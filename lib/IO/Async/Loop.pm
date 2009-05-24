#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007,2009 -- leonerd@leonerd.org.uk

package IO::Async::Loop;

use strict;
use warnings;

our $VERSION = '0.21';

use Carp;

use Socket;
use IO::Socket;
use Time::HiRes qw( time );

# Try to load IO::Socket::INET6 but don't worry if we don't have it
eval { require IO::Socket::INET6 };

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
 use IO::Async::Timer;

 use IO::Async::Loop;

 my $loop = IO::Async::Loop->new();

 $loop->add( IO::Async::Timer->new(
    delay => 10,
    on_expire => sub { print "10 seconds have passed\n" },
 ) );

 $loop->add( IO::Async::Stream->new(
    read_handle => \*STDIN,

    on_read => sub {
       my ( $self, $buffref, $closed ) = @_;

       if( $$buffref =~ s/^(.*)\n// ) {
          print "You typed a line $1\n";
          return 1;
       }

       return 0;
    },
 ) );

 $loop->loop_forever();

=head1 DESCRIPTION

This module provides an abstract class which implements the core loop of the
C<IO::Async> framework. Its primary purpose is to store a set of
C<IO::Async::Notifier> objects or subclasses of them. It handles all of the
lower-level set manipulation actions, and leaves the actual IO readiness 
testing/notification to the concrete class that implements it. It also
provides other functionallity such as signal handling, child process managing,
and timers.

See also the two bundled Loop subclasses:

=over 4

=item L<IO::Async::Loop::Select>

=item L<IO::Async::Loop::IO_Poll>

=back

Or other subclasses that may appear on CPAN which are not part of the core
C<IO::Async> distribution.

=cut

# Internal constructor used by subclasses
sub __new
{
   my $class = shift;

   # We've changed interface since 0.19; detect that this Loop implementation is compatible.
   $class->can( "watch_io" ) or die "$class is too old for IO::Async $VERSION; consider upgrading it\n";

   my $self = bless {
      notifiers    => {}, # {nkey} = notifier
      iowatches    => {}, # {fd} = [ onread, onwrite ] - TODO
      sigattaches  => {}, # {sig} => \@callbacks
      sigproxy     => undef,
      childmanager => undef,
      timequeue    => undef,
   }, $class;

   return $self;
}

=head1 MAGIC CONSTRUCTOR

=head2 $loop = IO::Async::Loop->new()

This function attempts to find a good subclass to use, then calls its
constructor. It works by making a list of likely candidate classes, then
trying each one in turn, C<require>ing the module then calling its C<new>
method. If either of these operations fails, the next subclass is tried. If
no class was successful, then an exception is thrown.

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

=item * IO_Poll and Select

Finally, if no other choice has been made by now, the built-in C<IO_Poll>
module is chosen. This should always work, but in case it doesn't, the
C<Select> module will be chosen afterwards as a last-case attempt. If this
also fails, then the magic constructor itself will throw an exception.

=back

If any of the explicitly-requested loop types (C<$ENV{IO_ASYNC_LOOP}> or
C<$IO::Async::Loop::LOOP>) fails to load then a warning is printed detailing
the error.

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

   $self = __try_new( "IO::Async::Loop::IO_Poll" ) and return $self;
   $self = __try_new( "IO::Async::Loop::Select" )  and return $self;

   croak "Cannot find a suitable candidate class";
}

=head1 METHODS

=cut

#######################
# Notifier management #
#######################

# Internal method
sub _nkey
{
   my $self = shift;
   my ( $notifier ) = @_;

   # References in integer context yield their address. We'll use that as the
   # notifier key
   return $notifier + 0;
}

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

   if( defined $notifier->get_loop ) {
      croak "Cannot add a notifier that is already a member of a loop";
   }

   $self->_add_noparentcheck( $notifier );
}

sub _add_noparentcheck
{
   my $self = shift;
   my ( $notifier ) = @_;

   my $nkey = $self->_nkey( $notifier );

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

   my $nkey = $self->_nkey( $notifier );

   exists $self->{notifiers}->{$nkey} or croak "Notifier does not exist in collection";

   delete $self->{notifiers}->{$nkey};

   $notifier->__set_loop( undef );

   $self->_remove_noparentcheck( $_ ) for $notifier->children;

   return;
}

############
# Features #
############

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
it needs to be removed by the C<detach_signal()> method. Note that this value
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
      # We make special exception to allow the ChildManager to do this
      caller eq "IO::Async::ChildManager" or
         carp "Attaching to SIGCHLD is not advised - use the IO::Async::ChildManager instead";
   }

   if( not $self->{sigattaches}->{$signal} ) {
      my $attaches = $self->{sigattaches}->{$signal} = [];
      $self->watch_signal( $signal, sub { $_->() for @$attaches } );
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
   my $attaches = $self->{sigattaches}->{$signal};
   for (my $i = 0; $i < @$attaches; ) {
      $i++, next unless \$attaches->[$i] == $id;

      splice @$attaches, $i, 1, ();
   }

   if( !@$attaches ) {
      $self->unwatch_signal( $signal );
      delete $self->{sigattaches}->{$signal};
   }
}

=head2 $loop->enable_childmanager

This method enables the child manager, which allows use of the
C<watch_child()> methods without a race condition.

The child manager will be automatically enabled if required; so this method
does not need to be explicitly called for other C<*_child()> methods.

=cut

sub enable_childmanager
{
   my $self = shift;

   $self->{childmanager} ||= $self->__new_feature( "IO::Async::ChildManager" );
}

=head2 $loop->disable_childmanager

This method disables the child manager.

=cut

sub disable_childmanager
{
   my $self = shift;

   if( my $childmanager = $self->{childmanager} ) {
      $childmanager->disable;
      undef $self->{childmanager};
   }
}

=head2 $loop->watch_child( $pid, $code )

This method adds a new handler for the termination of the given child PID.

Because the process represented by C<$pid> may already have exited by the time
this method is called, the child manager should already have been enabled
before it was C<fork()>ed, by calling C<enable_childmanager>. If this is not
done, then a C<SIGCHLD> signal may have been missed, and the exit of this
child process will not be reported.

=cut

sub watch_child
{
   my $self = shift;
   my ( $kid, $code ) = @_;

   my $childmanager = $self->{childmanager} ||=
      $self->__new_feature( "IO::Async::ChildManager" );

   $childmanager->watch_child( $kid, $code );
}

=head2 $pid = $loop->detach_child( %params )

This method creates a new child process to run a given code block. For more
detail, see the C<detach_child()> method on the L<IO::Async::ChildManager>
class.

=cut

sub detach_child
{
   my $self = shift;
   my %params = @_;

   my $childmanager = $self->{childmanager} ||=
      $self->__new_feature( "IO::Async::ChildManager" );

   $childmanager->detach_child( %params );
}

=head2 $code = $loop->detach_code( %params )

This method creates a new detached code object. It is equivalent to calling
the C<IO::Async::DetachedCode> constructor, passing in the given loop. See the
documentation on this class for more information.

=cut

sub detach_code
{
   my $self = shift;
   my %params = @_;

   require IO::Async::DetachedCode;

   return IO::Async::DetachedCode->new(
      %params,
      loop => $self
   );
}

=head2 $loop->spawn_child( %params )

This method creates a new child process to run a given code block or command.
For more detail, see the C<detach_child()> method on the
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

=head2 $loop->open_child( %params )

This method creates a new child process to run the given code block or command,
and attaches filehandles to it that the parent will watch. For more detail,
see the C<open_child()> method on the L<IO::Async::ChildManager> class.

=cut

sub open_child
{
   my $self = shift;
   my %params = @_;

   my $childmanager = $self->{childmanager} ||=
      $self->__new_feature( "IO::Async::ChildManager" );

   $childmanager->open_child( %params );
}

=head2 $loop->run_child( %params )

This method creates a new child process to run the given code block or command,
captures its STDOUT and STDERR streams, and passes them to the given
continuation. For more detail see the C<run_child()> method on the
L<IO::Async::ChildManager> class.

=cut

sub run_child
{
   my $self = shift;
   my %params = @_;

   my $childmanager = $self->{childmanager} ||=
      $self->__new_feature( "IO::Async::ChildManager" );

   $childmanager->run_child( %params );
}

# For subclasses to call
sub _adjust_timeout
{
   my $self = shift;
   my ( $timeref, %params ) = @_;

   if( defined $self->{sigproxy} and !$params{no_sigwait} ) {
      $$timeref = $MAX_SIGWAIT_TIME if( !defined $$timeref or $$timeref > $MAX_SIGWAIT_TIME );
   }

   my $timequeue = $self->{timequeue};
   return unless defined $timequeue;

   my $nexttime = $timequeue->next_time;
   return unless defined $nexttime;

   my $now = exists $params{now} ? $params{now} : time();
   my $timer_delay = $nexttime - $now;

   if( $timer_delay < 0 ) {
      $$timeref = 0;
   }
   elsif( !defined $$timeref or $timer_delay < $$timeref ) {
      $$timeref = $timer_delay;
   }
}

# For subclasses to call
sub _build_time
{
   my $self = shift;
   my %params = @_;

   my $time;
   if( exists $params{time} ) {
      $time = $params{time};
   }
   elsif( exists $params{delay} ) {
      my $now = exists $params{now} ? $params{now} : time();

      $time = $now + $params{delay};
   }
   else {
      croak "Expected either 'time' or 'delay' keys";
   }

   return $time;
}

=head2 $id = $loop->enqueue_timer( %params )

This method installs a callback which will be called at the specified time.
The time may either be specified as an absolute value (the C<time> key), or
as a delay from the time it is installed (the C<delay> key).

The returned C<$id> value can be used to identify the timer in case it needs
to be cancelled by the C<cancel_timer()> method. Note that this value may be
an object reference, so if it is stored, it should be released after it has
been fired or cancelled, so the object itself can be freed.

The C<%params> hash takes the following keys:

=over 8

=item time => NUM

The absolute system timestamp to run the event.

=item delay => NUM

The delay after now at which to run the event.

=item now => NUM

The time to consider as now; defaults to C<time()> if not specified.

=item code => CODE

CODE reference to the continuation to run at the allotted time.

=back

For more powerful timer functionallity as a C<IO::Async::Notifier> (so it can
be used as a child within another Notifier), see instead the
L<IO::Async::Timer> object.

=cut

sub enqueue_timer
{
   my $self = shift;
   my ( %params ) = @_;

   my $timequeue = $self->{timequeue} ||= $self->__new_feature( "IO::Async::Internals::TimeQueue" );

   $params{time} = $self->_build_time( %params );

   $timequeue->enqueue( %params );
}

=head2 $loop->cancel_timer( $id )

Cancels a previously-enqueued timer event by removing it from the queue.

=cut

sub cancel_timer
{
   my $self = shift;
   my ( $id ) = @_;

   my $timequeue = $self->{timequeue} ||= $self->__new_feature( "IO::Async::Internals::TimeQueue" );

   $timequeue->cancel( $id );
}

=head2 $newid = $loop->requeue_timer( $id, %params )

Reschedule an existing timer, moving it to a new time. The old timer is
removed and will not be invoked.

The C<%params> hash takes the same keys as C<enqueue_timer()>, except for the
C<code> argument.

The requeue operation may be implemented as a cancel + enqueue, which may
mean the ID changes. Be sure to store the returned C<$newid> value if it is
required.

=cut

sub requeue_timer
{
   my $self = shift;
   my ( $id, %params ) = @_;

   my $timequeue = $self->{timequeue} ||= $self->__new_feature( "IO::Async::Internals::TimeQueue" );

   $params{time} = $self->_build_time( %params );

   $timequeue->requeue( $id, %params );
}

=head2 $loop->resolve( %params )

This method performs a single name resolution operation. It uses an
internally-stored C<IO::Async::Resolver> object. For more detail, see the
C<resolve()> method on the L<IO::Async::Resolver> class.

=cut

sub resolve
{
   my $self = shift;
   my ( %params ) = @_;

   my $resolver = $self->{resolver} ||= $self->__new_feature( "IO::Async::Resolver" );

   $resolver->resolve( %params );
}

=head2 $loop->connect( %params )

This method performs a non-blocking connect operation. It uses an
internally-stored C<IO::Async::Connector> object. For more detail, see the
C<connect()> method on the L<IO::Async::Connector> class.

=cut

sub connect
{
   my $self = shift;
   my ( %params ) = @_;

   my $connector = $self->{connector} ||= $self->__new_feature( "IO::Async::Connector" );

   $connector->connect( %params );
}

=head2 $loop->listen( %params )

This method sets up a listening socket. It uses an internally-stored
C<IO::Async::Listener> object. For more detail, see the C<listen()> method on
the L<IO::Async::Listener> class.

=cut

sub listen
{
   my $self = shift;
   my ( %params ) = @_;

   my $listener = $self->{listener} ||= $self->__new_feature( "IO::Async::Listener" );

   $listener->listen( %params );
}

###################
# Looping support #
###################

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

   croak "Expected that $self overrides ->loop_once()";
}

=head2 $loop->loop_forever()

This method repeatedly calls the C<loop_once> method with no timeout (i.e.
allowing the underlying mechanism to block indefinitely), until the
C<loop_stop> method is called from an event callback.

=cut

sub loop_forever
{
   my $self = shift;

   $self->{still_looping} = 1;

   while( $self->{still_looping} ) {
      $self->loop_once( undef );
   }
}

=head2 $loop->loop_stop()

This method cancels a running C<loop_forever>, and makes that method return.
It would be called from an event callback triggered by an event that occured
within the loop.

=cut

sub loop_stop
{
   my $self = shift;
   
   $self->{still_looping} = 0;
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

   croak "Cannot create a new socket() without a family" unless $family;

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
   # usually happens if getaddrinfo() returns an AF_INET6 address but we don't
   # have IO::Socket::INET6 loaded. In this case we'll return a generic one.
   # It won't be in the specific subclass but that's the best we can do. And
   # it will still work as a generic socket.
   return IO::Socket->new->socket( $family, $socktype, $proto );
}

=head2 ( $S1, $S2 ) = $loop->socketpair( $family, $socktype, $proto )

An abstraction of the C<socketpair()> syscall, where any argument may be
missing (or given as C<undef>).

If C<$family> is not provided, a suitable value will be provided by the OS
(likely C<AF_UNIX> on POSIX-based platforms). If C<$socktype> is not provided,
then C<SOCK_STREAM> will be used.

=cut

sub socketpair
{
   my $self = shift;
   my ( $family, $socktype, $proto ) = @_;

   # PF_UNSPEC and undef are both false
   $family ||= AF_UNIX;

   # SOCK_STREAM is the most likely
   defined $socktype or $socktype = SOCK_STREAM;

   defined $proto or $proto = 0;

   return IO::Socket->new->socketpair( $family, $socktype, $proto );
}

=head2 ( $rd, $wr ) = $loop->pipepair()

An abstraction of the C<pipe()> syscall, which returns the two new handles.

=cut

sub pipepair
{
   my $self = shift;

   pipe( my ( $rd, $wr ) ) or return;
   return ( $rd, $wr );
}

=head2 ( $rdA, $wrA, $rdB, $wrB ) = $loop->pipequad()

This method is intended for creating two pairs of filehandles that are linked
together, suitable for passing as the STDIN/STDOUT pair to a child process.
After this function returns, C<$rdA> and C<$wrA> will be a linked pair, as
will C<$rdB> and C<$wrB>.

On platforms that support C<socketpair()>, this implementation will be
preferred, in which case C<$rdA> and C<$wrB> will actually be the same
filehandle, as will C<$rdB> and C<$wrA>. This saves a file descriptor in the
parent process.

When creating a C<IO::Async::Stream> or subclass of it, the C<read_handle>
and C<write_handle> parameters should always be used.

 my ( $childRd, $myWr, $myRd, $childWr ) = $loop->pipequad();

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

   # Prefer socketpair()
   if( my ( $S1, $S2 ) = $self->socketpair() ) {
      return ( $S1, $S2, $S2, $S1 );
   }

   # Can't do that, fallback on pipes
   my ( $rdA, $wrA ) = $self->pipepair() or return;
   my ( $rdB, $wrB ) = $self->pipepair() or return;

   return ( $rdA, $wrA, $rdB, $wrB );
}

=head2 $signum = $loop->signame2num( $signame )

This utility method converts a signal name (such as "TERM") into its system-
specific signal number. This may be useful to pass to C<POSIX::SigSet> or use
in other places which use numbers instead of symbolic names.

Note that this function is not an object method, and is not exported.

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

=head1 SUBCLASS METHODS

As C<IO::Async::Loop> is an abstract base class, specific subclasses of it are
required to implement certain methods that form the base level of
functionallity. They are not recommended for applications to use; see instead
the various event objects or higher level methods listed above.

These methods should be considered as part of the interface contract required
to implement a C<IO::Async::Loop> subclass.

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
# This is done so that we can recognise and abort on a pre-0.20 Loop
# implementation.
sub __watch_io
{
   my $self = shift;
   my %params = @_;

   my $handle = $params{handle} or croak "Expected 'handle'";

   my $watch = ( $self->{iowatches}->{$handle->fileno} ||= [] );

   $watch->[0] = $handle;

   if( $params{on_read_ready} ) {
      $watch->[1] = $params{on_read_ready};
   }

   if( $params{on_write_ready} ) {
      $watch->[2] = $params{on_write_ready};
   }
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

   my $handle = $params{handle} or croak "Expected 'handle'";

   my $watch = $self->{iowatches}->{$handle->fileno} or return;

   if( $params{on_read_ready} ) {
      undef $watch->[1];
   }

   if( $params{on_write_ready} ) {
      undef $watch->[2];
   }

   if( not $watch->[1] and not $watch->[2] ) {
      delete $self->{iowatches}->{$handle->fileno};
   }
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

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
