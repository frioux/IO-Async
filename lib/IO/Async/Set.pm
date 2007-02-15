#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007 -- leonerd@leonerd.org.uk

package IO::Async::Set;

use strict;

our $VERSION = '0.01';

use Carp;

=head1 NAME

C<IO::Async::Set> - a class that maintains a set of C<IO::Async::Notifier>
objects.

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
      notifiers => {}, # {fileno} = notifier
   }, $class;

   return $self;
}

=head1 METHODS

=cut

=head2 $set->add( $notifier )

This method adds another notifier object to the stored collection. The object
may be a C<IO::Async::Notifier>, or any subclass of it.

=cut

sub add
{
   my $self = shift;
   my ( $notifier ) = @_;

   my $fileno = $notifier->fileno;

   defined $fileno or croak "Can only add a notifier bound to a socket with a fileno";

   if( defined $notifier->__memberof_set ) {
      croak "Cannot add a notifier that is already a member of a set";
   }

   $self->{notifiers}->{$fileno} = $notifier;

   $notifier->__memberof_set( $self );

   return;
}

=head2 $set->remove( $notifier )

This method removes a notifier object from the stored collection.

=cut

sub remove
{
   my $self = shift;
   my ( $notifier ) = @_;

   my $fileno = $notifier->fileno;

   defined $fileno or croak "Cannot remove a notifier that has no fileno";

   exists $self->{notifiers}->{$fileno} or croak "Notifier does not exist in collection";

   delete $self->{notifiers}->{$fileno};

   $notifier->__memberof_set( undef );

   return;
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
