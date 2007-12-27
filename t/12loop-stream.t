#!/usr/bin/perl -w

use strict;

use Test::More tests => 3;
use Test::Exception;

use IO::Socket::UNIX;

use IO::Async::Loop::IO_Poll;
use IO::Async::Stream;

my ( $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socketpair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my $closed = 0;

my $stream = IO::Async::Stream->new( handle => $S1,
   on_read   => sub { },
   on_closed => sub { $closed = 1 },
);

$stream->write( "hello" );

my $loop = IO::Async::Loop::IO_Poll->new();
$loop->add( $stream );

is( $closed, 0, 'closed before close' );

$stream->close;

is( $closed, 0, 'closed after close' );

$loop->loop_once( 1 ) or die "Nothing ready after 1 second";

is( $closed, 1, 'closed after wait' );
