#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006-2009 -- leonerd@leonerd.org.uk

package IO::Async::Handle;

use strict;
use warnings;
use base qw( IO::Async::Notifier );

our $VERSION = '0.22';

use Carp;
use Scalar::Util qw( weaken );

=head1 NAME

C<IO::Async::Handle> - event callbacks for a non-blocking file descriptor

=head1 SYNOPSIS

This class is likely not to be used directly, because subclasses of it exist
to handle more specific cases. Here is an example of how it would be used to
watch a listening socket for new connections. In real code, it is likely that
the C<< Loop->listen() >> method would be used instead.

 use IO::Socket::INET;
 use IO::Async::Handle;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();

 my $socket = IO::Socket::INET->new( LocalPort => 1234, Listen => 1 );

 my $handle = IO::Async::Handle->new(
    handle => $socket,

    on_read_ready  => sub {
       my $new_client = $socket->accept(); 
       ...
    },
 );

 $loop->add( $handle );

For most other uses with sockets, pipes or other filehandles that carry a byte
stream, the C<IO::Async::Stream> class is likely to be more suitable.

=head1 DESCRIPTION

This module provides a class of C<IO::Async::Notifier> for implementing
non-blocking IO on file descriptors. The object interacts with the actual OS
by being part of the C<IO::Async::Loop> object it has been added to.

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
when the C<close> method is invoked.

 $on_closed->( $self )

This callback is invoked before the filehandles are closed and the Handle
removed from its containing Loop. The C<get_loop> will still return the
containing Loop object.

=item Base Class

If a subclass is built, then it can override the C<on_read_ready> or
C<on_write_ready> methods of the base to perform its work. In this case, it
should not call the C<SUPER::> versions of those methods.

 $self->on_read_ready()

 $self->on_write_ready()

=back

If either of the readyness methods calls the C<close()> method, then
the handle is internally marked as closed within the object and will be
removed from its containing loop, if it is within one.

=cut

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>:

=over 8

=item read_handle => IO

=item write_handle => IO

The reading and writing IO handles. Each must implement the C<fileno> method.
Primarily used for passing C<STDIN> / C<STDOUT>; see the SYNOPSIS section of
C<IO::Async::Stream> for an example.

=item handle => IO

The IO handle for both reading and writing; instead of passing each separately
as above. Must implement C<fileno> method in way that C<IO::Handle> does.

=item on_read_ready => CODE

=item on_write_ready => CODE

CODE references to callbacks for when the handle becomes read-ready or
write-ready. If these are not supplied, subclass methods will be called
instead.

=item on_closed => CODE

CODE reference to the callback for when the handle becomes closed.

=back

It is required that a matching C<on_read_ready> or C<on_write_ready> are
available for any handle that is provided; either passed as a callback CODE
reference or as an overridden the method. I.e. if only a C<read_handle> is
given, then C<on_write_ready> can be absent. If C<handle> is used as a
shortcut, then both read and write-ready callbacks or methods are required.

If no IO handles are provided at construction time, the object is still
created but will not yet be fully-functional as a Handle. IO handles can be
assigned later using the C<set_handle> or C<set_handles> methods. This may be
useful when constructing an object to represent a network connection, before
the C<connect()> has actually been performed yet.

=cut

sub configure
{
   my $self = shift;
   my %params = @_;

   if( exists $params{on_read_ready} ) {
      $self->{on_read_ready} = delete $params{on_read_ready};
      $self->_watch_read(0), $self->_watch_read(1) if $self->want_readready;
   }

   if( exists $params{on_write_ready} ) {
      $self->{on_write_ready} = delete $params{on_write_ready};
      $self->_watch_write(0), $self->_watch_write(1) if $self->want_writeready;
   }

   if( exists $params{on_closed} ) {
      $self->{on_closed} = delete $params{on_closed};
   }

   # 'handle' is a shortcut for setting read_ and write_
   if( exists $params{handle} ) {
      $params{read_handle}  = $params{handle};
      $params{write_handle} = $params{handle};
      delete $params{handle};
   }

   if( exists $params{read_handle} ) {
      my $read_handle = delete $params{read_handle};

      if( defined $read_handle ) {
         if( !defined eval { $read_handle->fileno } ) {
            croak 'Expected that read_handle can fileno()';
         }

         if( !$self->{on_read_ready} and !$self->can( 'on_read_ready' ) ) {
            croak 'Expected either a on_read_ready callback or an ->on_read_ready method';
         }
      }

      $self->{read_handle} = $read_handle;

      $self->want_readready( defined $read_handle );

      # In case someone has reopened the filehandles during an on_closed handler
      undef $self->{handle_closing};
   }

   if( exists $params{write_handle} ) {
      my $write_handle = delete $params{write_handle};

      if( defined $write_handle ) {
         if( !defined eval { $write_handle->fileno } ) {
            croak 'Expected that write_handle can fileno()';
         }

         if( !$self->{on_write_ready} and !$self->can( 'on_write_ready' ) ) {
            # This used not to be fatal. Make it just a warning for now.
            carp 'A write handle was provided but neither a on_write_ready callback nor an ->on_write_ready method were. Perhaps you mean \'read_handle\' instead?';
         }
      }

      $self->{write_handle} = $write_handle;

      # In case someone has reopened the filehandles during an on_closed handler
      undef $self->{handle_closing};
   }

   if( exists $params{want_writeready} ) {
      $self->want_writeready( delete $params{want_writeready} );
   }

   $self->SUPER::configure( %params );
}

# We'll be calling these any of three times
#   adding to/removing from loop
#   caller en/disables readiness checking
#   changing filehandle

sub _watch_read
{
   my $self = shift;
   my ( $want ) = @_;

   my $loop = $self->get_loop or return;
   my $fh = $self->read_handle or return;

   if( !$self->{on_read_ready} ) {
      weaken( my $weakself = $self );
      $self->{on_read_ready} = sub { $weakself->on_read_ready };
   }

   if( $want ) {
      $loop->watch_io(
         handle => $fh,
         on_read_ready => $self->{on_read_ready},
      );
   }
   else {
      $loop->unwatch_io(
         handle => $fh,
         on_read_ready => 1,
      );
   }
}

sub _watch_write
{
   my $self = shift;
   my ( $want ) = @_;

   my $loop = $self->get_loop or return;
   my $fh = $self->write_handle or return;

   if( !$self->{on_write_ready} ) {
      weaken( my $weakself = $self );
      $self->{on_write_ready} = sub { $weakself->on_write_ready };
   }

   if( $want ) {
      $loop->watch_io(
         handle => $fh,
         on_write_ready => $self->{on_write_ready},
      );
   }
   else {
      $loop->unwatch_io(
         handle => $fh,
         on_write_ready => 1,
      );
   }
}

sub _add_to_loop
{
   my $self = shift;
   my ( $loop ) = @_;

   $self->_watch_read(1)  if $self->want_readready;
   $self->_watch_write(1) if $self->want_writeready;
}

sub _remove_from_loop
{
   my $self = shift;
   my ( $loop ) = @_;

   $self->_watch_read(0);
   $self->_watch_write(0);
}

=head1 METHODS

=cut

=head2 $handle->set_handles( %params )

Sets new reading or writing filehandles. Equivalent to calling the
C<configure> method with the same parameters.

=cut

sub set_handles
{
   my $self = shift;
   my %params = @_;

   $self->configure(
      exists $params{read_handle}  ? ( read_handle  => $params{read_handle} )  : (),
      exists $params{write_handle} ? ( write_handle => $params{write_handle} ) : (),
   );
}

=head2 $handle->set_handle( $fh )

Shortcut for

 $handle->configure( handle => $fh )

=cut

sub set_handle
{
   my $self = shift;
   my ( $fh ) = @_;

   $self->configure( handle => $fh );
}

=head2 $handle->close

This method calls C<close> on the underlying IO handles. This method will then
remove the handle from its containing loop.

=cut

sub close
{
   my $self = shift;

   # Prevent infinite loops if there's two crosslinked handles
   return if $self->{handle_closing};
   $self->{handle_closing} = 1;

   $self->{on_closed}->( $self ) if $self->{on_closed};

   if( my $parent = $self->{parent} ) {
      $parent->remove_child( $self );
   }
   elsif( my $loop = $self->get_loop ) {
      $loop->remove( $self );
   }

   my $read_handle = delete $self->{read_handle};
   $read_handle->close if defined $read_handle;

   my $write_handle = delete $self->{write_handle};
   $write_handle->close if defined $write_handle and ( not defined $read_handle or $write_handle != $read_handle );

   # Clear the want* states, so if we get a new handle and are re-opened,
   # we'll rearm the underlying loop
   undef $self->{want_readready};
   undef $self->{want_writeready};
}

=head2 $handle = $handle->read_handle

=head2 $handle = $handle->write_handle

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

=head2 $fileno = $handle->read_fileno

=head2 $fileno = $handle->write_fileno

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

=head2 $value = $handle->want_readready

=head2 $oldvalue = $handle->want_readready( $newvalue )

=head2 $value = $handle->want_writeready

=head2 $oldvalue = $handle->want_writeready( $newvalue )

These are the accessor for the C<want_readready> and C<want_writeready>
properties, which define whether the object is interested in knowing about 
read- or write-readiness on the underlying file handle.

=cut

sub want_readready
{
   my $self = shift;
   if( @_ ) {
      my ( $new ) = @_;

      $new = !!$new;
      return $new if !$new == !$self->{want_readready}; # compare bools

      if( $new ) {
         defined $self->read_handle or
            croak 'Cannot want_readready in a Handle with no read_handle';
      }

      my $old = $self->{want_readready};
      $self->{want_readready} = $new;

      $self->_watch_read( $new );

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

      $new = !!$new;
      return $new if !$new == !$self->{want_writeready}; # compare bools

      if( $new ) {
         defined $self->write_handle or
            croak 'Cannot want_writeready in a Handle with no write_handle';
      }

      my $old = $self->{want_writeready};
      $self->{want_writeready} = $new;

      $self->_watch_write( $new );

      return $old;
   }
   else {
      return $self->{want_writeready};
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

Paul Evans <leonerd@leonerd.org.uk>
