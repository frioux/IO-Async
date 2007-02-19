#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007 -- leonerd@leonerd.org.uk

package IO::Async::Set::IO_Poll;

use strict;

our $VERSION = '0.01';

use base qw( IO::Async::Set );

use Carp;

use IO::Poll qw( POLLIN POLLOUT );

=head1 NAME

C<IO::Async::Set::IO_Poll> - a class that maintains a set of
C<IO::Async::Notifier> objects by using an C<IO::Poll> object.

=head1 DESCRIPTION

This subclass of C<IO::Async::Notifier> uses an C<IO::Poll> object to perform
read-ready and write-ready tests.

To integrate with existing code that uses an C<IO::Poll>, a C<post_poll()> can
be called immediately after the C<poll()> method on the contained C<IO::Poll>
object. The appropriate mask bits are maintained on the C<IO::Poll> object
when notifiers are added or removed from the set, or when they change their
C<want_writeready> status. The C<post_poll()> method inspects the result bits
and invokes the C<read_ready()> or C<write_ready()> methods on the notifiers.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $set = IO::Async::Set::IO_Poll->new( %args )

This function returns a new instance of a C<IO::Async::Set::IO_Poll> object.
It takes the following named arguments:

=over 8

=item C<poll>

The C<IO::Poll> object to use for notification. Optional; if a value is not
given, a new C<IO::Poll> will be constructed.

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

=head2 $set->post_poll( $poll )

This method checks the returned event list from a C<IO::Poll::poll()> call,
and calls any of the notification methods or callbacks that are appropriate.

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

   foreach my $nkey ( keys %$notifiers ) {
      my $notifier = $notifiers->{$nkey};

      my $events = $poll->events( $notifier->handle ) or next;

      if( $events & POLLIN ) {
         $notifier->read_ready;
      }

      if( $events & POLLOUT ) {
         $notifier->write_ready;
      }
   }
}

=head2 $set->loop_once( $timeout )

This method calls the C<poll()> method on the stored C<IO::Poll> object,
passing in the value of C<$timeout>, and then runs the C<post_poll()> method
on itself.

=cut

sub loop_once
{
   my $self = shift;
   my ( $timeout ) = @_;

   my $poll = $self->{poll};
   $poll->poll( $timeout );

   $self->post_poll();
}

=head2 $set->loop_forever()

This method repeatedly calls the C<loop_once> method with no timeout (i.e.
allowing the C<poll()> method to block indefinitely), until the C<loop_stop>
method is called from an event callback.

=cut

sub loop_forever
{
   my $self = shift;

   $self->{still_looping} = 1;

   while( $self->{still_looping} ) {
      $self->loop_once( undef );
   }
}

=head2 $set->loop_stop()

This method cancels a running C<loop_forever>, and makes that method return.
It would be called from an event callback triggered by an event that occured
within the loop.

=cut

sub loop_stop
{
   my $self = shift;
   
   $self->{still_looping} = 0;
}

# override
sub remove
{
   my $self = shift;
   my ( $notifier ) = @_;

   my $poll = $self->{poll};

   $self->SUPER::remove( $notifier );

   $poll->remove( $notifier->handle );
}

# override
# For ::Notifier to call
sub __notifier_want_writeready
{
   my $self = shift;
   my ( $notifier, $want_writeready ) = @_;

   my $poll = $self->{poll};

   $poll->mask( $notifier->handle, POLLIN | ( $want_writeready ? POLLOUT : 0 ) );
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
