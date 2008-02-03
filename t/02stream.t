#!/usr/bin/perl -w

use strict;

use Test::More tests => 29;
use Test::Exception;

use POSIX qw( EAGAIN ECONNRESET );
use IO::Socket::UNIX;

use IO::Async::Stream;

( my $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

dies_ok( sub { IO::Async::Stream->new( handle => $S1 ) },
         'No on_read' );

lives_ok( sub { IO::Async::Stream->new( write_handle => \*STDOUT ) },
          'Write-only Stream works' );

sub read_data($)
{
   my ( $s ) = @_;

   my $buffer;
   my $ret = sysread( $s, $buffer, 8192 );

   return $buffer if( defined $ret && $ret > 0 );
   die "Socket closed" if( defined $ret && $ret == 0 );
   return "" if( $! == EAGAIN );
   die "Cannot sysread() - $!";
}

my @received;
my $closed = 0;
my $empty = 0;

sub on_read
{
   my $self = shift;
   my ( $buffref, $buffclosed ) = @_;

   if( $buffclosed ) {
      $closed = $buffclosed;
      @received = ();
      return 0;
   }

   return 0 unless( $$buffref =~ s/^(.*\n)// );
   push @received, $1;
   return 1;
}

my $stream = IO::Async::Stream->new( 
   handle => $S1,
   on_read => \&on_read,
   on_outgoing_empty => sub { $empty = 1 },
);

ok( defined $stream, '$stream defined' );
is( ref $stream, "IO::Async::Stream", 'ref $stream is IO::Async::Stream' );

# Writing

is( $stream->want_writeready, 0, 'want_writeready before write' );
$stream->write( "message\n" );

is( $stream->want_writeready, 1, 'want_writeready after write' );

is( scalar @received, 0,  '@received before writing buffer' );
is( $closed,          0,  '$closed before writing buffer' );
is( read_data( $S2 ), "", 'data before writing buffer' );

is( $empty, 0, '$empty before writing buffer' );

$stream->on_write_ready;

is( $stream->want_writeready, 0, 'want_writeready after on_write_ready' );
is( $empty, 1, '$empty after writing buffer' );

is( scalar @received, 0,           '@received before writing buffer' );
is( $closed,          0,           '$closed before writing buffer' );
is( read_data( $S2 ), "message\n", 'data after writing buffer' );

# Receiving

$S2->syswrite( "reply\n" );

$stream->on_read_ready;

is( scalar @received, 1,         'scalar @received receiving after select' );
is( $received[0],     "reply\n", '$received[0] receiving after select' );
is( $closed,          0,         '$closed receiving after select' );

@received = ();

# Buffer chaining;

# Write partial buffer;

$S2->syswrite( "return" );

$stream->on_read_ready;

is( scalar @received, 0, 'scalar @received writepartial 1' );
is( $closed,          0, '$closed writepartial 1' );

$S2->syswrite( "\n" );

$stream->on_read_ready;

is( scalar @received, 1,          'scalar @received receiving after select' );
is( $received[0],     "return\n", '$received[0] writepartial 2' );
is( $closed,          0,          '$closed writepartial 2' );

package ErrorSocket;

our $errno;

sub new      { return bless [], shift; }
sub DESTROY  { }
sub fileno   { 100; }
sub sysread  { $! = $errno; undef; }
sub syswrite { $! = $errno; undef; }
sub close    { }

package main;

# Spurious reports to no ill effects
{
   my $warning;
   local $SIG{__WARN__} = sub { $warning .= join( "", @_ ) };

   my $stream = IO::Async::Stream->new(
      handle => ErrorSocket->new(),
      on_read => sub {},
   );

   $ErrorSocket::errno = EAGAIN;

   $warning = "";
   $stream->on_read_ready;

   is( $warning, "", 'Spurious on_read_ready does not print a warning' );

   $warning = "";
   $stream->on_write_ready;

   is( $warning, "", 'Spurious on_write_ready does not print a warning' );
}

@received = ();

# Close

close( $S2 );
undef $S2;

$stream->on_read_ready;

is( scalar @received, 0, 'scalar @received receiving after select' );
is( $closed,          1, '$closed after close' );

# Socket errors
$ErrorSocket::errno = ECONNRESET;

my $read_errno;
my $write_errno;

$stream = IO::Async::Stream->new(
   handle => ErrorSocket->new(),
   on_read => sub {},

   on_read_error  => sub { ( undef, $read_errno ) = @_ },
);

$stream->on_read_ready;

cmp_ok( $read_errno, "==", ECONNRESET, 'errno after failed read' );

$stream = IO::Async::Stream->new(
   handle => ErrorSocket->new(),
   on_read => sub {},

   on_write_error  => sub { ( undef, $write_errno ) = @_ },
);

$stream->write( "hello" );

$stream->on_write_ready;

cmp_ok( $write_errno, "==", ECONNRESET, 'errno after failed write' );
