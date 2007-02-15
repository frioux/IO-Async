#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006 -- leonerd@leonerd.org.uk

package IO::Async::Buffer;

use strict;

our $VERSION = '0.01';

use base qw( IO::Async::Notifier );

use Carp;

=head1 NAME

C<IO::Async::Buffer> - a class which implements asynchronous sending
and receiving data buffers around a connected handle

=head1 DESCRIPTION

This module provides a class for implementing asynchronous communications
buffers behind connected handles. It provides buffering for both incoming and
outgoing data, which are transferred to or from the actual handle as
appropriate.

Data can be added to the outgoing buffer at any time using the C<send()>
method, and will be flushed whenever the underlying handle is notified as
being write-ready. Whenever the handle is notified as being read-ready, the
data is read in from the handle, and the transceiver object's receiver is
signaled to indicate the data is available.

=head2 Receivers

Each C<IO::Async::Buffer> object stores a reference to a receiver
object.  This is any object that supports a C<< ->incoming_data() >> method.
When data arrives in the incoming data buffer, the transceiver calls this
method on its receiver to indicate the data is available. It is called in the
following manner:

 $again = $receiver->incoming_data( \$buffer, $handleclosed )

A reference to the incoming data buffer is passed, which is a plain perl
string. The C<incoming_data()> method should inspect and remove any data it
likes, but is not required to remove all, or indeed any of the data. Any data
remaining in the buffer will be preserved for the next call, the next time more
data is received from the handle.

In this way, it is easy to implement code that reads records of some form when
completed, but ignores partially-received records, until all the data is
present. If the method is confident no more useful data remains, it should
return a false value. If not, it should return a true value, and the method
will be called again. This makes it easy to implement code that handles
multiple incoming records at the same time. See the examples at the end of
this documentation for more detail.

The second argument to the C<incoming_data()> method is a scalar indicating
whether the handle has been closed. Normally it is false, but will become true
once the handle closes. A reference to the buffer is passed to the method in
the usual way, so it may inspect data contained in it. Once the method returns
a false value, it will not be called again, as the handle is now closed and no
more data can arrive.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $ioab = IO::Async::Buffer->new( handle => $handle, receiver => $receiver )

This function returns a new instance of a C<IO::Async::Buffer> object.
The transceiver wraps a connected handle and a receiver.

If the string C<'self'> is passed instead, then the object will call
notification events on itself. This will be useful in implementing subclasses,
which internally implements the notification method.

=over 8

=item $handle

The handle object to wrap. Must implement C<fileno>, C<sysread> and
C<syswrite> methods in the way that C<IO::Handle> does.

=item $receiver

An object reference to notify on incoming data, or the string C<'self'>.
This object reference should support a C<< ->incoming_data() >> method.

=back

=cut

sub new
{
   my $class = shift;
   my ( %params ) = @_;

   my $self = $class->SUPER::new( %params, listener => 'self' );

   my $receiver = $params{receiver};
   $receiver = $self if( $receiver eq "self" );

   unless( ref( $receiver ) && $receiver->can( "incoming_data" ) ) {
      croak 'Expected that $receiver can incoming_data()';
   }

   $self->{receiver} = $receiver;
   $self->{sendbuff} = "";
   $self->{recvbuff} = "";

   return $self;
}

=head1 METHODS

=cut

=head2 $ioab->send( $data )

This method adds data to the outgoing data queue. The data is not yet sent to
the handle; this will be done later in the C<write_ready()> method.

=over 8

=item $data

A scalar containing data to send

=back

=cut

sub send
{
   my $self = shift;
   my ( $data ) = @_;

   $self->{sendbuff} .= $data;

   $self->want_writeready( 1 );
}

# protected
sub read_ready
{
   my $self = shift;

   my $handle = $self->{handle};

   my $data;
   my $len = $handle->sysread( $data, 8192 );

   # TODO: Deal with other types of read error

   my $handleclosed = ( $len == 0 );

   $self->{recvbuff} .= $data if( !$handleclosed );
   my $receiver = $self->{receiver};
   while( length( $self->{recvbuff} ) > 0 || $handleclosed ) {
      my $again = $receiver->incoming_data( \$self->{recvbuff}, $handleclosed );
      last if !$again;
   }

   $self->handle_closed() if $handleclosed;
}

# protected
sub write_ready
{
   my $self = shift;

   my $handle = $self->{handle};

   my $len = length( $self->{sendbuff} );
   $len = 8192 if( $len > 8192 );

   my $data = substr( $self->{sendbuff}, 0, $len );

   $len = $handle->syswrite( $data );

   # TODO: Deal with other types of write error

   if( $len == 0 ) {
      $self->handle_closed();
   }
   else {
      substr( $self->{sendbuff}, 0, $len ) = "";

      if( length( $self->{sendbuff} ) == 0 ) {
         $self->want_writeready( 0 );
      }
   }
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 EXAMPLES

=head2 A line-based C<incoming_data()> method

The following C<incoming_data()> method accepts incoming 'C<\n>'-terminated
lines and prints them to the program's C<STDOUT> stream.

 sub incoming_data
 {
    my $self = shift;
    my ( $buffref, $handleclosed ) = @_;

    return 0 unless( $$buffref =~ s/^(.*\n)// );

    print "Received a line: $1";
    return 1;
 }

Because a reference to the buffer itself is passed, it is simple to use a
C<s///> regular expression on the scalar it points at, to both check if data
is ready (i.e. a whole line), and to remove it from the buffer. If no data is
available then C<0> is returned, to indicate it should not be tried again. If
a line was successfully extracted, then C<1> is returned, to indicate it
should try again in case more lines exist in the buffer.

=head1 SEE ALSO

=over 4

=item *

L<IO::Handle> - Supply object methods for I/O handles

=back

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
