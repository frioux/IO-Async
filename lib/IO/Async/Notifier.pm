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

This object may be used in one of two ways; with callback functions, or as a
base class.

=over 4

=item Callbacks

If the C<read_ready> or C<write_ready> keys are supplied in the constructor,
they should contain CODE references to callback functions to be called when
the underlying IO handle becomes readable or writable.

=item Base Class

If a subclass is built, then it can override the C<read_ready> or
C<write_ready> methods of the base to perform its work. In this case, it
should not call the C<SUPER::> versions of those methods.

=back

If either of the readyness methods calls the C<handle_closed()> method, then
the handle is internally marked as closed within the object.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $ioan = IO::Async::Notifier->new( %params )

This function returns a new instance of a C<IO::Async::Notifier> object.
The C<%params> hash takes the following keys:

=over 8

=item handle => $handle

The handle object to wrap. Must implement C<fileno> method in way that
C<IO::Handle> does.

=item read_ready => CODE

=item write_ready => CODE

CODE references to handlers for when the handle becomes read-ready or
write-ready. If these are not supplied, subclass methods will be called
instead.

=back

It is required that either a C<read_ready> callback reference is passed, or
that the object is actually a subclass that overrides the C<read_ready>
method. It is optional whether either is true for C<write_ready>; if neither
is supplied then write-readiness notifications will be ignored.

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

   if( $params{read_ready} ) {
      $self->{read_ready} = $params{read_ready};
   }
   else {
      # No callback was passed. But don't worry; perhaps we're really a
      # subclass that overrides it
      if( $self->can( 'read_ready' ) == \&read_ready ) {
         croak 'Expected either a read_ready callback or to be a subclass that can ->read_ready';
      }

      # Don't need to store anything - if an overridden method exists, we know
      # our own won't be called
   }

   if( $params{write_ready} ) {
      $self->{write_ready} = $params{write_ready};
   }
   # No problem if it doesn't exist

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
   my $callback = $self->{read_ready};
   $callback->();
}

# For ::Sets to call
sub write_ready
{
   my $self = shift;
   my $callback = $self->{write_ready};
   $callback->() if defined $callback;
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
