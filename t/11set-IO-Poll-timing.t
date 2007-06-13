#!/usr/bin/perl -w

use strict;

use Test::More tests => 4;

use Time::HiRes qw( time );

use IO::Socket::UNIX;
use IO::Async::Notifier;

use IO::Async::Set::IO_Poll;

( my $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my $readready = 0;
my $writeready = 0;

my $notifier = IO::Async::Notifier->new( handle => $S1,
   on_read_ready  => sub { $readready = 1 },
   on_write_ready => sub { $writeready = 1 },
);

my $set = IO::Async::Set::IO_Poll->new();

# loop_once

my ( $now, $took );

$now = time;
$set->loop_once( 2 );
$took = time - $now;

cmp_ok( $took, '>', 1.9, 'loop_once(2) while idle takes at least 1.9 seconds' );
cmp_ok( $took, '<', 2.5, 'loop_once(2) while idle takes no more than 2.5 seconds' );

$set->add( $notifier );

$now = time;
$set->loop_once( 2 );
$took = time - $now;

cmp_ok( $took, '>', 1.9, 'loop_once(2) while waiting takes at least 1.9 seconds' );
cmp_ok( $took, '<', 2.5, 'loop_once(2) while waiting takes no more than 2.5 seconds' );
