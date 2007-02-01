#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU Library General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
#
#  (C) Paul Evans, 2006 -- leonerd@leonerd.org.uk

package IO::Async::Buffer;

use strict;

use base qw( IO::Async::Notifier );

use Carp;

=head1 Name

C<Common::AsyncTransceiver> - a class which implements asynchronous sending
and receiving data buffers around a connected socket

=head1 Overview

This module provides a class for implementing asynchronous communications
buffers behind connected sockets. It provides buffering for both incoming and
outgoing data, which are transferred to or from the actual socket during a
C<select()> loop. The object is built on the C<IO::Async::Notifier> to allow
easy integration into a C<select()> loop.

Data can be added to the outgoing buffer at any time using the C<send()>
method, and will be flushed whenever the underlying socket is notified as
being write-ready. Whenever the socket is notified as being read-ready, the
data is read in from the socket, and the transceiver object's receiver is
signaled to indicate the data is available.

=head2 Receivers

Each C<Common::AsyncTransceiver> object stores a reference to a receiver
object.  This is any object that supports a C<< ->incomingData() >> method.
When data arrives in the incoming data buffer, the transceiver calls this
method on its receiver to indicate the data is available. It is called in the
following manner:

 $again = $receiver->incomingData( \$buffer, $socketclosed )

A reference to the incoming data buffer is passed, which is a plain perl
string. The C<incomingData()> method should inspect and remove any data it
likes, but is not required to remove all, or indeed any of the data. Any data
remaining in the buffer will be preserved for the next call, the next time more
data is received from the socket.

In this way, it is easy to implement code that reads records of some form when
completed, but ignores partially-received records, until all the data is
present. If the method is confident no more useful data remains, it should
return a false value. If not, it should return a true value, and the method
will be called again. This makes it easy to implement code that handles
multiple incoming records at the same time. See the examples at the end of
this documentation for more detail.

The second argument to the C<incomingData()> method is a scalar indicating
whether the socket has been closed. Normally it is false, but will become true
once the socket closes. A reference to the buffer is passed to the method in
the usual way, so it may inspect data contained in it. Once the method returns
a false value, it will not be called again, as the socket is now closed and no
more data can arrive.

=cut

=head1 Constructors

=cut

=head2 C<< B<sub> Common::AsyncTransceiver->new( I<%params> ) >>

=over 4

=over 8

=item C<I<%params>>

A hash containing the following keys

=over 8

=item C<sock>

The C<Common::Socket> object to wrap

=item C<receiver>

An object reference to notify on incoming data. This object reference should
support a C<< ->incomingData() >> method.

=back

=item Returns

An instance of C<Common::AsyncTransceiver>

=back

This function returns a new instance of a C<Common::AsyncTransceiver> object.
The transceiver wraps a connected socket and a receiver.

=back

=cut

sub new
{
   my $class = shift;
   my ( %params ) = @_;

   my $self = $class->SUPER::new( %params, listener => 'self' );

   my $receiver = $params{receiver};
   unless( ref( $receiver ) && $receiver->can( "incomingData" ) ) {
      croak 'Expected that $receiver can incomingData()';
   }

   $self->{receiver} = $receiver;
   $self->{sendbuff} = "";
   $self->{recvbuff} = "";

   return $self;
}

=head1 Methods

=cut

=head2 C<< B<sub> $self->send( I<$data> ) >>

=over 4

=over 8

=item C<I<$data>>

A scalar containing data to send

=item Returns

Nothing

=back

This method adds data to the outgoing data queue. The data is not yet sent to
the socket; this will be done later in the C<post_select()> method.

=back

=cut

sub send
{
   my $self = shift;
   my ( $data ) = @_;

   $self->{sendbuff} .= $data;
}

# protected
sub want_writeready
{
   my $self = shift;
   return ( length $self->{sendbuff} > 0 ) ? 1 : 0;
}

# protected
sub readready
{
   my $self = shift;

   my $sock = $self->{sock};

   my $data;
   my $len = $sock->sysread( $data, 8192 );

   # TODO: Deal with other types of read error

   my $sockclosed = ( $len == 0 );

   $self->{recvbuff} .= $data if( !$sockclosed );
   my $receiver = $self->{receiver};
   while( length( $self->{recvbuff} ) > 0 || $sockclosed ) {
      my $again = $receiver->incomingData( \$self->{recvbuff}, $sockclosed );
      last if !$again;
   }

   $self->socket_closed() if $sockclosed;
}

# protected
sub writeready
{
   my $self = shift;

   my $sock = $self->{sock};

   my $len = length( $self->{sendbuff} );
   $len = 8192 if( $len > 8192 );

   my $data = substr( $self->{sendbuff}, 0, $len );

   $len = $sock->syswrite( $data );

   # TODO: Deal with other types of write error

   if( $len == 0 ) {
      $self->socket_closed();
   }
   else {
      substr( $self->{sendbuff}, 0, $len ) = "";
   }
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 Examples

=head2 A line-based C<incomingData()> method

The following C<incomingData()> method accepts incoming 'C<\n>'-terminated
lines and prints them to the program's C<STDOUT> stream.

 sub incomingData
 {
    my $self = shift;
    my ( $buffref, $socketclosed ) = @_;

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
