#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006-2008 -- leonerd@leonerd.org.uk

package IO::Async::Notifier;

use strict;

our $VERSION = '0.16';

use Carp;
use Scalar::Util qw( weaken );

=head1 NAME

C<IO::Async::Notifier> - event callbacks for a non-blocking file descriptor

=head1 SYNOPSIS

 use IO::Socket::INET;
 use IO::Async::Notifier;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();

 my $socket = IO::Socket::INET->new( LocalPort => 1234, Listen => 1 );

 my $notifier = IO::Async::Notifier->new(
    handle => $socket,

    on_read_ready  => sub {
       my $new_client = $socket->accept(); 
       ...
    },
 );

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
At most one of C<read_handle> or C<write_handle> is allowed to be C<undef>.
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

It is required that at C<on_read_ready> or C<on_write_ready> are provided for
any handle that is provided; either as a callback reference or that the object
is a subclass that overrides the method. I.e. if only a C<read_handle> is
given, then C<on_write_ready> can be absent. If C<handle> is used as a
shortcut, then both read and write-ready callbacks or methods are required.

If no IO handles are provided at construction time, the object is still
created but will not yet be fully-functional as a Notifier. IO handles can
be assigned later using the C<set_handle> or C<set_handles> methods. This may
be useful when constructing an object to represent a network connection,
before the C<connect()> has actually been performed yet.

=cut

sub new
{
   my $class = shift;
   my ( %params ) = @_;

   my ( $read_handle, $write_handle );

   if( defined $params{read_handle} or defined $params{write_handle} ) {
      # Test if we've got a fileno. We put it in an eval block in case what
      # we were passed in can't do fileno. We can't just test if 
      # $read_handle->can( "fileno" ) because this is not true for bare
      # filehandles like \*STDIN, whereas STDIN->fileno still works.

      $read_handle  = $params{read_handle};
      if( defined $read_handle ) {
         unless( defined eval { $read_handle->fileno } ) {
            croak 'Expected that read_handle can fileno()';
         }
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

   if( defined $read_handle ) {
      if( !$params{on_read_ready} and $class->can( 'on_read_ready' ) == \&on_read_ready ) {
         croak 'Expected either a on_read_ready callback or an ->on_read_ready method';
      }
   }

   if( defined $write_handle ) {
      if( !$params{on_write_ready} and $class->can( 'on_write_ready' ) == \&on_write_ready ) {
         # This used not to be fatal. Make it just a warning for now.
         carp 'A write handle was provided but neither a on_write_ready callback nor an ->on_write_ready method were. Perhaps you mean \'read_handle\' instead?';
      }
   }

   my $self = bless {
      read_handle     => $read_handle,
      write_handle    => $write_handle,
      want_readready  => 0,
      want_writeready => 0,
      children        => [],
      parent          => undef,
   }, $class;

   $self->{on_read_ready}  = $params{on_read_ready}  if defined $params{on_read_ready};
   $self->{on_write_ready} = $params{on_write_ready} if defined $params{on_write_ready};
   $self->{on_closed}      = $params{on_closed}      if defined $params{on_closed};

   # Slightly asymmetric
   $self->want_readready( defined $read_handle );
   $self->want_writeready( $params{want_writeready} || 0 );

   return $self;
}

=head1 METHODS

=cut

=head2 $notifier->set_handles( %params )

This method stores new reading or writing handles in the object, as if they
had been passed as the C<read_handle> or C<write_handle> arguments to the
constructor. The C<%params> hash takes the following keys:

=over 8

=item read_handle => IO

A new IO handle for reading, or C<undef> to remove the old one.

=item write_handle => IO

A new IO handle for writing, or C<undef> to remove the old one.

=back

=cut

sub set_handles
{
   my $self = shift;
   my %params = @_;

   if( defined $params{read_handle} ) {
      unless( defined eval { $params{read_handle}->fileno } ) {
         croak 'Expected that read_handle can fileno()';
      }
   }

   if( defined $params{write_handle} ) {
      unless( defined eval { $params{write_handle}->fileno } ) {
         croak 'Expected that write_handle can fileno()';
      }
   }

   if( exists $params{read_handle} ) {
      $self->{read_handle} = $params{read_handle};

      # Register interest in readability with the underlying loop
      $self->want_readready( defined $self->{read_handle} );
   }

   if( exists $params{write_handle} ) {
      $self->{write_handle} = $params{write_handle};
   }
}

=head2 $notifier->set_handle( $handle )

Shortcut for

 $notifier->set_handles( read_handle => $handle, write_handle => $handle )

=cut

sub set_handle
{
   my $self = shift;
   my ( $handle ) = @_;

   $self->set_handles(
      read_handle  => $handle,
      write_handle => $handle,
   );
}

=head2 $notifier->close

This method calls C<close> on the underlying IO handles. This method will will
remove the notifier from its containing loop.

=cut

sub close
{
   my $self = shift;

   return unless defined $self->read_handle or defined $self->write_handle;

   if( my $parent = $self->{parent} ) {
      $parent->remove_child( $self );
   }
   elsif( my $loop = $self->{loop} ) {
      $loop->remove( $self );
   }

   my $read_handle = delete $self->{read_handle};
   $read_handle->close if defined $read_handle;

   my $write_handle = delete $self->{write_handle};
   $write_handle->close if defined $write_handle and ( not defined $read_handle or $write_handle != $read_handle );

   $self->{on_closed}->( $self ) if $self->{on_closed};
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

=head2 $notifier->get_loop

This accessor returns the C<IO::Async::Loop> object to which this notifier
belongs.

=cut

sub get_loop
{
   my $self = shift;
   return $self->{loop}
}

# Only called by IO::Async::Loop, not external interface
sub __set_loop
{
   my $self = shift;
   my ( $loop ) = @_;
   $self->{loop} = $loop;
   weaken( $self->{loop} ); # To avoid a cycle
}

=head2 $value = $notifier->want_readready

=head2 $oldvalue = $notifier->want_readready( $newvalue )

=head2 $value = $notifier->want_writeready

=head2 $oldvalue = $notifier->want_writeready( $newvalue )

These are the accessor for the C<want_readready> and C<want_writeready>
properties, which define whether the object is interested in knowing about 
read- or write-readiness on the underlying file handle.

=cut

sub want_readready
{
   my $self = shift;
   if( @_ ) {
      my ( $new ) = @_;

      $new = $new ?1:0; # Squash to boolean
      return $new if $new == $self->{want_readready};

      if( $new ) {
         defined $self->read_handle or
            croak 'Cannot want_readready in a Notifier with no read_handle';
      }

      my $old = $self->{want_readready};
      $self->{want_readready} = $new;

      if( $self->{loop} ) {
         $self->{loop}->__notifier_want_readready( $self, $self->{want_readready} );
      }

      return $old;
   }
   else {
      return $self->{want_readready};
   }
}

sub want_writeready
{
   my $self = shift;
   if( @_ ) {
      my ( $new ) = @_;

      $new = $new ?1:0; # Squash to boolean
      return $new if $new == $self->{want_writeready};

      if( $new ) {
         defined $self->write_handle or
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
   $callback->( $self ) if defined $callback;
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
