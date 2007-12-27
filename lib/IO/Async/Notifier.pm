#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006,2007 -- leonerd@leonerd.org.uk

package IO::Async::Notifier;

use strict;

our $VERSION = '0.10';

use Carp;

=head1 NAME

C<IO::Async::Notifier> - event callbacks for a non-blocking file descriptor

=head1 SYNOPSIS

 use IO::Socket::INET;
 use IO::Async::Notifier;

 my $socket = IO::Socket::INET->new( LocalPort => 1234, Listen => 1 );

 my $notifier = IO::Async::Notifer->new(
    handle => $socket,

    on_read_ready  => sub {
       my $new_client = $socket->accept(); 
       ...
    },
 );

 my $loop = IO::Async::Loop::...
 $loop->add( $notifier );

For most other uses with sockets, pipes or other filehandles that carry a byte
stream, the C<IO::Async::Stream> class is likely to be more suitable.

=head1 DESCRIPTION

This module provides a base class for implementing non-blocking IO on file
descriptors. The object provides ways to integrate with existing asynchronous
IO handling code, by way of the various C<IO::Async::Loop::*> collection
classes.

This object may be used in one of two ways; with callback functions, or as a
base class.

=over 4

=item Callbacks

If the C<on_read_ready> or C<on_write_ready> keys are supplied in the
constructor, they should contain CODE references to callback functions to be
called when the underlying IO handle becomes readable or writable:

 $on_read_ready->( $self )

 $on_write_ready->( $self )

Optionally, an C<on_closed> key can also be specified, which will be called
when the C<close> method is invoked. This is intended for subclasses.

 $on_closed->( $self )

=item Base Class

If a subclass is built, then it can override the C<on_read_ready> or
C<on_write_ready> methods of the base to perform its work. In this case, it
should not call the C<SUPER::> versions of those methods.

 $self->on_read_ready()

 $self->on_write_ready()

=back

If either of the readyness methods calls the C<close()> method, then
the handle is internally marked as closed within the object.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $notifier = IO::Async::Notifier->new( %params )

This function returns a new instance of a C<IO::Async::Notifier> object.
The C<%params> hash takes the following keys:

=over 8

=item read_handle => IO

=item write_handle => IO

The reading and writing IO handles. Each must implement the C<fileno> method.
C<read_handle> must be defined, C<write_handle> is allowed to be C<undef>.
Primarily used for passing C<STDIN> / C<STDOUT>; see the SYNOPSIS section of
C<IO::Async::Stream> for an example.

=item handle => IO

The IO handle for both reading and writing; instead of passing each separately
as above. Must implement C<fileno> method in way that C<IO::Handle> does.

=item on_read_ready => CODE

=item on_write_ready => CODE

CODE references to handlers for when the handle becomes read-ready or
write-ready. If these are not supplied, subclass methods will be called
instead.

=item on_closed => CODE

CODE reference to the handler for when the handle becomes closed.

=back

It is required that either a C<on_read_ready> callback reference is passed, or
that the object is actually a subclass that overrides the C<on_read_ready>
method. It is optional whether either is true for C<on_write_ready>; if
neither is supplied then write-readiness notifications will be ignored.

=cut

sub new
{
   my $class = shift;
   my ( %params ) = @_;

   my ( $read_handle, $write_handle );

   if( defined $params{read_handle} or defined $params{write_handle} ) {
      $read_handle  = $params{read_handle};

      # Test if we've got a fileno. We put it in an eval block in case what
      # we were passed in can't do fileno. We can't just test if 
      # $read_handle->can( "fileno" ) because this is not true for bare
      # filehandles like \*STDIN, whereas STDIN->fileno still works.
      unless( defined eval { $read_handle->fileno } ) {
         croak 'Expected that read_handle can fileno()';
      }

      $write_handle = $params{write_handle};
      if( defined $write_handle ) {
         unless( defined eval { $write_handle->fileno } ) {
            croak 'Expected that write_handle can fileno()';
         }
      }
   }
   elsif( defined $params{handle} ) {
      my $handle = $params{handle};
      unless( defined eval { $handle->fileno } ) {
         croak 'Expected that handle can fileno()';
      }

      $read_handle  = $handle;
      $write_handle = $handle;
   }
   else {
      croak "Expected either 'handle' or 'read_handle' and 'write_handle' keys";
   }

   my $self = bless {
      read_handle     => $read_handle,
      write_handle    => $write_handle,
      want_writeready => $params{want_writeready} || 0,
      children        => [],
      parent          => undef,
   }, $class;

   if( $params{on_read_ready} ) {
      $self->{on_read_ready} = $params{on_read_ready};
   }
   else {
      # No callback was passed. But don't worry; perhaps we're really a
      # subclass that overrides it
      if( $self->can( 'on_read_ready' ) == \&on_read_ready ) {
         croak 'Expected either a on_read_ready callback or to be a subclass that can ->on_read_ready';
      }

      # Don't need to store anything - if an overridden method exists, we know
      # our own won't be called
   }

   if( $params{on_write_ready} ) {
      $self->{on_write_ready} = $params{on_write_ready};
   }
   # No problem if it doesn't exist

   if( $params{on_closed} ) {
      $self->{on_closed} = $params{on_closed};
   }
   # No problem if it doesn't exist

   return $self;
}

=head1 METHODS

=cut

=head2 $notifier->close

This method calls C<close> on the underlying IO handles. This method will will
remove the notifier from its containing loop.

=cut

sub close
{
   my $self = shift;

   my $read_handle = $self->{read_handle};
   return unless( defined $read_handle );

   $self->{on_closed}->( $self ) if $self->{on_closed};

   if( my $loop = $self->{loop} ) {
      $loop->remove( $self );
   }

   delete $self->{read_handle};
   $read_handle->close;

   my $write_handle = delete $self->{write_handle};
   $write_handle->close if defined $write_handle and $write_handle != $read_handle;
}

=head2 $handle = $notifier->read_handle

=head2 $handle = $notifier->write_handle

These accessors return the underlying IO handles.

=cut

sub read_handle
{
   my $self = shift;
   return $self->{read_handle};
}

sub write_handle
{
   my $self = shift;
   return $self->{write_handle};
}

=head2 $fileno = $notifier->read_fileno

=head2 $fileno = $notifier->write_fileno

These accessors return the file descriptor numbers of the underlying IO
handles.

=cut

sub read_fileno
{
   my $self = shift;
   my $handle = $self->read_handle or return undef;
   return $handle->fileno;
}

sub write_fileno
{
   my $self = shift;
   my $handle = $self->write_handle or return undef;
   return $handle->fileno;
}

# For ::Loops to call
sub __memberof_loop
{
   my $self = shift;
   if( @_ ) {
      my $old = $self->{loop};
      $self->{loop} = $_[0];
      return $old;
   }
   else {
      return $self->{loop};
   }
}

=head2 $value = $notifier->want_writeready

=head2 $oldvalue = $notifier->want_writeready( $newvalue )

This is the accessor for the C<want_writeready> property, which defines
whether the object will register interest in the write-ready bitvector in a
C<select()> call, or whether to register the C<POLLOUT> bit in a C<IO::Poll>
mask.

=cut

sub want_writeready
{
   my $self = shift;
   if( @_ ) {
      my ( $new ) = @_;

      if( $new and !defined $self->write_handle ) {
         croak 'Cannot want_writeready in a Notifier with no write_handle';
      }

      my $old = $self->{want_writeready};
      $self->{want_writeready} = $new;

      if( $self->{loop} ) {
         $self->{loop}->__notifier_want_writeready( $self, $self->{want_writeready} );
      }

      return $old;
   }
   else {
      return $self->{want_writeready};
   }
}

# For ::Loops to call
sub on_read_ready
{
   my $self = shift;
   my $callback = $self->{on_read_ready};
   $callback->( $self );
}

# For ::Loops to call
sub on_write_ready
{
   my $self = shift;
   my $callback = $self->{on_write_ready};
   $callback->( $self ) if defined $callback;
}

=head1 CHILD NOTIFIERS

During the execution of a program, it may be the case that certain IO handles
cause other handles to be created; for example, new sockets that have been
C<accept()>ed from a listening socket. To facilitate these, a notifier may
contain child notifier objects, that are automatically added to or removed
from the C<IO::Async::Loop> that manages their parent.

=cut

=head2 $parent = $notifier->parent()

Returns the parent of the notifier, or C<undef> if does not have one.

=cut

sub parent
{
   my $self = shift;
   return $self->{parent};
}

=head2 @children = $notifier->children()

Returns a list of the child notifiers contained within this one.

=cut

sub children
{
   my $self = shift;
   return @{ $self->{children} };
}

=head2 $notifier->add_child( $child )

Adds a child notifier. This notifier will be added to the containing loop, if
the parent has one. Only a notifier that does not currently have a parent and
is not currently a member of any loop may be added as a child. If the child
itself has grandchildren, these will be recursively added to the containing
loop.

=cut

sub add_child
{
   my $self = shift;
   my ( $child ) = @_;

   croak "Cannot add a child that already has a parent" if defined $child->{parent};

   croak "Cannot add a child that is already a member of a loop" if defined $child->{loop};

   if( defined( my $loop = $self->{loop} ) ) {
      $loop->add( $child );
   }

   push @{ $self->{children} }, $child;
   $child->{parent} = $self;

   return;
}

=head2 $notifier->remove_child( $child )

Removes a child notifier. The child will be removed from the containing loop,
if the parent has one. If the child itself has grandchildren, these will be
recurively removed from the loop.

=cut

sub remove_child
{
   my $self = shift;
   my ( $child ) = @_;

   LOOP: {
      my $childrenref = $self->{children};
      for my $i ( 0 .. $#$childrenref ) {
         next unless $childrenref->[$i] == $child;
         splice @$childrenref, $i, 1, ();
         last LOOP;
      }

      croak "Cannot remove child from a parent that doesn't contain it";
   }

   undef $child->{parent};

   if( defined( my $loop = $self->{loop} ) ) {
      $loop->remove( $child );
   }
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
