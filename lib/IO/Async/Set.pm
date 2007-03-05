#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007 -- leonerd@leonerd.org.uk

package IO::Async::Set;

use strict;

our $VERSION = '0.02';

use Carp;

=head1 NAME

C<IO::Async::Set> - a class that maintains a set of C<IO::Async::Notifier>
objects.

=head1 SYNOPSIS

This module would not be used directly; see the subclasses:

=over 4

=item L<IO::Async::Set::Select>

=item L<IO::Async::Set::IO_Perl>

=item L<IO::Async::Set::GMainLoop>

=back

=head1 DESCRIPTION


This module provides an abstract class to store a set of
C<IO::Async::Notifier> objects or subclasses of them. It handles all of the
lower-level set manipulation actions, and leaves the actual IO readiness 
testing/notification to the concrete class that implements it.

=cut

# Internal constructor used by subclasses
sub __new
{
   my $class = shift;

   my $self = bless {
      notifiers => {}, # {nkey} = notifier
   }, $class;

   return $self;
}

=head1 METHODS

=cut

# Internal method
sub _nkey
{
   my $self = shift;
   my ( $notifier ) = @_;

   # We key the notifiers by their reading fileno; because every notifier
   # needs to have one.
   my $nkey = $notifier->read_fileno;

   defined $nkey or croak "Cannot operate on a notifer that is not read-bound to a handle with a fileno";

   return $nkey;
}

=head2 $set->add( $notifier )

This method adds another notifier object to the stored collection. The object
may be a C<IO::Async::Notifier>, or any subclass of it.

=cut

sub add
{
   my $self = shift;
   my ( $notifier ) = @_;

   my $nkey = $self->_nkey( $notifier );

   if( defined $notifier->__memberof_set ) {
      croak "Cannot add a notifier that is already a member of a set";
   }

   $self->{notifiers}->{$nkey} = $notifier;

   $notifier->__memberof_set( $self );

   $self->__notifier_want_writeready( $notifier, $notifier->want_writeready );

   return;
}

=head2 $set->remove( $notifier )

This method removes a notifier object from the stored collection.

=cut

sub remove
{
   my $self = shift;
   my ( $notifier ) = @_;

   my $nkey = $self->_nkey( $notifier );

   exists $self->{notifiers}->{$nkey} or croak "Notifier does not exist in collection";

   delete $self->{notifiers}->{$nkey};

   $notifier->__memberof_set( undef );

   return;
}

# For ::Notifier to call
sub __notifier_want_writeready
{
   my $self = shift;
   my ( $notifier, $want_writeready ) = @_;
   # Ignore
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
