#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2011 -- leonerd@leonerd.org.uk

package IO::Async::Channel;

use strict;
use warnings;

our $VERSION = '0.44';

use Storable qw( freeze thaw );

sub new
{
   my $class = shift;
   return bless {
      mode => undef,
   }, $class;
}

sub setup_sync_mode
{
   my $self = shift;
   ( $self->{fh} ) = @_;

   $self->{mode} = "sync";

   # Since we're communicating binary structures and not Unicode text we need to
   # enable binmode
   binmode $self->{fh};

   $self->{fh}->autoflush(1);
}

sub _read_exactly
{
   $_[1] = "";

   while( length $_[1] < $_[2] ) {
      my $n = read( $_[0], $_[1], $_[2]-length $_[1], length $_[1] );
      defined $n or return undef;
      $n or die "EXIT";
   }
}

sub recv
{
   my $self = shift;

   $self->{mode} eq "sync" or die "Needs to be in synchronous mode";

   my $n = _read_exactly( $self->{fh}, my $lenbuffer, 4 );
   defined $n or die "Cannot read - $!";

   my $len = unpack( "I", $lenbuffer );

   $n = _read_exactly( $self->{fh}, my $record, $len );
   defined $n or die "Cannot read - $!";

   return thaw $record;
}

sub send
{
   my $self = shift;
   my ( $data ) = @_;

   $self->{mode} eq "sync" or die "Needs to be in synchronous mode";

   my $record = freeze $data;

   $self->{fh}->print( pack( "I", length $record ) );
   $self->{fh}->print( $record );
}

0x55AA;
