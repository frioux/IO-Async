#!/usr/bin/perl -w

use strict;

use Test::More tests => 9;

use Time::HiRes qw( time );

use IO::Socket::UNIX;

use IO::Async::Loop::Select;

my $loop = IO::Async::Loop::Select->new();

my ( $rvec, $wvec, $evec ) = ('') x 3;
my $timeout;

$loop->pre_select( \$rvec, \$wvec, \$evec, \$timeout );
is( $timeout, undef, '$timeout idling pre_select' );

$timeout = 5;

$loop->pre_select( \$rvec, \$wvec, \$evec, \$timeout );
is( $timeout, 5, '$timeout idling pre_select with timeout' );

my $done = 0;
$loop->enqueue_timer( delay => 2, code => sub { $done = 1; } );

my $id = $loop->enqueue_timer( delay => 5, code => sub { die "This timer should have been cancelled" } );
$loop->cancel_timer( $id );

undef $id;

$loop->pre_select( \$rvec, \$wvec, \$evec, \$timeout );
cmp_ok( $timeout, '>', 1.9, '$timeout while timer waiting pre_select at least 1.9' );
cmp_ok( $timeout, '<', 2.5, '$timeout while timer waiting pre_select at least 2.5' );

my ( $now, $took );

$now = time;
select( $rvec, $wvec, $evec, $timeout );
$took = time - $now;

cmp_ok( $took, '>', 1.9, 'loop_once(5) while waiting for timer takes at least 1.9 seconds' );
cmp_ok( $took, '<', 10, 'loop_once(5) while waiting for timer no more than 10 seconds' );
if( $took > 2.5 ) {
   diag( "took more than 2.5 seconds to select().\n" .
         "This is not itself a bug, and may just be an indication of a busy testing machine" );
}

$loop->post_select( $rvec, $evec, $wvec );

# select() might have returned just a little early, such that the TimerQueue
# doesn't think anything is ready yet. We need to handle that case.
while( !$done ) {
   die "It should have been ready by now" if( time - $now > 5 );

   $timeout = 0.1;

   $loop->pre_select( \$rvec, \$wvec, \$evec, \$timeout );
   select( $rvec, $wvec, $evec, $timeout );
   $loop->post_select( $rvec, $evec, $wvec );
}

is( $done, 1, '$done after post_select while waiting for timer' );

$id = $loop->enqueue_timer( delay => 1, code => sub { $done = 2; } );
$id = $loop->requeue_timer( $id, delay => 2 );

$done = 0;
$now = time;

$loop->pre_select( \$rvec, \$wvec, \$evec, \$timeout );
select( $rvec, $wvec, $evec, 1.5 );
$loop->post_select( $rvec, $evec, $wvec );

is( $done, 0, '$done still 0 before timeout' );

while( !$done ) {
   die "It should have been ready by now" if( time - $now > 5 );

   $timeout = 0.1;

   $loop->pre_select( \$rvec, \$wvec, \$evec, \$timeout );
   select( $rvec, $wvec, $evec, $timeout );
   $loop->post_select( $rvec, $evec, $wvec );
}

is( $done, 2, '$done is 2 after timeout' );
