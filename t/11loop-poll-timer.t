#!/usr/bin/perl -w

use strict;

use Test::More tests => 6;

use Time::HiRes qw( time );

use IO::Async::Loop::IO_Poll;

use constant AUT => $ENV{TEST_QUICK_TIMERS} ? 0.1 : 1;

my $loop = IO::Async::Loop::IO_Poll->new();

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

# loop_once

my ( $now, $took );

$now = time;
$loop->loop_once( 2 * AUT );
$took = (time - $now) / AUT;

cmp_ok( $took, '>', 1.9, 'loop_once(2) while idle takes at least 1.9 seconds' );
cmp_ok( $took, '<', 10, 'loop_once(2) while idle takes no more than 10 seconds' );
if( $took > 2.5 ) {
   diag( "loop_once(2) while idle took more than 2.5 seconds.\n" .
         "This is not itself a bug, and may just be an indication of a busy testing machine" );
}

# timers

my $done = 0;

$loop->enqueue_timer( delay => 2 * AUT, code => sub { $done = 1; } );

my $id = $loop->enqueue_timer( delay => 3 * AUT, code => sub { die "This timer should have been cancelled" } );
$loop->cancel_timer( $id );

undef $id;

$now = time;

$loop->loop_once( 5 * AUT );

# poll() might have returned just a little early, such that the TimerQueue
# doesn't think anything is ready yet. We need to handle that case.
while( !$done ) {
   die "It should have been ready by now" if( time - $now > 5 * AUT );
   $loop->loop_once( 0.1 * AUT );
}

$took = (time - $now) / AUT;

cmp_ok( $took, '>', 1.9, 'loop_once(5) while waiting for timer takes at least 1.9 seconds' );
cmp_ok( $took, '<', 10, 'loop_once(5) while waiting for timer no more than 10 seconds' );
if( $took > 2.5 ) {
   diag( "loop_once(2) while waiting for timer took more than 2.5 seconds.\n" .
         "This is not itself a bug, and may just be an indication of a busy testing machine" );
}

$id = $loop->enqueue_timer( delay => 1 * AUT, code => sub { $done = 2; } );
$id = $loop->requeue_timer( $id, delay => 2 * AUT );

$done = 0;

$loop->loop_once( 1 * AUT );

is( $done, 0, '$done still 0 so far' );

$loop->loop_once( 5 * AUT );

# poll() might have returned just a little early, such that the TimerQueue
# doesn't think anything is ready yet. We need to handle that case.
while( !$done ) {
   die "It should have been ready by now" if( time - $now > 5 * AUT );
   $loop->loop_once( 0.1 * AUT );
}

is( $done, 2, '$done is 2 after requeued timer' );
