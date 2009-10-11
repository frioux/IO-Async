#!/usr/bin/perl -w

use strict;

use Test::More tests => 9;

use Time::HiRes qw( time );

use IO::Async::Loop::Select;

my $loop = IO::Async::Loop::Select->new();

my $called = 0;

my $id = $loop->watch_idle( when => 'later', code => sub { $called++ } );

ok( defined $id, 'idle watcher id is defined' );

is( $called, 0, 'deferred sub not yet invoked' );

my ( $now, $took );

$now = time;
$loop->loop_once( 3 );
$took = time - $now;

is( $called, 1, 'deferred sub called after loop_once' );

cmp_ok( $took, '<', 1, 'loop_once(3) with deferred sub takes no more than 1 second' );

$loop->watch_idle( when => 'later', code => sub {
   $loop->watch_idle( when => 'later', code => sub { $called++ } )
} );

$loop->loop_once( 1 );

is( $called, 1, 'inner deferral not yet invoked' );

$loop->loop_once( 1 );

is( $called, 2, 'inner deferral now invoked' );

$id = $loop->watch_idle( when => 'later', code => sub { $called = 20 } );

$loop->unwatch_idle( $id );

$now = time;
$loop->loop_once( 1 );
$took = time - $now;

is( $called, 2, 'unwatched deferral not called' );

cmp_ok( $took, '>', '0.9', 'loop_once(1) with unwatched deferral takes more than 0.9 seconds' );

$loop->later( sub { $called++ } );

$loop->loop_once( 1 );

is( $called, 3, '$loop->later() shortcut works' );
