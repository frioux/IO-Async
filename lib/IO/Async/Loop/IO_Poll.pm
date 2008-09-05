#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007,2008 -- leonerd@leonerd.org.uk

package IO::Async::Loop::IO_Poll;

use strict;

our $VERSION = '0.17';

use base qw( IO::Async::Loop );

use Carp;

use IO::Poll qw( POLLIN POLLOUT POLLHUP );

use POSIX qw( EINTR );

# IO::Poll version 0.05 contain a bug whereby the ->remove() method doesn't
# properly clean up all the references to the handles. If the version we're
# using is in this range, we have to clean it up ourselves.
use constant IO_POLL_REMOVE_BUG => ( $IO::Poll::VERSION == '0.05' );

=head1 NAME

C<IO::Async::Loop::IO_Poll> - a Loop using an C<IO::Poll> object

=head1 SYNOPSIS

 use IO::Async::Loop::IO_Poll;

 my $loop = IO::Async::Loop::IO_Poll->new();

 $loop->add( ... );

 $loop->loop_forever();

Or

 while(1) {
    $loop->loop_once();
    ...
 }

Or

 use IO::Poll;
 use IO::Async::Loop::IO_Poll;

 my $poll = IO::Poll->new();
 my $loop = IO::Async::Loop::IO_Poll->new( poll => $poll );

 $loop->add( ... );

 while(1) {
    my $timeout = ...
    my $ret = $poll->poll( $timeout );
    $loop->post_poll();
 }

=head1 DESCRIPTION

This subclass of C<IO::Async::Loop> uses an C<IO::Poll> object to perform
read-ready and write-ready tests.

To integrate with existing code that uses an C<IO::Poll>, a C<post_poll()> can
be called immediately after the C<poll()> method on the contained C<IO::Poll>
object. The appropriate mask bits are maintained on the C<IO::Poll> object
when notifiers are added or removed from the set, or when they change their
C<want_writeready> status. The C<post_poll()> method inspects the result bits
and invokes the C<on_read_ready()> or C<on_write_ready()> methods on the
notifiers.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $loop = IO::Async::Loop::IO_Poll->new( %args )

This function returns a new instance of a C<IO::Async::Loop::IO_Poll> object.
It takes the following named arguments:

=over 8

=item C<poll>

The C<IO::Poll> object to use for notification. Optional; if a value is not
given, a new C<IO::Poll> object will be constructed.

=back

=cut

sub new
{
   my $class = shift;
   my ( %args ) = @_;

   my $poll = delete $args{poll};

   $poll ||= IO::Poll->new();

   my $self = $class->__new( %args );

   $self->{poll} = $poll;

   return $self;
}

=head1 METHODS

=cut

=head2 $count = $loop->post_poll( $poll )

This method checks the returned event list from a C<IO::Poll::poll()> call,
and calls any of the notification methods or callbacks that are appropriate.
It returns the total number of callbacks that were invoked; that is, the
total number of C<on_read_ready> and C<on_write_ready> methods on Notifiers,
and the total number of TimeQueue event callbacks.

=over 8

=item $poll

Reference to the C<IO::Poll> object

=back

=cut

sub post_poll
{
   my $self = shift;

   my $notifiers = $self->{notifiers};
   my $poll      = $self->{poll};

   # Build a list of the notifiers that are ready, then fire the callbacks
   # afterwards. This avoids races and other bad effects if any of the
   # callbacks happen to change the notifiers in the set
   my @readready;
   my @writeready;

   foreach my $nkey ( keys %$notifiers ) {
      my $notifier = $notifiers->{$nkey};

      if( defined( my $rhandle = $notifier->read_handle ) ) {
         my $revents = $poll->events( $rhandle );

         # We have to test separately because kernel doesn't report POLLIN when
         # a pipe gets closed.
         if( $revents & (POLLIN|POLLHUP) ) {
            push @readready, $notifier;
         }
      }

      if( defined( my $whandle = $notifier->write_handle ) ) {
         my $wevents = defined $whandle ? $poll->events( $whandle ) : 0;

         if( $wevents & POLLOUT or
             ( $notifier->want_writeready and $wevents & POLLHUP ) ) {
            push @writeready, $notifier;
         }
      }
   }

   my $count = @readready + @writeready;

   $_->on_read_ready foreach @readready;
   $_->on_write_ready foreach @writeready;

   # Since we have no way to know if the timeout occured, we'll have to
   # attempt to fire any waiting timeout events anyway

   my $timequeue = $self->{timequeue};
   $count += $timequeue->fire if $timequeue;

   return $count;
}

=head2 $count = $loop->loop_once( $timeout )

This method calls the C<poll()> method on the stored C<IO::Poll> object,
passing in the value of C<$timeout>, and then runs the C<post_poll()> method
on itself. It returns the total number of callbacks invoked by the 
C<post_poll()> method, or C<undef> if the underlying C<poll()> method returned
an error.

=cut

# override
sub loop_once
{
   my $self = shift;
   my ( $timeout ) = @_;

   $self->_adjust_timeout( \$timeout );

   my $poll = $self->{poll};

   my $pollret;

   # There is a bug in IO::Poll at least version 0.07, where poll() with no
   # registered masks returns immediately, rather than waiting for a timeout
   # This has been reported: 
   #   http://rt.cpan.org/Ticket/Display.html?id=25049
   if( $poll->handles ) {
      $pollret = $poll->poll( $timeout );

      if( ( $pollret == -1 and $! == EINTR ) or $pollret == 0 
              and defined $self->{sigproxy} ) {
         # A signal occured and we have a sigproxy. Allow one more poll call
         # with zero timeout. If it finds something, keep that result. If it
         # finds nothing, keep -1

         # Preserve $! whatever happens
         local $!;

         my $secondattempt = $poll->poll( 0 );
         $pollret = $secondattempt if $secondattempt > 0;
      }
   }
   else {
      # Workaround - we'll use select() to fake a millisecond-accurate sleep
      $pollret = select( undef, undef, undef, $timeout );
   }

   return undef unless defined $pollret;

   return $self->post_poll();
}

# override
sub _notifier_removed
{
   my $self = shift;
   my ( $notifier ) = @_;

   my $poll = $self->{poll};

   my $rhandle = $notifier->read_handle;
   my $whandle = $notifier->write_handle;

   if( defined $rhandle ) {
      $poll->remove( $rhandle );
      # This sort of mangling is usually frowned-upon because it relies on
      # knowledge of the internals of IO::Poll. But we know those internals
      # because it is conditional on a specific version number of IO::Poll, so we
      # can rely on the internal layout for that particular version.
      delete $poll->[0]{fileno $rhandle} if IO_POLL_REMOVE_BUG;
   }

   if( defined $whandle and ( not defined $rhandle or $whandle != $rhandle ) ) {
      $poll->remove( $whandle );
      delete $poll->[0]{fileno $whandle} if IO_POLL_REMOVE_BUG;
   }
}

# override
# For ::Notifier to call
sub __notifier_want_readready
{
   my $self = shift;
   my ( $notifier, $want_readready ) = @_;

   my $poll = $self->{poll};

   my $rhandle = $notifier->read_handle or return;

   my $curmask = $poll->mask( $rhandle ) || 0;
   $poll->mask( $rhandle, $want_readready ? $curmask | POLLIN : $curmask & ~POLLIN );
}

# override
# For ::Notifier to call
sub __notifier_want_writeready
{
   my $self = shift;
   my ( $notifier, $want_writeready ) = @_;

   my $poll = $self->{poll};

   my $whandle = $notifier->write_handle or return;

   my $curmask = $poll->mask( $whandle ) || 0;
   $poll->mask( $whandle, $want_writeready ? $curmask | POLLOUT : $curmask & ~POLLOUT );
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
