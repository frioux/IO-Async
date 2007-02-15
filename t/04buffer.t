#!/usr/bin/perl -w

use strict;

use Test::More tests => 19;
use Test::Exception;

use lib qw( t );
use Receiver;

use POSIX qw( EAGAIN );
use IO::Socket::UNIX;

use IO::Async::Buffer;

( my $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

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

our @received;
our $closed = 0;

my $recv = Receiver->new();

my $buff = IO::Async::Buffer->new( handle => $S1, receiver => $recv );

# Sending

is( $buff->want_writeready, 0, 'want_writeready before send' );
$buff->send( "message\n" );

is( $buff->want_writeready, 1, 'want_writeready after send' );

is( scalar @received, 0,  '@received before sending buffer' );
is( $closed,          0,  '$closed before sending buffer' );
is( read_data( $S2 ), "", 'data before sending buffer' );

$buff->write_ready;

is( $buff->want_writeready, 0, 'want_writeready after write_ready' );

is( scalar @received, 0,           '@received before sending buffer' );
is( $closed,          0,           '$closed before sending buffer' );
is( read_data( $S2 ), "message\n", 'data after sending buffer' );

# Receiving

$S2->syswrite( "reply\n" );

$buff->read_ready;

is( scalar @received, 1,         'scalar @received receiving after select' );
is( $received[0],     "reply\n", '$received[0] receiving after select' );
is( $closed,          0,         '$closed receiving after select' );

@received = ();

# Buffer chaining;

# Send partial buffer;

$S2->syswrite( "return" );

$buff->read_ready;

is( scalar @received, 0, 'scalar @received sendpartial 1' );
is( $closed,          0, '$closed sendpartial 1' );

$S2->syswrite( "\n" );

$buff->read_ready;

is( scalar @received, 1,          'scalar @received receiving after select' );
is( $received[0],     "return\n", '$received[0] sendpartial 2' );
is( $closed,          0,          '$closed sendpartial 2' );

@received = ();

# Close

close( $S2 );
undef $S2;

$buff->read_ready;

is( scalar @received, 0, 'scalar @received receiving after select' );
is( $closed,          1, '$closed after close' );
