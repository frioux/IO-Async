#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007,2008 -- leonerd@leonerd.org.uk

package IO::Async::Loop;

use strict;

our $VERSION = '0.15';

use Carp;

# Never sleep for more than 1 second if a signal proxy is registered, to avoid
# a borderline race condition.
# There is a race condition in perl involving signals interacting with XS code
# that implements blocking syscalls. There is a slight chance a signal will
# arrive in the XS function, before the blocking itself. Perl will not run our
# (safe) deferred signal handler in this case. To mitigate this, if we have a
# signal proxy, we'll adjust the maximal timeout. The signal handler will be 
# run when the XS function returns. 
our $MAX_SIGWAIT_TIME = 1;

BEGIN {
   if ( eval { Time::HiRes::time(); 1 } ) {
      Time::HiRes->import( qw( time ) );
   }
}

=head1 NAME

C<IO::Async::Loop> - core loop of the C<IO::Async> framework

=head1 SYNOPSIS

This module would not be used directly; see the subclasses:

=over 4

=item L<IO::Async::Loop::Select>

=item L<IO::Async::Loop::IO_Poll>

=back

Or other subclasses that may appear on CPAN which are not part of the core
C<IO::Async> distribution.

=head1 DESCRIPTION

This module provides an abstract class which implements the core loop of the
C<IO::Async> framework. Its primary purpose is to store a set of
C<IO::Async::Notifier> objects or subclasses of them. It handles all of the
lower-level set manipulation actions, and leaves the actual IO readiness 
testing/notification to the concrete class that implements it. It also
provides other functionallity such as signal handling, child process managing,
and timers.

=cut

# Internal constructor used by subclasses
sub __new
{
   my $class = shift;

   my $self = bless {
      notifiers    => {}, # {nkey} = notifier
      sigproxy     => undef,
      childmanager => undef,
      timequeue    => undef,
   }, $class;

   return $self;
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

   $self->__notifier_want_readready(  $notifier, $notifier->want_readready  );
   $self->__notifier_want_writeready( $notifier, $notifier->want_writeready );

   $self->_add_noparentcheck( $_ ) for $notifier->children;

   return;
}

=head2 $loop->remove( $notifier )

This method removes a notifier object from the stored collection.

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

   $self->_notifier_removed( $notifier );

   $self->_remove_noparentcheck( $_ ) for $notifier->children;

   return;
}

# Default 'do-nothing' implementation - meant for subclasses to override
sub _notifier_removed
{
   # Ignore
}

# For ::Notifier to call
sub __notifier_want_readready
{
   my $self = shift;
   my ( $notifier, $want_readready ) = @_;
   # Ignore
}

sub __notifier_want_writeready
{
   my $self = shift;
   my ( $notifier, $want_writeready ) = @_;
   # Ignore
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

=head2 $loop->attach_signal( $signal, $code )

This method adds a new signal handler to watch the given signal.

=over 8

=item $signal

The name of the signal to attach to. This should be a bare name like C<TERM>.

=item $code

A CODE reference to the handling function.

=back

Attaching to C<SIGCHLD> is not recommended because of the way all child
processes use it to report their termination. Instead, the C<watch_child>
method should be used to watch for termination of a given child process. A
warning will be printed if C<SIGCHLD> is passed here, but in future versions
of C<IO::Async> this behaviour may be disallowed altogether.

See also L<POSIX> for the C<SIGI<name>> constants.

=cut

sub attach_signal
{
   my $self = shift;
   my ( $signal, $code ) = @_;

   my $sigproxy = $self->{sigproxy} ||= $self->__new_feature( "IO::Async::SignalProxy" );
   $sigproxy->attach( $signal, $code );
}

=head2 $loop->detach_signal( $signal )

This method removes the signal handler for the given signal.

=over 8

=item $signal

The name of the signal to attach to. This should be a bare name like C<TERM>.

=back

=cut

sub detach_signal
{
   my $self = shift;
   my ( $signal ) = @_;

   my $sigproxy = $self->{sigproxy} ||= $self->__new_feature( "IO::Async::SignalProxy" );
   $sigproxy->detach( $signal );

   # TODO: Consider "refcount" signals and cleanup if zero. How do we know if
   # anyone else has a reference to the signal proxy though? Tricky...
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
captures its STDOUT and STDERR streams, and passes them to the given callback
function. For more detail see the C<run_child()> method on the
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

CODE reference to the callback function to run at the allotted time.

=back

If the C<Time::HiRes> module is loaded, then it is used to obtain the current
time which is used for the delay calculation. If this behaviour is required,
the C<Time::HiRes> module must be loaded before C<IO::Async::Loop>:

 use Time::HiRes;
 use IO::Async::Loop;

=cut

sub enqueue_timer
{
   my $self = shift;
   my ( %params ) = @_;

   my $timequeue = $self->{timequeue} ||= $self->__new_feature( "IO::Async::TimeQueue" );

   $timequeue->enqueue( %params );
}

=head2 $loop->cancel_timer( $id )

Cancels a previously-enqueued timer event by removing it from the queue.

=cut

sub cancel_timer
{
   my $self = shift;
   my ( $id ) = @_;

   my $timequeue = $self->{timequeue} ||= $self->__new_feature( "IO::Async::TimeQueue" );

   $timequeue->cancel( $id );
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

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
