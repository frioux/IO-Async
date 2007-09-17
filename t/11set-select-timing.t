#!/usr/bin/perl -w

use strict;

use Test::More tests => 6;

use Time::HiRes qw( time );

use IO::Socket::UNIX;

use IO::Async::Set::Select;

my $set = IO::Async::Set::Select->new();

my ( $rvec, $wvec, $evec ) = ('') x 3;
my $timeout;

$set->pre_select( \$rvec, \$wvec, \$evec, \$timeout );
is( $timeout, undef, '$timeout idling pre_select' );

$timeout = 5;

$set->pre_select( \$rvec, \$wvec, \$evec, \$timeout );
is( $timeout, 5, '$timeout idling pre_select with timeout' );

my $done = 0;
$set->enqueue_timer( delay => 2, code => sub { $done = 1; } );

$set->pre_select( \$rvec, \$wvec, \$evec, \$timeout );
is( $timeout, 2, '$timeout while timer waiting pre_select' );

my ( $now, $took );

$now = time;
select( $rvec, $wvec, $evec, $timeout );
$took = time - $now;

cmp_ok( $took, '>', 1.9, 'loop_once(5) while waiting for timer takes at least 1.9 seconds' );
cmp_ok( $took, '<', 2.5, 'loop_once(5) while waiting for timer no more than 2.5 seconds' );

$set->post_select( $rvec, $evec, $wvec );

is( $done, 1, '$done after post_select while waiting for timer' );
