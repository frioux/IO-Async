#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006-2009 -- leonerd@leonerd.org.uk

package IO::Async::Notifier;

use strict;

our $VERSION = '0.20';

use Carp;
use Scalar::Util qw( weaken );

=head1 NAME

C<IO::Async::Notifier> - base class for C<IO::Async> event objects

=head1 SYNOPSIS

Usually not directly used by a program, but one valid use case may be:

 use IO::Async::Notifier;

 use IO::Async::Stream;
 use IO::Async::Signal;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();

 my $notifier = IO::Async::Notifier->new();

 $notifier->add_child(
    IO::Async::Stream->new(
       read_handle => \*STDIN,
       on_read => sub {
          my $self = shift;
          my ( $buffref, $closed ) = @_;
          $$buffref =~ s/^(.*)\n// or return 0;
          print "You said $1\n";
          return 1;
       },
    )
 );

 $notifier->add_child(
    IO::Async::Signal->new(
       name => 'INT',
       on_receipt => sub {
          print "Goodbye!\n";
          $loop->loop_stop;
       },
    )
 );

 $loop->add( $notifier );

 $loop->loop_forever;

=head1 DESCRIPTION

This object class forms the basis for all the other event objects that an
C<IO::Async> program uses. It provides the lowest level of integration with a
C<IO::Async::Loop> container, and a facility to collect Notifiers together, in
a tree structure, where any Notifier can contain a collection of children.

Normally, objects in this class would not be directly used by an end program,
as it performs no actual IO work, and generates no actual events. These are all
left to the various subclasses, such as:

=over 4

=item *

L<IO::Async::Handle> - event callbacks for a non-blocking file descriptor

=item *

L<IO::Async::Stream> - read and write buffers around an IO handle

=item *

L<IO::Async::Sequencer> - handle a serial pipeline of requests / responses (EXPERIMENTAL)

=item *

L<IO::Async::Timer> - event callback after some timed delay

=item *

L<IO::Async::Signal> - event callback on receipt of a POSIX signal

=back

For more detail, see the SYNOPSIS section in one of the above.

One case where this object class would be used, is when a library wishes to
provide a sub-component which consists of multiple other C<Notifier>
subclasses, such as C<Handle>s and C<Timers>, but no particular object is
suitable to be the root of a tree. In this case, a plain C<Notifier> object
can be used as the tree root, and all the other notifiers added as children of
it.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $notifier = IO::Async::Notifier->new( %params )

This function returns a new instance of a C<IO::Async::Notifier> object.

Up until C<IO::Async> version 0.19, this module used to implement the IO
handle features now found in the C<IO::Async::Handle> subclass. To allow for a
smooth upgrade of existing code, this constructor check for any C<%params> key
which looks like it belongs there instead. These keys are C<handle>,
C<read_handle>, C<write_handle>, C<on_read_ready> and C<on_write_ready>. If
any of these keys are present, then a C<IO::Async::Handle> is returned.

Do not rely on this feature in new code.  This logic exists purely to provide
an upgrade path from older code that still expects C<IO::Async::Notifier> to
provide filehandle operations. This will eventually produce a deprecation
warning at some point in the future, and removed at some point beyond that.

=cut

sub new
{
   my $class = shift;
   my %params = @_;

   if( $class eq __PACKAGE__ ) {
      # TODO: This is temporary. Eventually, throw a deprecation warning.
      foreach my $key ( keys %params ) {
         if( grep { $key eq $_ } qw( handle read_handle write_handle on_read_ready on_write_ready ) ) {
            require IO::Async::Handle;
            return IO::Async::Handle->new( %params );
         }
      }
   }

   my $self = bless {
      children => [],
      parent   => undef,
   }, $class;

   return $self;
}

=head2 $notifier->get_loop

Returns the C<IO::Async::Loop> that this Notifier is a member of.

=cut

sub get_loop
{
   my $self = shift;
   return $self->{loop}
}

# for subclasses to override
sub _add_to_loop
{
}

sub _remove_from_loop
{
}

# Only called by IO::Async::Loop, not external interface
sub __set_loop
{
   my $self = shift;
   my ( $loop ) = @_;

   # early exit if no change
   return if !$loop and !$self->{loop} or
             $loop and $self->{loop} and $loop == $self->{loop};

   $self->_remove_from_loop( $self->{loop} ) if $self->{loop};

   $self->{loop} = $loop;
   weaken( $self->{loop} ); # To avoid a cycle

   $self->_add_to_loop( $self->{loop} ) if $self->{loop};
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
   weaken( $child->{parent} );

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

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
