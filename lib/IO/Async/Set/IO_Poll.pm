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

To integrate with existing code that uses an C<IO::Poll>, a pair of methods
C<pre_poll()> and C<post_poll()> can be called immediately before and after 
the C<poll()> method on an C<IO::Poll> object. The C<pre_poll()> method 
registers the appropriate mask bits on the C<IO::Poll> object, and the 
C<post_poll()> method inspects the result and invokes the C<readready()> or 
C<writeready()> methods on the notifiers.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $set = IO::Async::Set::IO_Poll->new( %args )

This function returns a new instance of a C<IO::Async::Set::IO_Poll> object.
It takes the following named arguments:

=over 8

=item C<poll>

The C<IO::Poll> object to use for notification

=back

=cut

sub new
{
   my $class = shift;
   my ( %args ) = @_;

   my $poll = delete $args{poll};

   my $self = $class->__new( %args );

   $self->{poll} = $poll;

   return $self;
}

=head1 METHODS

=cut

=head2 $ioan->pre_poll( $poll, \$timeout )

This method adds the appropriate mask bits to an C<IO::Poll> object.

=over 8

=item $poll

Reference to the C<IO::Poll> object

=item \$timeout

Scalar reference to the timeout value

=back

=cut

sub pre_poll
{
   my $self = shift;

   my $notifiers = $self->{notifiers};
   my $poll      = $self->{poll};

   foreach my $fileno ( keys %$notifiers ) {
      my $notifier = $notifiers->{$fileno};

      $poll->mask( $notifier->sock, POLLIN | ( $notifier->want_writeready ? POLLOUT : 0 ) );
   }

   return;
}

=head2 $ioan->post_poll( $poll )

This method checks the returned event list from a C<IO::Poll::poll()> call,
and calls any of the notification methods on the listener that are
appropriate.

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

   foreach my $fileno ( keys %$notifiers ) {
      my $notifier = $notifiers->{$fileno};

      my $events = $poll->events( $notifier->sock ) or next;

      if( $events & POLLIN ) {
         $notifier->read_ready;
      }

      if( $events & POLLOUT ) {
         $notifier->write_ready;
      }
   }
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
