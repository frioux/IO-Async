#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006-2009 -- leonerd@leonerd.org.uk

package IO::Async::Notifier;

use strict;

our $VERSION = '0.19';

use Carp;
use Scalar::Util qw( weaken );

=head1 NAME

C<IO::Async::Notifier> - base class for C<IO::Async> event objects

=head1 SYNOPSIS

 TODO

=head1 DESCRIPTION

This object class forms the basis for all the other event objects that an
C<IO::Async> program uses. It provides the lowest level of integration with a
C<IO::Async::Loop> container, and a facility to collect Notifiers together, in
a tree structure, where any Notifier can contain a collection of children.

This class itself performs no actual IO work, and generates no actual events.
These are all left to the various subclasses, such as:

=over 4

=item *

L<IO::Async::Handle> - event callbacks for a non-blocking file descriptor

=item *

L<IO::Async::Stream> - read and write buffers around an IO handle

=item *

L<IO::Async::Sequencer> - handle a serial pipeline of requests / responses (EXPERIMENTAL)

=back

For more detail, see the SYNOPSIS section in one of the above.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $notifier = IO::Async::Notifier->new()

This function returns a new instance of a C<IO::Async::Notifier> object.

=cut

sub new
{
   my $class = shift;

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
