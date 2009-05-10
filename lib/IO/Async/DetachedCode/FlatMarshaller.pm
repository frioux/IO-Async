#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007 -- leonerd@leonerd.org.uk

package # hide from CPAN
  IO::Async::DetachedCode::FlatMarshaller;

use strict;
use warnings;

use Carp;

use constant LENGTH_OF_I => length( pack( "I", 0 ) );

sub new
{
   my $class = shift;
   return bless {}, $class;
}

sub marshall_args
{
   my ( $self ) = shift;
   my ( $id, $args ) = @_;

   my $buffer = "";

   foreach( @$args ) {
      croak "Cannot marshall a ".ref($_)." using the 'flat' marshaller" if ref $_;

      $buffer .= defined $_ ?
         pack( "i", length( $_ ) ) . $_ :
         pack( "i", -1 );
   }

   return $buffer;
}

sub unmarshall_args
{
   my ( $self ) = shift;
   my ( $id, $record ) = @_;

   my @args;

   while( length $record ) {
      my $arglen = unpack( "i", $record );
      substr( $record, 0, LENGTH_OF_I, "" );

      if( $arglen == -1 ) {
         push @args, undef;
      }
      else {
         push @args, substr( $record, 0, $arglen, "" );
      }
   }

   return ( \@args );
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
