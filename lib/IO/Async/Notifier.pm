#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006 -- leonerd@leonerd.org.uk

package IO::Async::Notifier;

use strict;

our $VERSION = '0.01';

use Carp;

# We need to be careful about what sort of polling-loop code we
# unconditionally "use" here.
use IO::Poll qw( POLLIN POLLOUT );

=head1 NAME

C<IO::Async::Notifier> - a class which implements event callbacks for a
non-blocking file descriptor

=head1 DESCRIPTION

This module provides a base class for implementing non-blocking IO on file
descriptors. The object provides ways to integrate with existing asynchronous
IO handling code simple.

For C<select()>-based code, a pair of methods C<pre_select()> and
C<post_select()> can be called immediately before and after a C<select()>
call. The relevant bit in the read-ready bitvector is always set by the
C<pre_select()> method, but the corresponding bit in write-ready vector is
set depending on the state of the C<'want_writeready'> property. The
C<post_select()> will invoke the listener object's C<readready()> or
C<writeready()> methods.

For C<IO::Poll>-based code, a pair of methods C<pre_poll()> and C<post_poll()>
can be called immediately before and after the C<poll()> method on an
C<IO::Poll> object. The C<pre_poll()> method registers the appropriate mask
bits on the C<IO::Poll> object, and the C<post_poll()> method inspects the
result and invokes the C<readready()> or C<writeready()> methods on the
listener.

=head2 Listener

Each C<IO::Async::Notifier> object stores a reference to a listener object.
This object will be informed of read- or write-readyness by the
C<post_select()> method by the following methods on the listener:

 $listener->readready();

 $listener->writeready();

None of these methods will be passed any arguments; the object itself should
track any data it requires. If either of the readyness methods calls the
C<socket_closed()> method, then the socket is internally marked as closed
within the object. After this happens, it will no longer register bits in the
bitvectors in C<pre_select()>, and will remove the mask in C<pre_poll()>.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $ioan = IO::Async::Notifier->new( sock => $sock, listener => $listener )

This function returns a new instance of a C<IO::Async::Notifier> object.
The transceiver wraps a connected socket and a receiver.

If the string C<'self'> is passed instead, then the object will call
notification events on itself. This will be useful in implementing subclasses,
which internally implement the notification methods.

=over 8

=item $sock

The socket object to wrap. Must implement C<fileno> method in way that
C<IO::Socket> does.

=item $listener

An object reference to notify on events, or the string C<'self'>

=back

=cut

sub new
{
   my $class = shift;
   my ( %params ) = @_;

   my $sock = $params{sock};
   unless( ref( $sock ) and $sock->can( "fileno" ) ) {
      croak 'Expected that $sock can fileno()';
   }

   my $self = bless {
      sock => $sock,
      want_writeready => $params{want_writeready} || 0,
   }, $class;

   my $listener = $params{listener};
   $listener = $self if( $listener eq "self" );

   $self->{listener} = $listener;

   return $self;
}

=head1 METHODS

=cut

=head2 $value = $ioan->want_writeready

=head2 $oldvalue = $ioan->want_writeready( $newvalue )

This is the accessor for the C<want_writeready> property, which defines
whether the object will register interest in the write-ready bitvector in a
C<select()> call, or whether to register the C<POLLOUT> bit in a C<IO::Poll>
mask.

=cut

sub want_writeready
{
   my $self = shift;
   my $old = $self->{want_writeready};
   $self->{want_writeready} = $_[0] if @_;
   return $old;
}

=head2 $ioan->pre_select( \$readvec, \$writevec, \$exceptvec, \$timeout )

This method prepares the bitvectors for a C<select()> call, setting the bits
that this notifier is interested in. It will always set the bit in the read
vector, but will only set it in the write vector if the object's
C<want_writeready()> property is true. Neither the exception vector nor the
timeout are affected.

=over 8

=item \$readvec

=item \$writevec

=item \$exceptvec

Scalar references to the reading, writing and exception bitvectors

=item \$timeout

Scalar reference to the timeout value

=back

=cut

sub pre_select
{
   my $self = shift;
   my ( $readref, $writeref, $exceptref, $timeref ) = @_;

   my $sock = $self->{sock};
   return unless( defined $sock );

   my $fileno = $sock->fileno;
   return unless( defined $fileno );

   vec( $$readref,  $fileno, 1 ) = 1;

   vec( $$writeref, $fileno, 1 ) = 1 if( $self->want_writeready );
}

=head2 $ioan->post_select( $readvec, $writevec, $exceptvec )

This method checks the returned bitvectors from a C<select()> call, and calls
any of the notification methods on the listener that are appropriate.

=over 8

=item $readvec

=item $writevec

=item $exceptvec

Scalars containing the read-ready, write-ready and exception bitvectors

=back

=cut

sub post_select
{
   my $self = shift;
   my ( $readvec, $writevec, $exceptvec ) = @_;

   my $sock = $self->{sock};
   return unless( defined $sock );

   my $fileno = $sock->fileno;
   return unless( defined $fileno );

   my $listener = $self->{listener};

   if( vec( $readvec, $fileno, 1 ) ) {
      $listener->readready;
   }

   if( vec( $writevec, $fileno, 1 ) ) {
      $listener->writeready;
   }
}

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
   my ( $poll, $timeref ) = @_;

   my $sock = $self->{sock};
   return unless( defined $sock );

   $poll->mask( $sock, POLLIN | ( $self->want_writeready ? POLLOUT : 0 ) );
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
   my ( $poll ) = @_;

   my $sock = $self->{sock};

   my $events = $poll->events( $sock ) or return;

   my $listener = $self->{listener};

   if( $events & POLLIN ) {
      $listener->readready;
   }

   if( $events & POLLOUT ) {
      $listener->writeready;
   }
}

=head2 $ioan->socket_closed()

This method marks that the socket has been closed. After this has been called,
the object will no longer mark any bits in the C<pre_select()> call, nor
respond to any set bits in the C<post_select()> call.

=cut

sub socket_closed
{
   my $self = shift;

   my $sock = $self->{sock};
   return unless( defined $sock );

   $sock->close;
   undef $sock;
   delete $self->{sock};
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 SEE ALSO

=over 4

=item *

L<IO::Socket> - Object interface to socket communications

=item *

L<IO::Select> - OO interface to select system call

=back

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
