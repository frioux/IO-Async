#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007 -- leonerd@leonerd.org.uk

package IO::Async::Loop;

use strict;

our $VERSION = '0.10';

use Carp;
use warnings qw();

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

=item L<IO::Async::Loop::IO_Perl>

=item L<IO::Async::Loop::GMainLoop>

=back

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

   if( defined $notifier->__memberof_loop ) {
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

   $notifier->__memberof_loop( $self );

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

   $notifier->__memberof_loop( undef );

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
sub __notifier_want_writeready
{
   my $self = shift;
   my ( $notifier, $want_writeready ) = @_;
   # Ignore
}

=head2 $sigproxy = $loop->get_sigproxy

This method returns the associated C<IO::Async::SignalProxy> object for the
loop. If there is not yet such a proxy, a new one is constructed and added to
the loop.

Use of this method is deprecated as not all C<IO::Async::Loop> subclasses will
be able to support it. All signal handling should be done by calling
C<attach_signal()> or C<detach_signal()> directly.

=cut

sub get_sigproxy
{
   my $self = shift;

   warnings::warnif "deprecated",
      "IO::Async::Loop->get_sigproxy is deprecated; use ->attach_signal() or ->detach_signal() instead";

   return $self->_get_sigproxy;
}

sub _get_sigproxy
{
   my $self = shift;

   return $self->{sigproxy} if defined $self->{sigproxy};

   require IO::Async::SignalProxy;
   my $sigproxy = IO::Async::SignalProxy->new();
   $self->add( $sigproxy );

   return $self->{sigproxy} = $sigproxy;
}

=head2 $loop->attach_signal( $signal, $code )

This method adds a new signal handler to watch the given signal.

=over 8

=item $signal

The name of the signal to attach to. This should be a bare name like C<TERM>.

=item $code

A CODE reference to the handling function.

=back

See also L<POSIX> for the C<SIGI<name>> constants.

=cut

sub attach_signal
{
   my $self = shift;
   my ( $signal, $code ) = @_;

   my $sigproxy = $self->_get_sigproxy;
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

   my $sigproxy = $self->_get_sigproxy;
   $sigproxy->detach( $signal );

   # TODO: Consider "refcount" signals and cleanup if zero. How do we know if
   # anyone else has a reference to the signal proxy though? Tricky...
}

=head2 $loop->enable_childmanager

This method creates a new C<IO::Async::ChildManager> object and attaches the
C<SIGCHLD> signal to call the manager's C<SIGCHLD()> method. The manager is
stored in the loop and can be obtained using the C<get_childmanager()> method.

=cut

sub enable_childmanager
{
   my $self = shift;

   defined $self->{childmanager} and
      croak "ChildManager already enabled for this loop";

   require IO::Async::ChildManager;
   my $childmanager = IO::Async::ChildManager->new( loop => $self );
   $self->attach_signal( CHLD => sub { $childmanager->SIGCHLD } );

   $self->{childmanager} = $childmanager;
}

=head2 $loop->disable_childmanager

This method detaches the contained C<IO::Async::ChildManager> from the
C<SIGCHLD> signal and destroys it. After this method is called, the C<SIGCHLD>
slot is released.

=cut

sub disable_childmanager
{
   my $self = shift;

   defined $self->{childmanager} or
      croak "ChildManager not enabled for this loop";

   $self->detach_signal( 'CHLD' );
   undef $self->{childmanager};
}

=head2 $manager = $loop->get_childmanager

This method returns the associated C<IO::Async::ChildManager> object for the
loop. If there is not yet such an object (namely; that the
C<enable_childmanager()> method has not yet been called), an exception is
thrown.

Use of this method is deprecated as not all C<IO::Async::Loop> subclasses will
be able to support it. All child management should be done by calling
C<watch_child()>, C<detach_child()>, or C<spawn_child()> directly.

=cut

sub get_childmanager
{
   my $self = shift;

   warnings::warnif "deprecated",
      "IO::Async::Loop->get_childmanager is deprecated; use ->watch_child(), ->detach_child() or ->spawn_child() instead";

   return $self->{childmanager} if defined $self->{childmanager};
   croak "ChildManager not enabled in Loop";
}

=head2 $loop->watch_child( $pid, $code )

This method adds a new handler for the termination of the given child PID.

=cut

sub watch_child
{
   my $self = shift;
   my ( $kid, $code ) = @_;

   my $childmanager = $self->{childmanager} or
      croak "ChildManager not enabled in Loop";

   $childmanager->watch( $kid, $code );
}

=head2 $loop->detach_child( %params )

This method creates a new child process to run a given code block. For more
detail, see the C<detach_child()> method on the L<IO::Async::ChildManager>
class.

=cut

sub detach_child
{
   my $self = shift;
   my %params = @_;

   my $childmanager = $self->{childmanager} or
      croak "ChildManager not enabled in Loop";

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

   my $childmanager = $self->{childmanager} or
      croak "ChildManager not enabled in Loop";

   $childmanager->spawn( %params );
}

sub __enable_timer
{
   my $self = shift;

   defined $self->{timequeue} and
      croak "Timer already enabled for this loop";

   require IO::Async::TimeQueue;
   my $timequeue = IO::Async::TimeQueue->new();

   $self->{timequeue} = $timequeue;
}

# For subclasses to call
sub _adjust_timeout
{
   my $self = shift;
   my ( $timeref ) = @_;

   if( defined $self->{sigproxy} ) {
      $$timeref = $MAX_SIGWAIT_TIME if( !defined $$timeref or $$timeref > $MAX_SIGWAIT_TIME );
   }

   my $timequeue = $self->{timequeue};
   return unless defined $timequeue;

   my $nexttime = $timequeue->next_time;
   return unless defined $nexttime;

   my $now = time();
   my $timer_delay = $nexttime - $now;

   if( $timer_delay < 0 ) {
      $$timeref = 0;
   }
   elsif( $timer_delay < \$timeref ) {
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

   defined $self->{timequeue} or $self->__enable_timer;

   my $timequeue = $self->{timequeue};

   $timequeue->enqueue( %params );
}

=head2 $loop->canel_timer( $id )

Cancels a previously-enqueued timer event by removing it from the queue.

=cut

sub cancel_timer
{
   my $self = shift;
   my ( $id ) = @_;

   defined $self->{timequeue} or $self->__enable_timer;

   my $timequeue = $self->{timequeue};

   $timequeue->cancel( $id );
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
