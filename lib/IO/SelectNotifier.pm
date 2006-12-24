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

package IO::SelectNotifier;

use strict;

use Common::Exception;
use Common::Socket; # for the exception type

use Error qw(:try);

=head1 Name

C<IO::SelectNotifier> - a class which implements event callbacks for a
non-blocking file descriptor

=head1 Overview

This module provides a base class for implementing non-blocking IO on file
descriptors. The object provides a pair of methods, C<pre_select()> and
C<post_select()>, to make integration with C<select()>-based code simple, and
to co-exist with other modules which use the same interface.

The relevant bit in the read-ready bitvector is always set by the
C<pre_select()> method, but the corresponding bit in write-ready vector is
only set if the object's listener object states an interest in write-readyness
by its C<want_writeready()> method. The C<post_select()> will call any of the
listener object's C<readready()> or C<writeready()> methods as indicated by
the bits in the vectors from the C<select()> syscall.

=head2 Listener

Each C<IO::SelectNotifier> object stores a reference to a listener object.
This object will be informed of read- or write-readyness by the
C<post_select()> method, and will be queried on whether it is interested in
write-readyness by the C<pre_select()> method. To do this, the following
methods may be called on the listener:

 $want = $listener->want_writeready();

 $listener->readready();

 $listener->writeready();

None of these methods will be passed any arguments; the object itself should
track any data it requires. If either of the readyness methods throws an
exception of C<Common::Socket::ClosedException> class, then it will be caught
by the C<post_select()> method, and the socket internally marked as closed
within the object. After this happens, it will no longer register bits in the
bitvectors in C<pre_select()>.

=cut

=head1 Constructors

=cut

=head2 C<< B<sub> IO::SelectNotifier->new( I<%params> ) >>

=over 4

=over 8

=item C<I<%params>>

A hash containing the following keys

=over 8

=item C<sock>

The C<Common::Socket> object to wrap

=item C<listener>

An object reference to notify on events, or the string C<'self'>

=back

=item Returns

An instance of C<IO::SelectNotifier>

=back

This function returns a new instance of a C<IO::SelectNotifier> object.
The transceiver wraps a connected socket and a receiver.

If the string C<'self'> is passed instead, then the object will call
notification events on itself. This will be useful in implementing subclasses,
which internally implement the notification methods.

=back

=cut

sub new
{
   my $class = shift;
   my ( %params ) = @_;

   my $sock = $params{sock};
   unless( ref( $sock ) && $sock->isa( "Common::Socket" ) ) {
      throw Common::Exception( "Expected sock to be a Common::Socket" );
   }

   my $self = bless {
      sock => $sock,
   }, $class;

   my $listener = $params{listener};
   $listener = $self if( $listener eq "self" );

   $self->{listener} = $listener;

   return $self;
}

=head2 C<< B<sub> $self->pre_select( I<\$readvec>, I<\$writevec>, I<\$exceptvec>, I<\$timeout> ) >>

=over 4

=over 8

=item C<I<\$readvec>>

=item C<I<\$writevec>>

=item C<I<\$exceptvec>>

Scalar references to the reading, writing and exception bitvectors

=item C<I<\$timeout>>

Scalar reference to the timeout value

=item Returns

Nothing

=back

This method prepares the bitvectors for a C<select()> call, setting the bits
that this notifier is interested in. It will always set the bit in the read
vector, but will only set it in the write vector if the listener declares an
interest in it by returning a true value from its C<want_writeready()> method.
Neither the exception vector nor the timeout are affected.

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

   my $listener = $self->{listener};

   vec( $$readref,  $fileno, 1 ) = 1;

   if( $listener->can( "want_writeready" ) ) {
      vec( $$writeref, $fileno, 1 ) = 1 if( $listener->want_writeready );
   }
}

=head2 C<< B<sub> $self->post_select( I<$readvec>, I<$writevec>, I<$exceptvec> ) >>

=over 4

=over 8

=item C<I<$readvec>>

=item C<I<$writevec>>

=item C<I<$exceptvec>>

Scalars containing the read-ready, write-ready and exception bitvectors

=item Returns

Nothing

=back

This method checks the returned bitvectors from a C<select()> call, and calls
any of the notification methods on the listener that are appropriate.

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

   try {
      if( vec( $readvec, $fileno, 1 ) ) {
         $listener->readready;
      }

      if( vec( $writevec, $fileno, 1 ) ) {
         $listener->writeready;
      }
   }
   catch Common::Socket::ClosedException with {   
      $sock->close;
      undef $sock;
      delete $self->{sock};
   };
}

# Keep perl happy; keep Britain tidy
1;
