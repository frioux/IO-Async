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

   defined $fileno or carp "Can only add a notifier bound to a socket with a fileno";

   $self->{notifiers}->{$fileno} = $notifier;

   return;
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
