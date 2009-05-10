#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007 -- leonerd@leonerd.org.uk

package # hide from CPAN
  IO::Async::DetachedCode::StorableMarshaller;

use strict;
use warnings;

use Storable qw( freeze thaw );

use Carp;

sub new
{
   my $class = shift;
   return bless {}, $class;
}

sub marshall_args
{
   my ( $self ) = shift;
   my ( $id, $args ) = @_;

   return freeze( $args );
}

sub unmarshall_args
{
   my ( $self ) = shift;
   my ( $id, $record ) = @_;

   return thaw( $record );
}

sub marshall_ret
{
   my $self = shift;
   my ( $id, $ret ) = @_;

   return $self->marshall_args( $id, $ret );
}

sub unmarshall_ret
{
   my $self = shift;
   my ( $id, $record ) = @_;

   return $self->unmarshall_args( $id, $record );
}

# Keep perl happy; keep Britain tidy
1;
