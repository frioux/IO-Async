#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007-2012 -- leonerd@leonerd.org.uk

package IO::Async::Loop;

use strict;
use warnings;

our $VERSION = '0.49';

# When editing this value don't forget to update the docs below
use constant NEED_API_VERSION => '0.33';

# Base value but some classes might override
use constant _CAN_ON_HANGUP => 0;

use constant HAVE_MSWIN32 => ( $^O eq "MSWin32" );

use Carp;

use Socket qw( AF_INET AF_UNIX SOCK_STREAM SOCK_DGRAM SOCK_RAW );
BEGIN {
   # Not quite sure where we'll find AF_INET6
   eval { Socket->import( 'AF_INET6' ); 1 } or
      eval { require Socket6; Socket6->import( 'AF_INET6' ) }
}
use IO::Socket;
use Time::HiRes qw(); # empty import
use POSIX qw( _exit WNOHANG );
use Scalar::Util qw( refaddr );

# Never sleep for more than 1 second if a signal proxy is registered, to avoid
# a borderline race condition.
# There is a race condition in perl involving signals interacting with XS code
# that implements blocking syscalls. There is a slight chance a signal will
# arrive in the XS function, before the blocking itself. Perl will not run our
# (safe) deferred signal handler in this case. To mitigate this, if we have a
# signal proxy, we'll adjust the maximal timeout. The signal handler will be 
# run when the XS function returns. 
our $MAX_SIGWAIT_TIME = 1;

# Maybe our calling program will have a suggested hint of a specific Loop
# class or list of classes to use
our $LOOP;

# Undocumented; used only by the test scripts.
# Setting this value true will avoid the IO::Async::Loop::$^O candidate in the
# magic constructor
our $LOOP_NO_OS;

=head1 NAME

C<IO::Async::Loop> - core loop of the C<IO::Async> framework

=head1 SYNOPSIS

 use IO::Async::Stream;
 use IO::Async::Timer::Countdown;

 use IO::Async::Loop;

 my $loop = IO::Async::Loop->new;

 $loop->add( IO::Async::Timer::Countdown->new(
    delay => 10,
    on_expire => sub { print "10 seconds have passed\n" },
 )->start );

 $loop->add( IO::Async::Stream->new_for_stdin(
    on_read => sub {
       my ( $self, $buffref, $eof ) = @_;

       while( $$buffref =~ s/^(.*)\n// ) {
          print "You typed a line $1\n";
       }

       return 0;
    },
 ) );

 $loop->run;

=head1 DESCRIPTION

This module provides an abstract class which implements the core loop of the
C<IO::Async> framework. Its primary purpose is to store a set of
L<IO::Async::Notifier> objects or subclasses of them. It handles all of the
lower-level set manipulation actions, and leaves the actual IO readiness 
testing/notification to the concrete class that implements it. It also
provides other functionality such as signal handling, child process managing,
and timers.

See also the two bundled Loop subclasses:

=over 4

=item L<IO::Async::Loop::Select>

=item L<IO::Async::Loop::Poll>

=back

Or other subclasses that may appear on CPAN which are not part of the core
C<IO::Async> distribution.

=cut

# Internal constructor used by subclasses
sub __new
{
   my $class = shift;

   # Detect if the API version provided by the subclass is sufficient
   $class->can( "API_VERSION" ) or
      die "$class is too old for IO::Async $VERSION; it does not provide \->API_VERSION\n";

   $class->API_VERSION >= NEED_API_VERSION or
      die "$class is too old for IO::Async $VERSION; we need API version >= ".NEED_API_VERSION.", it provides ".$class->API_VERSION."\n";

   my $self = bless {
      notifiers    => {}, # {nkey} = notifier
      iowatches    => {}, # {fd} = [ $on_read_ready, $on_write_ready, $on_hangup ]
      sigattaches  => {}, # {sig} => \@callbacks
      sigproxy     => undef,
      childmanager => undef,
      childwatches => {}, # {pid} => $code
      timequeue    => undef,
      deferrals    => [],
   }, $class;

   # It's possible this is a specific subclass constructor. We still want the
   # magic IO::Async::Loop->new constructor to yield this if it's the first
   # one
   our $ONE_TRUE_LOOP ||= $self;

   # Legacy support - temporary until all CPAN classes are updated; bump NEEDAPI version at that point
   my $old_timer = $self->can( "enqueue_timer" ) != \&enqueue_timer;
   if( $old_timer != ( $self->can( "cancel_timer" ) != \&cancel_timer ) ) {
      die "$class should overload both ->enqueue_timer and ->cancel_timer, or neither";
   }

   $self->{old_timer} = $old_timer;

   return $self;
}

=head1 MAGIC CONSTRUCTOR

=head2 $loop = IO::Async::Loop->new

This function attempts to find a good subclass to use, then calls its
constructor. It works by making a list of likely candidate classes, then
trying each one in turn, C<require>ing the module then calling its C<new>
method. If either of these operations fails, the next subclass is tried. If
no class was successful, then an exception is thrown.

The constructed object is cached, and will be returned again by a subsequent
call. The cache will also be set by a constructor on a specific subclass. This
behaviour makes it possible to simply use the normal constructor in a module
that wishes to interract with the main program's Loop, such as an integration
module for another event system.

For example, the following two C<$loop> variables will refer to the same
object:

 use IO::Async::Loop;
 use IO::Async::Loop::Poll;

 my $loop_poll = IO::Async::Loop::Poll->new;

 my $loop = IO::Async::Loop->new;

While it is not advised to do so under normal circumstances, if the program
really wishes to construct more than one Loop object, it can call the
constructor C<really_new>, or invoke one of the subclass-specific constructors
directly.

The list of candidates is formed from the following choices, in this order:

=over 4

=item * $ENV{IO_ASYNC_LOOP}

If this environment variable is set, it should contain a comma-separated list
of subclass names. These names may or may not be fully-qualified; if a name
does not contain C<::> then it will have C<IO::Async::Loop::> prepended to it.
This allows the end-user to specify a particular choice to fit the needs of
his use of a program using C<IO::Async>.

=item * $IO::Async::Loop::LOOP

If this scalar is set, it should contain a comma-separated list of subclass
names. These may or may not be fully-qualified, as with the above case. This
allows a program author to suggest a loop module to use.

In cases where the module subclass is a hard requirement, such as GTK programs
using C<Glib>, it would be better to use the module specifically and invoke
its constructor directly.

=item * $^O

The module called C<IO::Async::Loop::$^O> is tried next. This allows specific
OSes, such as the ever-tricky C<MSWin32>, to provide an implementation that
might be more efficient than the generic ones, or even work at all.

=item * Poll and Select

Finally, if no other choice has been made by now, the built-in C<Poll> module
is chosen. This should always work, but in case it doesn't, the C<Select>
module will be chosen afterwards as a last-case attempt. If this also fails,
then the magic constructor itself will throw an exception.

=back

If any of the explicitly-requested loop types (C<$ENV{IO_ASYNC_LOOP}> or
C<$IO::Async::Loop::LOOP>) fails to load then a warning is printed detailing
the error.

Implementors of new C<IO::Async::Loop> subclasses should see the notes about
C<API_VERSION> below.

=cut

sub __try_new
{
   my ( $class ) = @_;

   ( my $file = "$class.pm" ) =~ s{::}{/}g;

   eval {
      local $SIG{__WARN__} = sub {};
      require $file;
   } or return;

   my $self;
   $self = eval { $class->new } and return $self;

   # Oh dear. We've loaded the code OK but for some reason the constructor
   # wasn't happy. Being polite we ought really to unload the file again,
   # but perl doesn't actually provide us a way to do this.

   return undef;
}

sub new
{
   return our $ONE_TRUE_LOOP ||= shift->really_new;
}

sub really_new
{
   shift;  # We're going to ignore the class name actually given

   my $self;

   my @candidates;

   push @candidates, split( m/,/, $ENV{IO_ASYNC_LOOP} ) if defined $ENV{IO_ASYNC_LOOP};

   push @candidates, split( m/,/, $LOOP ) if defined $LOOP;

   foreach my $class ( @candidates ) {
      $class =~ m/::/ or $class = "IO::Async::Loop::$class";
      $self = __try_new( $class ) and return $self;

      my ( $topline ) = split m/\n/, $@; # Ignore all the other lines; they'll be require's verbose output
      warn "Unable to use $class - $topline\n";
   }

   $self = __try_new( "IO::Async::Loop::$^O" ) and return $self unless $LOOP_NO_OS;

   $self = __try_new( "IO::Async::Loop::Poll" )   and return $self;
   $self = __try_new( "IO::Async::Loop::Select" ) and return $self;

   croak "Cannot find a suitable candidate class";
}

#######################
# Notifier management #
#######################

=head1 NOTIFIER MANAGEMENT

The following methods manage the collection of C<IO::Async::Notifier> objects.

=cut

=head2 $loop->add( $notifier )

This method adds another notifier object to the stored collection. The object
may be a C<IO::Async::Notifier>, or any subclass of it.

When a notifier is added, any children it has are also added, recursively. In
this way, entire sections of a program may be written within a tree of
notifier objects, and added or removed on one piece.

=cut

sub add
{
   my $self = shift;
   my ( $notifier ) = @_;

   if( defined $notifier->parent ) {
      croak "Cannot add a child notifier directly - add its parent";
   }

   if( defined $notifier->loop ) {
      croak "Cannot add a notifier that is already a member of a loop";
   }

   $self->_add_noparentcheck( $notifier );
}

sub _add_noparentcheck
{
   my $self = shift;
   my ( $notifier ) = @_;

   my $nkey = refaddr $notifier;

   $self->{notifiers}->{$nkey} = $notifier;

   $notifier->__set_loop( $self );

   $self->_add_noparentcheck( $_ ) for $notifier->children;

   return;
}

=head2 $loop->remove( $notifier )

This method removes a notifier object from the stored collection, and
recursively and children notifiers it contains.

=cut

sub remove
{
   my $self = shift;
   my ( $notifier ) = @_;

   if( defined $notifier->parent ) {
      croak "Cannot remove a child notifier directly - remove its parent";
   }

   $self->_remove_noparentcheck( $notifier );
}

sub _remove_noparentcheck
{
   my $self = shift;
   my ( $notifier ) = @_;

   my $nkey = refaddr $notifier;

   exists $self->{notifiers}->{$nkey} or croak "Notifier does not exist in collection";

   delete $self->{notifiers}->{$nkey};

   $notifier->__set_loop( undef );

   $self->_remove_noparentcheck( $_ ) for $notifier->children;

   return;
}

=head2 @notifiers = $loop->notifiers

Returns a list of all the notifier objects currently stored in the Loop.

=cut

sub notifiers
{
   my $self = shift;
   # Sort so the order remains stable under additions/removals
   return map { $self->{notifiers}->{$_} } sort keys %{ $self->{notifiers} };
}

###################
# Looping support #
###################

=head1 LOOPING CONTROL

The following methods control the actual run cycle of the loop, and hence the
program.

=cut

=head2 $count = $loop->loop_once( $timeout )

This method performs a single wait loop using the specific subclass's
underlying mechanism. If C<$timeout> is undef, then no timeout is applied, and
it will wait until an event occurs. The intention of the return value is to
indicate the number of callbacks that this loop executed, though different
subclasses vary in how accurately they can report this. See the documentation
for this method in the specific subclass for more information.

=cut

sub loop_once
{
   my $self = shift;
   my ( $timeout ) = @_;

   croak "Expected that $self overrides ->loop_once";
}

=head2 @result = $loop->run

=head2 $result = $loop->run

Runs the actual IO event loop. This method blocks until the C<stop> method is
called, and returns the result that was passed to C<stop>. In scalar context
only the first result is returned; the others will be discarded if more than
one value was provided. This method may be called recursively.

This method is a recent addition and may not be supported by all the
C<IO::Async::Loop> subclasses currently available on CPAN.

=cut

sub run
{
   my $self = shift;

   local $self->{running} = 1;
   local $self->{result} = [];

   while( $self->{running} ) {
      $self->loop_once( undef );
   }

   return wantarray ? @{ $self->{result} } : $self->{result}[0];
}

=head2 $loop->stop( @result )

Stops the inner-most C<run> method currently in progress, causing it to return
the given C<@result>.

This method is a recent addition and may not be supported by all the
C<IO::Async::Loop> subclasses currently available on CPAN.

=cut

sub stop
{
   my $self = shift;

   @{ $self->{result} } = @_;
   undef $self->{running};
}

=head2 $loop->loop_forever

A synonym for C<run>, though this method does not return a result.

=cut

sub loop_forever
{
   my $self = shift;
   $self->run;
   return;
}

=head2 $loop->loop_stop

A synonym for C<stop>, though this method does not pass any results.

=cut

sub loop_stop
{
   my $self = shift;
   $self->stop;
}

############
# Features #
############

=head1 FEATURES

Most of the following methods are higher-level wrappers around base
functionality provided by the low-level API documented below. They may be
used by C<IO::Async::Notifier> subclasses or called directly by the program.

=cut

sub __new_feature
{
   my $self = shift;
   my ( $classname ) = @_;

   ( my $filename = "$classname.pm" ) =~ s{::}{/}g;
   require $filename;

   # These features aren't supposed to be "user visible", so if methods called
   # on it carp or croak, the shortmess line ought to skip IO::Async::Loop and
   # go on report its caller. To make this work, add the feature class to our
   # @CARP_NOT list.
   push our(@CARP_NOT), $classname;

   return $classname->new( loop => $self );
}

=head2 $id = $loop->attach_signal( $signal, $code )

This method adds a new signal handler to watch the given signal. The same
signal can be attached to multiple times; its callback functions will all be
invoked, in no particular order.

The returned C<$id> value can be used to identify the signal handler in case
it needs to be removed by the C<detach_signal> method. Note that this value
may be an object reference, so if it is stored, it should be released after it
cancelled, so the object itself can be freed.

=over 8

=item $signal

The name of the signal to attach to. This should be a bare name like C<TERM>.

=item $code

A CODE reference to the handling callback.

=back

Attaching to C<SIGCHLD> is not recommended because of the way all child
processes use it to report their termination. Instead, the C<watch_child>
method should be used to watch for termination of a given child process. A
warning will be printed if C<SIGCHLD> is passed here, but in future versions
of C<IO::Async> this behaviour may be disallowed altogether.

See also L<POSIX> for the C<SIGI<name>> constants.

For a more flexible way to use signals from within Notifiers, see instead the
L<IO::Async::Signal> object.

=cut

sub attach_signal
{
   my $self = shift;
   my ( $signal, $code ) = @_;

   if( $signal eq "CHLD" ) {
      # We make special exception to allow $self->watch_child to do this
      caller eq "IO::Async::Loop" or
         carp "Attaching to SIGCHLD is not advised - use ->watch_child instead";
   }

   if( not $self->{sigattaches}->{$signal} ) {
      my @attaches;
      $self->watch_signal( $signal, sub {
         foreach my $attachment ( @attaches ) {
            $attachment->();
         }
      } );
      $self->{sigattaches}->{$signal} = \@attaches;
   }

   push @{ $self->{sigattaches}->{$signal} }, $code;

   return \$self->{sigattaches}->{$signal}->[-1];
}

=head2 $loop->detach_signal( $signal, $id )

Removes a previously-attached signal handler.

=over 8

=item $signal

The name of the signal to remove from. This should be a bare name like
C<TERM>.

=item $id

The value returned by the C<attach_signal> method.

=back

=cut

sub detach_signal
{
   my $self = shift;
   my ( $signal, $id ) = @_;

   # Can't use grep because we have to preserve the addresses
   my $attaches = $self->{sigattaches}->{$signal} or return;

   for (my $i = 0; $i < @$attaches; ) {
      $i++, next unless \$attaches->[$i] == $id;

      splice @$attaches, $i, 1, ();
   }

   if( !@$attaches ) {
      $self->unwatch_signal( $signal );
      delete $self->{sigattaches}->{$signal};
   }
}

=head2 $loop->later( $code )

Schedules a code reference to be invoked as soon as the current round of IO
operations is complete.

The code reference is never invoked immediately, though the loop will not
perform any blocking operations between when it is installed and when it is
invoked. It may call C<select>, C<poll> or equivalent with a zero-second
timeout, and process any currently-pending IO conditions before the code is
invoked, but it will not block for a non-zero amount of time.

This method is implemented using the C<watch_idle> method, with the C<when>
parameter set to C<later>. It will return an ID value that can be passed to
C<unwatch_idle> if required.

=cut

sub later
{
   my $self = shift;
   my ( $code ) = @_;

   return $self->watch_idle( when => 'later', code => $code );
}

# undocumented, to be removed soon
sub detach_child
{
   my $self = shift;
   warnings::warnif( deprecated => "Loop->detach_child is deprecated; use ->fork instead" );
   $self->fork( @_ );
}

# undocumented, to be removed soon
sub detach_code
{
   my $self = shift;
   my %params = @_;

   warnings::warnif( deprecated => "Loop->detach_code is deprecated; use IO::Async::Function instead" );

   require IO::Async::DetachedCode;

   return IO::Async::DetachedCode->new(
      %params,
      loop => $self
   );
}

=head2 $loop->spawn_child( %params )

This method creates a new child process to run a given code block or command.
For more detail, see the C<spawn_child> method on the
L<IO::Async::ChildManager> class.

=cut

sub spawn_child
{
   my $self = shift;
   my %params = @_;

   my $childmanager = $self->{childmanager} ||=
      $self->__new_feature( "IO::Async::ChildManager" );

   $childmanager->spawn_child( %params );
}

=head2 $pid = $loop->open_child( %params )

This creates a new child process to run the given code block or command, and
attaches filehandles to it that the parent will watch. This method is a light
wrapper around constructing a new L<IO::Async::Process> object, provided
largely for backward compatibility. New code ought to construct such an object
directly, as it may provide more features than are available here.

The C<%params> hash takes the following keys:

=over 8

=item command => ARRAY or STRING

=item code => CODE

The command or code to run in the child process (as per the C<spawn> method)

=item on_finish => CODE

A continuation to be called when the child process exits and has closed all of
the filehandles that were set up for it. It will be invoked in the following
way:

 $on_finish->( $pid, $exitcode )

The second argument is passed the plain perl C<$?> value. To use that
usefully, see C<WEXITSTATUS> and others from C<POSIX>.

=item on_error => CODE

Optional continuation to be called when the child code block throws an
exception, or the command could not be C<exec(2)>ed. It will be invoked in the
following way (as per C<spawn>)

 $on_error->( $pid, $exitcode, $dollarbang, $dollarat )

If this continuation is not supplied, then C<on_finish> is used instead. The
value of C<$!> and C<$@> will not be reported.

=item setup => ARRAY

Optional reference to an array to pass to the underlying C<spawn> method.

=back

In addition, the hash takes keys that define how to set up file descriptors in
the child process. (If the C<setup> array is also given, these operations will
be performed after those specified by C<setup>.)

=over 8

=item fdI<n> => HASH

A hash describing how to set up file descriptor I<n>. The hash may contain one
of the following sets of keys:

=over 4

=item on_read => CODE

The child will be given the writing end of a pipe. The reading end will be
wrapped by an C<IO::Async::Stream> using this C<on_read> callback function.

=item from => STRING

The child will be given the reading end of a pipe. The string given by the
C<from> parameter will be written to the child. When all of the data has been
written the pipe will be closed.

=back

=item stdin => ...

=item stdout => ...

=item stderr => ...

Shortcuts for C<fd0>, C<fd1> and C<fd2> respectively.

=back

=cut

sub open_child
{
   my $self = shift;
   my %params = @_;

   my $on_finish = delete $params{on_finish};
   ref $on_finish or croak "Expected 'on_finish' to be a reference";
   $params{on_finish} = sub {
      my ( $process, $exitcode ) = @_;
      $on_finish->( $process->pid, $exitcode );
   };

   if( my $on_error = delete $params{on_error} ) {
      ref $on_error or croak "Expected 'on_error' to be a reference";

      $params{on_exception} = sub {
         my ( $process, $exception, $errno, $exitcode ) = @_;
         # Swap order
         $on_error->( $process->pid, $exitcode, $errno, $exception );
      };
   }

   $params{on_exit} and croak "Cannot pass 'on_exit' parameter through ChildManager->open";

   require IO::Async::Process;
   my $process = IO::Async::Process->new( %params );

   $self->add( $process );

   return $process->pid;
}

=head2 $pid = $loop->run_child( %params )

This creates a new child process to run the given code block or command,
capturing its STDOUT and STDERR streams. When the process exits, a
continuation is invoked being passed the exitcode, and content of the streams.

=over 8

=item command => ARRAY or STRING

=item code => CODE

The command or code to run in the child process (as per the C<spawn_child>
method)

=item on_finish => CODE

A continuation to be called when the child process exits and closed its STDOUT
and STDERR streams. It will be invoked in the following way:

 $on_finish->( $pid, $exitcode, $stdout, $stderr )

The second argument is passed the plain perl C<$?> value. To use that
usefully, see C<WEXITSTATUS> and others from C<POSIX>.

=item stdin => STRING

Optional. String to pass in to the child process's STDIN stream.

=item setup => ARRAY

Optional reference to an array to pass to the underlying C<spawn> method.

=back

This method is intended mainly as an IO::Async-compatible replacement for the
perl C<readpipe> function (`backticks`), allowing it to replace

  my $output = `command here`;

with

 $loop->run_child(
    command => "command here", 
    on_finish => sub {
       my ( undef, $exitcode, $output ) = @_;
       ...
    }
 );

=cut

sub run_child
{
   my $self = shift;
   my %params = @_;

   my $on_finish = delete $params{on_finish};
   ref $on_finish or croak "Expected 'on_finish' to be a reference";

   my $stdout;
   my $stderr;

   my %subparams;

   if( my $child_stdin = delete $params{stdin} ) {
      ref $child_stdin and croak "Expected 'stdin' not to be a reference";
      $subparams{stdin} = { from => $child_stdin };
   }

   $subparams{code}    = delete $params{code};
   $subparams{command} = delete $params{command};
   $subparams{setup}   = delete $params{setup};

   croak "Unrecognised parameters " . join( ", ", keys %params ) if keys %params;

   require IO::Async::Process;
   my $process = IO::Async::Process->new(
      %subparams,
      stdout => { into => \$stdout },
      stderr => { into => \$stderr },

      on_finish => sub {
         my ( $process, $exitcode ) = @_;
         $on_finish->( $process->pid, $exitcode, $stdout, $stderr );
      },
   );

   $self->add( $process );

   return $process->pid;
}

=head2 $loop->resolver

Returns the internally-stored L<IO::Async::Resolver> object, used for name
resolution operations by the C<resolve>, C<connect> and C<listen> methods.

=cut

sub resolver
{
   my $self = shift;

   return $self->{resolver} ||= do {
      require IO::Async::Resolver;
      my $resolver = IO::Async::Resolver->new;
      $self->add( $resolver );
      $resolver;
   }
}

=head2 $loop->resolve( %params )

This method performs a single name resolution operation. It uses an
internally-stored C<IO::Async::Resolver> object. For more detail, see the
C<resolve> method on the L<IO::Async::Resolver> class.

=cut

sub resolve
{
   my $self = shift;
   my ( %params ) = @_;

   $self->resolver->resolve( %params );
}

=head2 $loop->connect( %params )

This method performs a non-blocking connect operation. It uses an
internally-stored C<IO::Async::Connector> object. For more detail, see the
C<connect> method on the L<IO::Async::Connector> class.

This method accepts an C<extensions> parameter; see the C<EXTENSIONS> section
below.

=cut

sub connect
{
   my $self = shift;
   my ( %params ) = @_;

   my $extensions;
   if( $extensions = delete $params{extensions} and @$extensions ) {
      my ( $ext, @others ) = @$extensions;

      my $method = "${ext}_connect";
      # TODO: Try to 'require IO::Async::$ext'

      $self->can( $method ) or croak "Extension method '$method' is not available";

      $self->$method(
         %params,
         ( @others ? ( extensions => \@others ) : () ),
      );
      return;
   }

   my $connector = $self->{connector} ||= $self->__new_feature( "IO::Async::Connector" );

   $connector->connect( %params );
}

=head2 $loop->listen( %params )

This method sets up a listening socket. It creates an instance of
L<IO::Async::Listener> and adds it to the Loop.

Most parameters given to this method are passed into the constructed Listener
object's C<listen> method. In addition, the following arguments are also
recognised directly:

=over 8

=item on_listen => CODE

Optional. A callback that is invoked when the listening socket is ready.
Typically this would be used in the name resolver case, in order to inspect
the socket's sockname address, or otherwise inspect the filehandle.

 $on_listen->( $socket )

=item on_notifier => CODE

Optional. A callback that is invoked when the Listener object is ready to
receive connections. The callback is passed the Listener object itself.

 $on_notifier->( $listener )

If this callback is required, it may instead be better to construct the
Listener object directly.

=back

An alternative which gives more control over the listener, is to create the
C<IO::Async::Listener> object directly and add it explicitly to the Loop.

This method accepts an C<extensions> parameter; see the C<EXTENSIONS> section
below.

=cut

sub listen
{
   my $self = shift;
   my ( %params ) = @_;

   my $extensions;
   if( $extensions = delete $params{extensions} and @$extensions ) {
      my ( $ext, @others ) = @$extensions;

      my $method = "${ext}_listen";
      # TODO: Try to 'require IO::Async::$ext'

      $self->can( $method ) or croak "Extension method '$method' is not available";

      $self->$method(
         %params,
         ( @others ? ( extensions => \@others ) : () ),
      );
      return;
   }

   require IO::Async::Listener;

   my $on_notifier = delete $params{on_notifier};

   my %listenerparams;

   if( my $handle = delete $params{handle} ) {
      $listenerparams{handle} = $handle;
   }

   # Our wrappings of these don't want $self
   for (qw( on_accept on_stream on_socket )) {
      next unless exists $params{$_};
      my $code = delete $params{$_};
      $listenerparams{$_} = sub {
         shift;
         goto &$code;
      };
   }

   my $listener = IO::Async::Listener->new( %listenerparams );

   $self->add( $listener );

   if( $listener->is_listening ) {
      $on_notifier->( $listener ) if $on_notifier;
   }
   else {
      my $on_listen = delete $params{on_listen};
      $listener->listen( 
         %params,
         on_listen => sub {
            my ( $sock ) = @_;
            $on_listen->( $listener->read_handle ) if $on_listen;
            $on_notifier->( $listener ) if $on_notifier;
         },
         on_listen_error => sub {
            $self->remove( $listener );
            $params{on_listen_error}->( @_ ) if $params{on_listen_error};
         },
         on_resolve_error => sub {
            $self->remove( $listener );
            $params{on_resolve_error}->( @_ ) if $params{on_resolve_error};
         },
      );
   }

   # Unit testing needs this
   return $listener;
}

=head1 OS ABSTRACTIONS

Because the Magic Constructor searches for OS-specific subclasses of the Loop,
several abstractions of OS services are provided, in case specific OSes need
to give different implementations on that OS.

=cut

# This one isn't documented because it's not really overridable. It's largely
# here just for completeness
sub socket
{
   my $self = shift;
   my ( $family, $socktype, $proto ) = @_;

   croak "Cannot create a new socket without a family" unless $family;

   # SOCK_STREAM is the most likely
   defined $socktype or $socktype = SOCK_STREAM;

   defined $proto or $proto = 0;

   my $sock = eval {
      IO::Socket->new(
         Domain => $family, 
         Type   => $socktype,
         Proto  => $proto,
      );
   };
   return $sock if $sock;

   # That failed. Most likely because the Domain was unrecognised. This 
   # usually happens if getaddrinfo returns an AF_INET6 address but we don't
   # have a suitable class loaded. In this case we'll return a generic one.
   # It won't be in the specific subclass but that's the best we can do. And
   # it will still work as a generic socket.
   return IO::Socket->new->socket( $family, $socktype, $proto );
}

sub _getfamilybyname
{
   my ( $name ) = @_;

   return undef unless defined $name;

   return $name if $name =~ m/^\d+$/;

   return AF_INET    if $name eq "inet";
   return AF_INET6() if $name eq "inet6" and defined &AF_INET6;
   return AF_UNIX    if $name eq "unix";

   croak "Unrecognised socktype name '$name'";
}

sub _getsocktypebyname
{
   my ( $name ) = @_;

   return undef unless defined $name;

   return $name if $name =~ m/^\d+$/;

   return SOCK_STREAM if $name eq "stream";
   return SOCK_DGRAM  if $name eq "dgram";
   return SOCK_RAW    if $name eq "raw";

   croak "Unrecognised socktype name '$name'";
}

=head2 ( $S1, $S2 ) = $loop->socketpair( $family, $socktype, $proto )

An abstraction of the C<socketpair(2)> syscall, where any argument may be
missing (or given as C<undef>).

If C<$family> is not provided, a suitable value will be provided by the OS
(likely C<AF_UNIX> on POSIX-based platforms). If C<$socktype> is not provided,
then C<SOCK_STREAM> will be used.

Additionally, this method supports building connected C<SOCK_STREAM> or
C<SOCK_DGRAM> pairs in the C<AF_INET> family even if the underlying platform's
C<socketpair(2)> does not, by connecting two normal sockets together.

C<$family> and C<$socktype> may also be given symbolically similar to the
behaviour of C<extract_addrinfo>.

=cut

sub socketpair
{
   my $self = shift;
   my ( $family, $socktype, $proto ) = @_;

   # PF_UNSPEC and undef are both false
   $family = _getfamilybyname( $family ) || AF_UNIX;

   # SOCK_STREAM is the most likely
   $socktype = _getsocktypebyname( $socktype ) || SOCK_STREAM;

   $proto ||= 0;

   my ( $S1, $S2 ) = IO::Socket->new->socketpair( $family, $socktype, $proto );
   return ( $S1, $S2 ) if defined $S1;

   return unless $family == AF_INET and ( $socktype == SOCK_STREAM or $socktype == SOCK_DGRAM );

   # Now lets emulate an AF_INET socketpair call

   my $Stmp = $self->socket( $family, $socktype ) or return;
   $Stmp->bind( pack_sockaddr_in( 0, INADDR_LOOPBACK ) ) or return;

   $S1 = $self->socket( $family, $socktype ) or return;

   if( $socktype == SOCK_STREAM ) {
      $Stmp->listen( 1 ) or return;
      $S1->connect( getsockname $Stmp ) or return;
      $S2 = $Stmp->accept or return;

      # There's a bug in IO::Socket here, in that $S2 's ->socktype won't
      # yet be set. We can apply a horribly hacky fix here
      #   defined $S2->socktype and $S2->socktype == $socktype or
      #     ${*$S2}{io_socket_type} = $socktype;
      # But for now we'll skip the test for it instead
   }
   else {
      $S2 = $Stmp;
      $S1->connect( getsockname $S2 ) or return;
      $S2->connect( getsockname $S1 ) or return;
   }

   return ( $S1, $S2 );
}

# TODO: Move this into its own file, have it loaded dynamically via $^O
if( HAVE_MSWIN32 ) {
   # Win32 doesn't have a socketpair(). We'll fake one up

   undef *socketpair;
   *socketpair = sub {
      my $self = shift;
      my ( $family, $socktype, $proto ) = @_;

      $family = _getfamilybyname( $family ) || AF_INET;

      # SOCK_STREAM is the most likely
      $socktype = _getsocktypebyname( $socktype ) || SOCK_STREAM;

      $proto ||= 0;

      if( $socktype == SOCK_STREAM ) {
         my $listener = IO::Socket::INET->new(
            LocalAddr => "127.0.0.1",
            LocalPort => 0,
            Listen    => 1,
            Blocking  => 0,
         ) or croak "Cannot socket() - $!";

         my $S1 = IO::Socket::INET->new(
            PeerAddr => $listener->sockhost,
            PeerPort => $listener->sockport
         ) or croak "Cannot socket() again - $!";

         my $S2 = $listener->accept or croak "Cannot accept() - $!";

         $listener->close;

         return ( $S1, $S2 );
      }
      elsif( $socktype == SOCK_DGRAM ) {
         my $S1 = IO::Socket::INET->new(
            LocalAddr => "127.0.0.1",
            Type      => SOCK_DGRAM,
            Proto     => "udp",
         ) or croak "Cannot socket() - $!";
         
         my $S2 = IO::Socket::INET->new(
            LocalAddr => "127.0.0.1",
            Type      => SOCK_DGRAM,
            Proto     => "udp",
         ) or croak "Cannot socket() again - $!";

         $S1->connect( $S2->sockname );
         $S2->connect( $S1->sockname );

         return ( $S1, $S2 );
      }
      else {
         croak "Unrecognised socktype $socktype";
      }
   };
}

=head2 ( $rd, $wr ) = $loop->pipepair

An abstraction of the C<pipe(2)> syscall, which returns the two new handles.

=cut

sub pipepair
{
   my $self = shift;

   pipe( my ( $rd, $wr ) ) or return;
   return ( $rd, $wr );
}

=head2 ( $rdA, $wrA, $rdB, $wrB ) = $loop->pipequad

This method is intended for creating two pairs of filehandles that are linked
together, suitable for passing as the STDIN/STDOUT pair to a child process.
After this function returns, C<$rdA> and C<$wrA> will be a linked pair, as
will C<$rdB> and C<$wrB>.

On platforms that support C<socketpair(2)>, this implementation will be
preferred, in which case C<$rdA> and C<$wrB> will actually be the same
filehandle, as will C<$rdB> and C<$wrA>. This saves a file descriptor in the
parent process.

When creating a C<IO::Async::Stream> or subclass of it, the C<read_handle>
and C<write_handle> parameters should always be used.

 my ( $childRd, $myWr, $myRd, $childWr ) = $loop->pipequad;

 $loop->open_child(
    stdin  => $childRd,
    stdout => $childWr,
    ...
 );

 my $str = IO::Async::Stream->new(
    read_handle  => $myRd,
    write_handle => $myWr,
    ...
 );
 $loop->add( $str );

=cut

sub pipequad
{
   my $self = shift;

   # Prefer socketpair
   if( my ( $S1, $S2 ) = $self->socketpair ) {
      return ( $S1, $S2, $S2, $S1 );
   }

   # Can't do that, fallback on pipes
   my ( $rdA, $wrA ) = $self->pipepair or return;
   my ( $rdB, $wrB ) = $self->pipepair or return;

   return ( $rdA, $wrA, $rdB, $wrB );
}

=head2 $signum = $loop->signame2num( $signame )

This utility method converts a signal name (such as "TERM") into its system-
specific signal number. This may be useful to pass to C<POSIX::SigSet> or use
in other places which use numbers instead of symbolic names.

=cut

my %sig_num;
sub _init_signum
{
   my $self = shift;
   # Copypasta from Config.pm's documentation

   our %Config;
   require Config;
   Config->import;

   unless($Config{sig_name} && $Config{sig_num}) {
      die "No signals found";
   }
   else {
      my @names = split ' ', $Config{sig_name};
      @sig_num{@names} = split ' ', $Config{sig_num};
   }
}

sub signame2num
{
   my $self = shift;
   my ( $signame ) = @_;

   %sig_num or $self->_init_signum;

   return $sig_num{$signame};
}

=head2 ( $family, $socktype, $protocol, $addr ) = $loop->extract_addrinfo( $ai )

Given an ARRAY or HASH reference value containing an addrinfo, returns a
family, socktype and protocol argument suitable for a C<socket> call and an
address suitable for C<connect> or C<bind>.

If given an ARRAY it should be in the following form:

 [ $family, $socktype, $protocol, $addr ]

If given a HASH it should contain the following keys:

 family socktype protocol addr

Each field in the result will be initialised to 0 (or empty string for the
address) if not defined in the C<$ai> value.

The family type may also be given as a symbolic string; C<inet> or possibly
C<inet6> if the host system supports it, or C<unix>; this will be converted to
the appropriate C<AF_*> constant.

The socktype may also be given as a symbolic string; C<stream>, C<dgram> or
C<raw>; this will be converted to the appropriate C<SOCK_*> constant.

Note that the C<addr> field, if provided, must be a packed socket address,
such as returned by C<pack_sockaddr_in> or C<pack_sockaddr_un>.

If the HASH form is used, rather than passing a packed socket address in the
C<addr> field, certain other hash keys may be used instead for convenience on
certain named families.

=over 4

=cut

use constant ADDRINFO_FAMILY   => 0;
use constant ADDRINFO_SOCKTYPE => 1;
use constant ADDRINFO_PROTOCOL => 2;
use constant ADDRINFO_ADDR     => 3;

sub extract_addrinfo
{
   my $self = shift;
   my ( $ai, $argname ) = @_;

   $argname ||= "addr";

   my @ai;

   if( ref $ai eq "ARRAY" ) {
      @ai = @$ai;
   }
   elsif( ref $ai eq "HASH" ) {
      @ai = @{$ai}{qw( family socktype protocol addr )};
   }
   else {
      croak "Expected '$argname' to be an ARRAY or HASH reference";
   }

   if( defined $ai[ADDRINFO_FAMILY] and !defined $ai[ADDRINFO_ADDR] and ref $ai eq "HASH" ) {
      my $family = $ai[ADDRINFO_FAMILY];
      my $method = "_extract_addrinfo_$family";
      my $code = $self->can( $method ) or croak "Cannot determine addr for extract_addrinfo on family='$family'";

      $ai[ADDRINFO_ADDR] = $code->( $self, $ai );
   }

   $ai[ADDRINFO_FAMILY]   = _getfamilybyname( $ai[ADDRINFO_FAMILY] );
   $ai[ADDRINFO_SOCKTYPE] = _getsocktypebyname( $ai[ADDRINFO_SOCKTYPE] );

   # Make sure all fields are defined
   $ai[$_] ||= 0 for ADDRINFO_FAMILY, ADDRINFO_SOCKTYPE, ADDRINFO_PROTOCOL;
   $ai[ADDRINFO_ADDR]  = "" if !defined $ai[ADDRINFO_ADDR];

   return @ai;
}

=item family => 'inet'

Will pack an IP address and port number from keys called C<ip> and C<port>.

=cut

sub _extract_addrinfo_inet
{
   my $self = shift;
   my ( $ai ) = @_;

   defined( my $port = $ai->{port} ) or croak "Expected 'port' for extract_addrinfo on family='inet'";
   defined( my $ip   = $ai->{ip}   ) or croak "Expected 'ip' for extract_addrinfo on family='inet'";

   return Socket::pack_sockaddr_in( $port, Socket::inet_aton( $ip ) );
}

=item family => 'inet6'

Will pack an IP address and port number from keys called C<ip> and C<port>.
Optionally will also include values from C<scopeid> and C<flowinfo> keys if
provided.

This will only work if a C<pack_sockaddr_in6> function can be found, either
in C<Socket> or C<Socket6>.

=cut

sub _extract_addrinfo_inet6
{
   my $self = shift;
   my ( $ai ) = @_;

   defined( my $port = $ai->{port} ) or croak "Expected 'port' for extract_addrinfo on family='inet6'";
   defined( my $ip   = $ai->{ip}   ) or croak "Expected 'ip' for extract_addrinfo on family='inet6'";

   my $scopeid  = $ai->{scopeid}  || 0;
   my $flowinfo = $ai->{flowinfo} || 0;

   # We're not quite sure where pack_sockaddr_in6 might come from. Perl's
   # Socket module added it in 5.13.8 but before then Socket6 is our best bet.
   # Socket6 isn't core though.
   if( defined &Socket::pack_sockaddr_in6 ) {
      return Socket::pack_sockaddr_in6( $port, Socket::inet_pton( Socket::AF_INET6(), $ip ), $scopeid, $flowinfo );
   }
   elsif( defined &Socket6::pack_sockaddr_in6_all ) {
      return Socket6::pack_sockaddr_in6_all( $port, $flowinfo, Socket6::inet_pton( Socket6::AF_INET6(), $ip ), $scopeid );
   }
   else {
      croak "Cannot pack_sockaddr_in6";
   }
}

=item family => 'unix'

Will pack a UNIX socket path from a key called C<path>.

=cut

sub _extract_addrinfo_unix
{
   my $self = shift;
   my ( $ai ) = @_;

   defined( my $path = $ai->{path} ) or croak "Expected 'path' for extract_addrinfo on family='unix'";

   return Socket::pack_sockaddr_un( $path );
}

=pod

=back

=cut

sub unpack_addrinfo { goto &extract_addrinfo }

=head2 $time = $loop->time

Returns the current UNIX time in fractional seconds. This is currently
equivalent to C<Time::HiRes::time> but provided here as a utility for
programs to obtain the time current used by C<IO::Async> for its own timing
purposes.

=cut

sub time
{
   my $self = shift;
   return Time::HiRes::time;
}

=head2 $pid = $loop->fork( %params )

This method creates a new child process to run a given code block, returning
its process ID.

=over 8

=item code => CODE

A block of code to execute in the child process. It will be called in scalar
context inside an C<eval> block. The return value will be used as the
C<exit(2)> code from the child if it returns (or 255 if it returned C<undef> or
thows an exception).

=item on_exit => CODE

A optional continuation to be called when the child processes exits. It will
be invoked in the following way:

 $on_exit->( $pid, $exitcode )

The second argument is passed the plain perl C<$?> value. To use that
usefully, see C<WEXITSTATUS> and others from C<POSIX>.

This key is optional; if not supplied, the calling code should install a
handler using the C<watch_child> method.

=item keep_signals => BOOL

Optional boolean. If missing or false, any CODE references in the C<%SIG> hash
will be removed and restored back to C<DEFAULT> in the child process. If true,
no adjustment of the C<%SIG> hash will be performed.

=back

=cut

sub fork
{
   my $self = shift;
   my %params = @_;

   my $code = $params{code} or croak "Expected 'code' as a CODE reference";

   my $kid = fork;
   defined $kid or croak "Cannot fork() - $!";

   if( $kid == 0 ) {
      unless( $params{keep_signals} ) {
         foreach( keys %SIG ) {
            next if m/^__(WARN|DIE)__$/;
            $SIG{$_} = "DEFAULT" if ref $SIG{$_} eq "CODE";
         }
      }

      my $exitvalue = eval { $code->() };

      defined $exitvalue or $exitvalue = -1;
      _exit( $exitvalue );
   }

   my $loop = $self->{loop};

   if( defined $params{on_exit} ) {
      $self->watch_child( $kid => $params{on_exit} );
   }

   return $kid;
}

=head1 LOW-LEVEL METHODS

As C<IO::Async::Loop> is an abstract base class, specific subclasses of it are
required to implement certain methods that form the base level of
functionality. They are not recommended for applications to use; see instead
the various event objects or higher level methods listed above.

These methods should be considered as part of the interface contract required
to implement a C<IO::Async::Loop> subclass.

=cut

=head2 IO::Async::Loop->API_VERSION

This method will be called by the magic constructor on the class before it is
constructed, to ensure that the specific implementation will support the
required API. This method should return the API version that the loop
implementation supports. The magic constructor will use that class, provided
it declares a version at least as new as the version documented here.

The current API version is C<0.33>.

This method may be implemented using C<constant>; e.g

 use constant API_VERSION => '0.33';

=cut

=head2 $loop->watch_io( %params )

This method installs callback functions which will be invoked when the given
IO handle becomes read- or write-ready.

The C<%params> hash takes the following keys:

=over 8

=item handle => IO

The IO handle to watch.

=item on_read_ready => CODE

Optional. A CODE reference to call when the handle becomes read-ready.

=item on_write_ready => CODE

Optional. A CODE reference to call when the handle becomes write-ready.

=back

There can only be one filehandle of any given fileno registered at any one
time. For any one filehandle, there can only be one read-readiness and/or one
write-readiness callback at any one time. Registering a new one will remove an
existing one of that type. It is not required that both are provided.

Applications should use a C<IO::Async::Handle> or C<IO::Async::Stream> instead
of using this method.

=cut

# This class specifically does NOT implement this method, so that subclasses
# are forced to. The constructor will be checking....
sub __watch_io
{
   my $self = shift;
   my %params = @_;

   my $handle = delete $params{handle} or croak "Expected 'handle'";

   my $watch = ( $self->{iowatches}->{$handle->fileno} ||= [] );

   $watch->[0] = $handle;

   if( exists $params{on_read_ready} ) {
      $watch->[1] = delete $params{on_read_ready};
   }

   if( exists $params{on_write_ready} ) {
      $watch->[2] = delete $params{on_write_ready};
   }

   if( exists $params{on_hangup} ) {
      $self->_CAN_ON_HANGUP or croak "Cannot watch_io for 'on_hangup' in ".ref($self);
      $watch->[3] = delete $params{on_hangup};
   }

   keys %params and croak "Unrecognised keys for ->watch_io - " . join( ", ", keys %params );
}

=head2 $loop->unwatch_io( %params )

This method removes a watch on an IO handle which was previously installed by
C<watch_io>.

The C<%params> hash takes the following keys:

=over 8

=item handle => IO

The IO handle to remove the watch for.

=item on_read_ready => BOOL

If true, remove the watch for read-readiness.

=item on_write_ready => BOOL

If true, remove the watch for write-readiness.

=back

Either or both callbacks may be removed at once. It is not an error to attempt
to remove a callback that is not present. If both callbacks were provided to
the C<watch_io> method and only one is removed by this method, the other shall
remain.

=cut

sub __unwatch_io
{
   my $self = shift;
   my %params = @_;

   my $handle = delete $params{handle} or croak "Expected 'handle'";

   my $watch = $self->{iowatches}->{$handle->fileno} or return;

   if( delete $params{on_read_ready} ) {
      undef $watch->[1];
   }

   if( delete $params{on_write_ready} ) {
      undef $watch->[2];
   }

   if( delete $params{on_hangup} ) {
      $self->_CAN_ON_HANGUP or croak "Cannot watch_io for 'on_hangup' in ".ref($self);
      undef $watch->[3];
   }

   if( not $watch->[1] and not $watch->[2] and not $watch->[3] ) {
      delete $self->{iowatches}->{$handle->fileno};
   }

   keys %params and croak "Unrecognised keys for ->unwatch_io - " . join( ", ", keys %params );
}

=head2 $loop->watch_signal( $signal, $code )

This method adds a new signal handler to watch the given signal.

=over 8

=item $signal

The name of the signal to watch to. This should be a bare name like C<TERM>.

=item $code

A CODE reference to the handling callback.

=back

There can only be one callback per signal name. Registering a new one will
remove an existing one.

Applications should use a C<IO::Async::Signal> object, or call
C<attach_signal> instead of using this method.

This and C<unwatch_signal> are optional; a subclass may implement neither, or
both. If it implements neither then signal handling will be performed by the
base class using a self-connected pipe to interrupt the main IO blocking.

=cut

sub watch_signal
{
   my $self = shift;
   my ( $signal, $code ) = @_;

   my $sigproxy = $self->{sigproxy} ||= $self->__new_feature( "IO::Async::Internals::SignalProxy" );
   $sigproxy->watch( $signal, $code );
}

=head2 $loop->unwatch_signal( $signal )

This method removes the signal callback for the given signal.

=over 8

=item $signal

The name of the signal to watch to. This should be a bare name like C<TERM>.

=back

=cut

sub unwatch_signal
{
   my $self = shift;
   my ( $signal ) = @_;

   my $sigproxy = $self->{sigproxy} ||= $self->__new_feature( "IO::Async::Internals::SignalProxy" );
   $sigproxy->unwatch( $signal );

   if( !$sigproxy->signals ) {
      $self->remove( $sigproxy );
      undef $sigproxy;
      undef $self->{sigproxy};
   }
}

=head2 $id = $loop->watch_time( %args )

This method installs a callback which will be called at the specified time.
The time may either be specified as an absolute value (the C<at> key), or
as a delay from the time it is installed (the C<after> key).

The returned C<$id> value can be used to identify the timer in case it needs
to be cancelled by the C<unwatch_time> method. Note that this value may be
an object reference, so if it is stored, it should be released after it has
been fired or cancelled, so the object itself can be freed.

The C<%params> hash takes the following keys:

=over 8

=item at => NUM

The absolute system timestamp to run the event.

=item after => NUM

The delay after now at which to run the event, if C<at> is not supplied. A
zero or negative delayed timer should be executed as soon as possible; the
next time the C<loop_once> method is invoked.

=item now => NUM

The time to consider as now if calculating an absolute time based on C<after>;
defaults to C<time()> if not specified.

=item code => CODE

CODE reference to the continuation to run at the allotted time.

=back

Either one of C<at> or C<after> is required.

For more powerful timer functionality as a C<IO::Async::Notifier> (so it can
be used as a child within another Notifier), see instead the
L<IO::Async::Timer> object and its subclasses.

These C<*_time> methods are optional; a subclass may implement neither or both
of them. If it implements neither, then the base class will manage a queue of
timer events. This queue should be handled by the C<loop_once> method
implemented by the subclass, using the C<_adjust_timeout> and
C<_manage_queues> methods.

This is the newer version of the API, replacing C<enqueue_timer>. It is
unspecified how this method pair interacts with the older
C<enqueue/requeue/cancel_timer> triplet.

=cut

sub watch_time
{
   my $self = shift;
   my %args = @_;

   # Renamed args
   if( exists $args{after} ) {
      $args{delay} = delete $args{after};
   }
   elsif( exists $args{at} ) {
      $args{time}  = delete $args{at};
   }
   else {
      croak "Expected one of 'at' or 'after'";
   }

   if( $self->{old_timer} ) {
      $self->enqueue_timer( %args );
   }
   else {
      my $timequeue = $self->{timequeue} ||= $self->__new_feature( "IO::Async::Internals::TimeQueue" );

      my $time = $self->_build_time( %args );
      my $code = $args{code};

      $timequeue->enqueue( time => $time, code => $code );
   }
}

=head2 $loop->unwatch_time( $id )

Removes a timer callback previously created by C<watch_time>.

This is the newer version of the API, replacing C<cancel_timer>. It is
unspecified how this method pair interacts with the older
C<enqueue/requeue/cancel_timer> triplet.

=cut

sub unwatch_time
{
   my $self = shift;
   my ( $id ) = @_;

   if( $self->{old_timer} ) {
      $self->cancel_timer( $id );
   }
   else {
      my $timequeue = $self->{timequeue} ||= $self->__new_feature( "IO::Async::Internals::TimeQueue" );

      $timequeue->cancel( $id );
   }
}

sub _build_time
{
   my $self = shift;
   my %params = @_;

   my $time;
   if( exists $params{time} ) {
      $time = $params{time};
   }
   elsif( exists $params{delay} ) {
      my $now = exists $params{now} ? $params{now} : $self->time;

      $time = $now + $params{delay};
   }
   else {
      croak "Expected either 'time' or 'delay' keys";
   }

   return $time;
}

=head2 $id = $loop->enqueue_timer( %params )

An older version of C<watch_time>. This method should not be used in new code
but is retained for legacy purposes. For simple watch/unwatch behaviour use
instead the new C<watch_time> method; though note it has differently-named
arguments. For requeueable timers, consider using an
L<IO::Async::Timer::Countdown> or L<IO::Async::Timer::Absolute> instead.

=cut

sub enqueue_timer
{
   my $self = shift;
   my ( %params ) = @_;

   # Renamed args
   $params{after} = delete $params{delay} if exists $params{delay};
   $params{at}    = delete $params{time}  if exists $params{time};

   my $code = $params{code};
   return [ $self->watch_time( %params ), $code ];
}

=head2 $loop->cancel_timer( $id )

An older version of C<unwatch_time>. This method should not be used in new
code but is retained for legacy purposes.

=cut

sub cancel_timer
{
   my $self = shift;
   my ( $id ) = @_;
   $self->unwatch_time( $id->[0] );
}

=head2 $newid = $loop->requeue_timer( $id, %params )

Reschedule an existing timer, moving it to a new time. The old timer is
removed and will not be invoked.

The C<%params> hash takes the same keys as C<enqueue_timer>, except for the
C<code> argument.

The requeue operation may be implemented as a cancel + enqueue, which may
mean the ID changes. Be sure to store the returned C<$newid> value if it is
required.

This method should not be used in new code but is retained for legacy
purposes. For requeueable, consider using an L<IO::Async::Timer::Countdown> or
L<IO::Async::Timer::Absolute> instead.

=cut

sub requeue_timer
{
   my $self = shift;
   my ( $id, %params ) = @_;

   $self->unwatch_time( $id->[0] );
   return $self->enqueue_timer( %params, code => $id->[1] );
}

=head2 $id = $loop->watch_idle( %params )

This method installs a callback which will be called at some point in the near
future.

The C<%params> hash takes the following keys:

=over 8

=item when => STRING

Specifies the time at which the callback will be invoked. See below.

=item code => CODE

CODE reference to the continuation to run at the allotted time.

=back

The C<when> parameter defines the time at which the callback will later be
invoked. Must be one of the following values:

=over 8

=item later

Callback is invoked after the current round of IO events have been processed
by the loop's underlying C<loop_once> method.

If a new idle watch is installed from within a C<later> callback, the
installed one will not be invoked during this round. It will be deferred for
the next time C<loop_once> is called, after any IO events have been handled.

=back

If there are pending idle handlers, then the C<loop_once> method will use a
zero timeout; it will return immediately, having processed any IO events and
idle handlers.

The returned C<$id> value can be used to identify the idle handler in case it
needs to be removed, by calling the C<unwatch_idle> method. Note this value
may be a reference, so if it is stored it should be released after the
callback has been invoked or cancled, so the referrant itself can be freed.

This and C<unwatch_idle> are optional; a subclass may implement neither, or
both. If it implements neither then idle handling will be performed by the
base class, using the C<_adjust_timeout> and C<_manage_queues> methods.

=cut

sub watch_idle
{
   my $self = shift;
   my %params = @_;

   my $code = delete $params{code};
   ref $code or croak "Expected 'code' to be a reference";

   my $when = delete $params{when} or croak "Expected 'when'";

   # Future-proofing for other idle modes
   $when eq "later" or croak "Expected 'when' to be 'later'";

   my $deferrals = $self->{deferrals};

   push @$deferrals, $code;
   return \$deferrals->[-1];
}

=head2 $loop->unwatch_idle( $id )

Cancels a previously-installed idle handler.

=cut

sub unwatch_idle
{
   my $self = shift;
   my ( $id ) = @_;

   my $deferrals = $self->{deferrals};

   my $idx;
   \$deferrals->[$_] == $id and ( $idx = $_ ), last for 0 .. $#$deferrals;

   splice @$deferrals, $idx, 1, () if defined $idx;
}

=head2 $loop->watch_child( $pid, $code )

This method adds a new handler for the termination of the given child process
PID, or all child processes.

=over 8

=item $pid

The PID to watch. Will report on all child processes if this is 0.

=item $code

A CODE reference to the exit handler. It will be invoked as

 $code->( $pid, $? )

The second argument is passed the plain perl C<$?> value. To use that
usefully, see C<WEXITSTATUS> and others from C<POSIX>.

=back

After invocation, the handler for a PID-specific watch is automatically
removed. The all-child watch will remain until it is removed by
C<unwatch_child>.

This and C<unwatch_child> are optional; a subclass may implement neither, or
both. If it implements neither then child watching will be performed by using
C<watch_signal> to install a C<SIGCHLD> handler, which will use C<waitpid> to
look for exited child processes.

If both a PID-specific and an all-process watch are installed, there is no
ordering guarantee as to which will be called first.

=cut

sub watch_child
{
   my $self = shift;
   my ( $pid, $code ) = @_;

   my $childwatches = $self->{childwatches};

   croak "Already have a handler for $pid" if exists $childwatches->{$pid};

   if( !$self->{childwatch_sigid} ) {
      $self->{childwatch_sigid} = $self->attach_signal( CHLD => sub {
         while( 1 ) {
            my $zid = waitpid( -1, WNOHANG );

            last if !defined $zid or $zid < 1;
            my $status = $?;

            if( defined $childwatches->{$zid} ) {
               $childwatches->{$zid}->( $zid, $status );
               delete $childwatches->{$zid};
            }

            if( defined $childwatches->{0} ) {
               $childwatches->{0}->( $zid, $status );
               # Don't delete it
            }
         }
      } );

      # There's a chance the child has already exited
      my $zid = waitpid( $pid, WNOHANG );
      if( defined $zid and $zid > 0 ) {
         my $exitstatus = $?;
         $self->later( sub { $code->( $pid, $exitstatus ) } );
         return;
      }
   }

   $childwatches->{$pid} = $code;
}

=head2 $loop->unwatch_child( $pid )

This method removes a watch on an existing child process PID.

=cut

sub unwatch_child
{
   my $self = shift;
   my ( $pid ) = @_;

   my $childwatches = $self->{childwatches};

   delete $childwatches->{$pid};

   if( !keys %$childwatches ) {
      $self->detach_signal( CHLD => delete $self->{childwatch_sigid} );
   }
}

=head1 METHODS FOR SUBCLASSES

The following methods are provided to access internal features which are
required by specific subclasses to implement the loop functionality. The use
cases of each will be documented in the above section.

=cut

=head2 $loop->_adjust_timeout( \$timeout )

Shortens the timeout value passed in the scalar reference if it is longer in
seconds than the time until the next queued event on the timer queue. If there
are pending idle handlers, the timeout is reduced to zero.

=cut

sub _adjust_timeout
{
   my $self = shift;
   my ( $timeref, %params ) = @_;

   $$timeref = 0, return if @{ $self->{deferrals} };

   if( defined $self->{sigproxy} and !$params{no_sigwait} ) {
      $$timeref = $MAX_SIGWAIT_TIME if( !defined $$timeref or $$timeref > $MAX_SIGWAIT_TIME );
   }

   my $timequeue = $self->{timequeue};
   return unless defined $timequeue;

   my $nexttime = $timequeue->next_time;
   return unless defined $nexttime;

   my $now = exists $params{now} ? $params{now} : $self->time;
   my $timer_delay = $nexttime - $now;

   if( $timer_delay < 0 ) {
      $$timeref = 0;
   }
   elsif( !defined $$timeref or $timer_delay < $$timeref ) {
      $$timeref = $timer_delay;
   }
}

=head2 $loop->_manage_queues

Checks the timer queue for callbacks that should have been invoked by now, and
runs them all, removing them from the queue. It also invokes all of the
pending idle handlers. Any new idle handlers installed by these are not
invoked yet; they will wait for the next time this method is called.

=cut

sub _manage_queues
{
   my $self = shift;

   my $count = 0;

   my $timequeue = $self->{timequeue};
   $count += $timequeue->fire if $timequeue;

   my $deferrals = $self->{deferrals};
   $self->{deferrals} = [];

   foreach my $code ( @$deferrals ) {
      $code->();
      $count++;
   }

   return $count;
}

=head1 EXTENSIONS

An Extension is a Perl module that provides extra methods in the
C<IO::Async::Loop> or other packages. They are intended to provide extra
functionality that easily integrates with the rest of the code.

Certain base methods take an C<extensions> parameter; an ARRAY reference
containing a list of extension names. If such a list is passed to a method, it
will immediately call a method whose name is that of the base method, prefixed
by the first extension name in the list, separated by C<_>. If the
C<extensions> list contains more extension names, it will be passed the
remaining ones in another C<extensions> parameter.

For example,

 $loop->connect(
    extensions => [qw( FOO BAR )],
    %args
 )

will become

 $loop->FOO_connect(
    extensions => [qw( BAR )],
    %args
 )

This is provided so that extension modules, such as L<IO::Async::SSL> can
easily be invoked indirectly, by passing extra arguments to C<connect> methods
or similar, without needing every module to be aware of the C<SSL> extension.
This functionality is generic and not limited to C<SSL>; other extensions may
also use it.

The following methods take an C<extensions> parameter:

 $loop->connect
 $loop->listen

=cut

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
