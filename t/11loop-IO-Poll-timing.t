#!/usr/bin/perl -w

use strict;

use Test::More tests => 8;

use Time::HiRes qw( time );

use IO::Async::Notifier;

use IO::Async::Loop::IO_Poll;

my $loop = IO::Async::Loop::IO_Poll->new();

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my $readready = 0;
my $writeready = 0;

my $notifier = IO::Async::Notifier->new( handle => $S1,
   on_read_ready  => sub { $readready = 1 },
   on_write_ready => sub { $writeready = 1 },
);

# loop_once

my ( $now, $took );

$now = time;
$loop->loop_once( 2 );
$took = time - $now;

cmp_ok( $took, '>', 1.9, 'loop_once(2) while idle takes at least 1.9 seconds' );
cmp_ok( $took, '<', 10, 'loop_once(2) while idle takes no more than 10 seconds' );
if( $took > 2.5 ) {
   diag( "loop_once(2) while idle took more than 2.5 seconds.\n" .
         "This is not itself a bug, and may just be an indication of a busy testing machine" );
}

$loop->add( $notifier );

$now = time;
$loop->loop_once( 2 );
$took = time - $now;

cmp_ok( $took, '>', 1.9, 'loop_once(2) while waiting takes at least 1.9 seconds' );
cmp_ok( $took, '<', 10, 'loop_once(2) while waiting takes no more than 10 seconds' );
if( $took > 2.5 ) {
   diag( "loop_once(2) while waiting took more than 2.5 seconds.\n" .
         "This is not itself a bug, and may just be an indication of a busy testing machine" );
}

$loop->remove( $notifier );

# timers

my $done = 0;

$loop->enqueue_timer( delay => 2, code => sub { $done = 1; } );

my $id = $loop->enqueue_timer( delay => 3, code => sub { die "This timer should have been cancelled" } );
$loop->cancel_timer( $id );

undef $id;

$now = time;

$loop->loop_once( 5 );

# poll() might have returned just a little early, such that the TimerQueue
# doesn't think anything is ready yet. We need to handle that case.
while( !$done ) {
   die "It should have been ready by now" if( time - $now > 5 );
   $loop->loop_once( 0.1 );
}

$took = time - $now;

cmp_ok( $took, '>', 1.9, 'loop_once(5) while waiting for timer takes at least 1.9 seconds' );
cmp_ok( $took, '<', 10, 'loop_once(5) while waiting for timer no more than 10 seconds' );
if( $took > 2.5 ) {
   diag( "loop_once(2) while waiting for timer took more than 2.5 seconds.\n" .
         "This is not itself a bug, and may just be an indication of a busy testing machine" );
}

$id = $loop->enqueue_timer( delay => 1, code => sub { $done = 2; } );
$id = $loop->requeue_timer( $id, delay => 2 );

$done = 0;

$loop->loop_once( 1 );

is( $done, 0, '$done still 0 so far' );

$loop->loop_once( 5 );

# poll() might have returned just a little early, such that the TimerQueue
# doesn't think anything is ready yet. We need to handle that case.
while( !$done ) {
   die "It should have been ready by now" if( time - $now > 5 );
   $loop->loop_once( 0.1 );
}

is( $done, 2, '$done is 2 after requeued timer' );
