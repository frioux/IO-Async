#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006 -- leonerd@leonerd.org.uk

package IO::Async::Notifier;

use strict;

our $VERSION = '0.01';

use Carp;

=head1 NAME

C<IO::Async::Notifier> - a class which implements event callbacks for a
non-blocking file descriptor

=head1 DESCRIPTION

This module provides a base class for implementing non-blocking IO on file
descriptors. The object provides ways to integrate with existing asynchronous
IO handling code, by way of the various C<IO::Async::Set::*> collection
classes.

=head2 Listener

Each C<IO::Async::Notifier> object stores a reference to a listener object.
This object will be informed of read- or write-readyness by the
C<post_select()> method by the following methods on the listener:

 $listener->read_ready();

 $listener->write_ready();

None of these methods will be passed any arguments; the object itself should
track any data it requires. If either of the readyness methods calls the
C<handle_closed()> method, then the handle is internally marked as closed
within the object. After this happens, it will no longer register bits in the
bitvectors in C<pre_select()>, and will remove the mask in C<pre_poll()>.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $ioan = IO::Async::Notifier->new( handle => $handle, listener => $listener )

This function returns a new instance of a C<IO::Async::Notifier> object.
The transceiver wraps a connected handle and a receiver.

If the string C<'self'> is passed instead, then the object will call
notification events on itself. This will be useful in implementing subclasses,
which internally implement the notification methods.

=over 8

=item $handle

The handle object to wrap. Must implement C<fileno> method in way that
C<IO::Handle> does.

=item $listener

An object reference to notify on events, or the string C<'self'>

=back

=cut

sub new
{
   my $class = shift;
   my ( %params ) = @_;

   my $handle = $params{handle};
   unless( ref( $handle ) and $handle->can( "fileno" ) ) {
      croak 'Expected that $handle can fileno()';
   }

   my $self = bless {
      handle => $handle,
      want_writeready => $params{want_writeready} || 0,
   }, $class;

   my $listener = $params{listener};
   $listener = $self if( $listener eq "self" );

   $self->{listener} = $listener;

   return $self;
}

=head1 METHODS

=cut

=head2 $handle = $ioan->handle

This accessor returns the underlying IO handle.

=cut

sub handle
{
   my $self = shift;
   return $self->{handle};
}

=head2 $fileno = $ioan->fileno

This accessor returns the file descriptor number of the underlying IO handle.

=cut

sub fileno
{
   my $self = shift;
   my $handle = $self->handle or return undef;
   return $handle->fileno;
}

# For ::Sets to call
sub __memberof_set
{
   my $self = shift;
   if( @_ ) {
      my $old = $self->{set};
      $self->{set} = $_[0];
      return $old;
   }
   else {
      return $self->{set};
   }
}

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
   if( @_ ) {
      my $old = $self->{want_writeready};
      $self->{want_writeready} = $_[0];

      if( $self->{set} ) {
         $self->{set}->__notifier_want_writeready( $self, $self->{want_writeready} );
      }

      return $old;
   }
   else {
      return $self->{want_writeready};
   }
}

# For ::Sets to call
sub read_ready
{
   my $self = shift;
   my $listener = $self->{listener};
   $listener->read_ready;
}

# For ::Sets to call
sub write_ready
{
   my $self = shift;
   my $listener = $self->{listener};
   $listener->write_ready;
}

=head2 $ioan->handle_closed()

This method marks that the handle has been closed. After this has been called,
the object will no longer mark any bits in the C<pre_select()> call, nor
respond to any set bits in the C<post_select()> call.

=cut

sub handle_closed
{
   my $self = shift;

   my $handle = $self->{handle};
   return unless( defined $handle );

   $handle->close;
   undef $handle;
   delete $self->{handle};
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 SEE ALSO

=over 4

=item *

L<IO::Handle> - Supply object methods for I/O handles

=back

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
