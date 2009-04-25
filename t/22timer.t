#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 22;
use Test::Exception;
use Test::Refcount;

use Time::HiRes qw( time );

use IO::Async::Timer;

use IO::Async::Loop::IO_Poll;

# Kindof like Test::Timer only we use Time::HiRes
sub time_between
{
   my ( $code, $lower, $upper, $name ) = @_;

   my ( $now, $took );

   $now = time;
   $code->();
   $took = time - $now;

   cmp_ok( $took, '>', $lower, "$name took at least $lower" );
   cmp_ok( $took, '<', $upper, "$name took no more than $upper" );
}

my $loop = IO::Async::Loop::IO_Poll->new();

testing_loop( $loop );

my $expired;

my $timer = IO::Async::Timer->new(
   mode  => 'countdown',
   delay => 0.2,

   on_expire => sub { $expired = 1 },
);

ok( defined $timer, '$timer defined' );
isa_ok( $timer, "IO::Async::Timer", '$timer isa IO::Async::Timer' );

is_oneref( $timer, '$timer has refcount 1 initially' );

$loop->add( $timer );

is_refcount( $timer, 2, '$timer has refcount 2 after adding to Loop' );

$timer->start;

is_refcount( $timer, 2, '$timer has refcount 2 after starting' );

ok( $timer->is_running, 'Started Timer is running' );

time_between( sub { wait_for { $expired } },
   0.19, 0.25, 'Timer works' );

ok( !$timer->is_running, 'Expired Timer is no longer running' );

is_refcount( $timer, 2, '$timer has refcount 2 before removing from Loop' );

$loop->remove( $timer );

is_oneref( $timer, '$timer has refcount 1 after removing from Loop' );

undef $expired;

$loop->add( $timer );

$timer->start;

time_between( sub { wait_for { $expired } },
   0.19, 0.25, 'Timer works a second time' );

undef $expired;
$timer->start;

$loop->loop_once( 0.1 );

$timer->stop;

$loop->loop_once( 0.2 );

ok( !$expired, "Stopped timer doesn't expire" );

undef $expired;
$timer->start;

$loop->loop_once( 0.1 );

$timer->reset;

$loop->loop_once( 0.15 );

ok( !$expired, "Reset Timer hasn't expired yet" );

time_between( sub { wait_for { $expired } },
   0.03, 0.1, 'Timer has now expired' );

undef $expired;
$timer->start;

$loop->remove( $timer );

$loop->loop_once( 0.3 );

ok( !$expired, "Removed Timer does not expire" );

$timer->start;

$loop->add( $timer );

ok( $timer->is_running, 'Pre-started Timer is running after adding' );

time_between( sub { wait_for { $expired } },
   0.19, 0.25, 'Pre-started Timer works' );

$loop->remove( $timer );

is_oneref( $timer, 'Timer has refcount 1 finally' );
