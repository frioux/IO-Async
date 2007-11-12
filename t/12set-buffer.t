#!/usr/bin/perl -w

use strict;

use Test::More tests => 3;
use Test::Exception;

use IO::Socket::UNIX;

use IO::Async::Set::IO_Poll;
use IO::Async::Buffer;

my ( $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socketpair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my $closed = 0;

my $buffer = IO::Async::Buffer->new( handle => $S1,
   on_read   => sub { },
   on_closed => sub { $closed = 1 },
);

$buffer->write( "hello" );

my $set = IO::Async::Set::IO_Poll->new();
$set->add( $buffer );

is( $closed, 0, 'closed before close' );

$buffer->close;

is( $closed, 0, 'closed after close' );

$set->loop_once( 1 ) or die "Nothing ready after 1 second";

is( $closed, 1, 'closed after wait' );
