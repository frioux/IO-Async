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

my $buff = IO::Async::Buffer->new( sock => $S1, receiver => $recv );

# First corner case - byte at a time

foreach( split( m//, "my line here\n" ) ) {
   $S2->syswrite( $_ );

   is( scalar @received, 0, 'scalar @received no data yet' );
   $buff->read_ready;
}

is( scalar @received, 1,                'scalar @received line' );
is( $received[0],     "my line here\n", '$received[0] line' );

@received = ();

# Second corner case - multiple lines at once

$S2->syswrite( "my\nlines\nhere\n" );

$buff->read_ready;

is( scalar @received, 3,         'scalar @received line' );
is( $received[0],     "my\n",    '$recieved[0] line' );
is( $received[1],     "lines\n", '$recieved[0] line' );
is( $received[2],     "here\n",  '$recieved[0] line' );
