#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2011 -- leonerd@leonerd.org.uk

package IO::Async::Channel;

use strict;
use warnings;
use base qw( IO::Async::Notifier ); # just to get _capture_weakself

our $VERSION = '0.45';

use Carp;
use Storable qw( freeze thaw );

sub new
{
   my $class = shift;
   return bless {
      mode => undef,
   }, $class;
}

sub send
{
   my $self = shift;
   my ( $data ) = @_;

   my $record = freeze $data;
   $self->send_frozen( $record );
}

sub send_frozen
{
   my $self = shift;
   my ( $record ) = @_;

   my $bytes = pack( "I", length $record ) . $record;

   defined $self->{mode} or die "Cannot ->send without being set up";

   return $self->_send_sync( $bytes )  if $self->{mode} eq "sync";
   return $self->_send_async( $bytes ) if $self->{mode} eq "async";
}

sub close
{
   my $self = shift;

   return $self->_close_sync  if $self->{mode} eq "sync";
   return $self->_close_async if $self->{mode} eq "async";
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
      $n or return "";
   }

   return $_[2];
}

sub recv
{
   my $self = shift;

   $self->{mode} eq "sync" or die "Needs to be in synchronous mode";

   my $n = _read_exactly( $self->{fh}, my $lenbuffer, 4 );
   defined $n or die "Cannot read - $!";
   length $n or return undef;

   my $len = unpack( "I", $lenbuffer );

   $n = _read_exactly( $self->{fh}, my $record, $len );
   defined $n or die "Cannot read - $!";
   length $n or return undef;

   return thaw $record;
}

sub _send_sync
{
   my $self = shift;
   my ( $bytes ) = @_;
   $self->{fh}->print( $bytes );
}

sub _close_sync
{
   my $self = shift;
   $self->{fh}->close;
}

sub setup_async_mode
{
   my $self = shift;
   my %args = @_;

   my $stream = delete $args{stream} or croak "Expected 'stream'";

   if( my $on_recv = delete $args{on_recv} ) {
      $stream->configure( on_read => $self->_capture_weakself( '_on_stream_read' ) );
      $self->{on_recv} = $on_recv;
      $self->{on_eof} = delete $args{on_eof};
   }

   keys %args and croak "Unrecognised keys for setup_async_mode: " . join( ", ", keys %args );

   $self->{stream} = $stream;
   $self->{mode} = "async";

   $stream->configure( autoflush => 1 );
}

sub _send_async
{
   my $self = shift;
   my ( $bytes ) = @_;
   $self->{stream}->write( $bytes );
}

sub _close_async
{
   my $self = shift;
   $self->{stream}->close_when_empty;
}

sub _on_stream_read
{
   my $self = shift;
   my ( $stream, $buffref, $eof ) = @_;

   if( $eof ) {
      $self->{on_eof}->( $self );
      return;
   }

   return 0 unless length( $$buffref ) >= 4;
   my $len = unpack( "I", $$buffref );
   return 0 unless length( $$buffref ) >= 4 + $len;

   my $record = thaw( substr( $$buffref, 4, $len ) );
   substr( $$buffref, 0, 4 + $len ) = "";

   $self->{on_recv}->( $self, $record );

   return 1;
}

0x55AA;
