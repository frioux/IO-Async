#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 30;
use Test::Exception;
use Test::Refcount;

use Time::HiRes qw( time );

use IO::Async::Timer::Periodic;

use IO::Async::Loop::Poll;

use constant AUT => $ENV{TEST_QUICK_TIMERS} ? 0.1 : 1;

# Kindof like Test::Timer only we use Time::HiRes
sub time_between
{
   my ( $code, $lower, $upper, $name ) = @_;

   my $now = time;
   $code->();
   my $took = (time - $now) / AUT;

   cmp_ok( $took, '>', $lower, "$name took at least $lower" );
   cmp_ok( $took, '<', $upper, "$name took no more than $upper" );
}

my $loop = IO::Async::Loop::Poll->new();

testing_loop( $loop );

my $tick = 0;

my $timer = IO::Async::Timer::Periodic->new(
   interval => 2 * AUT,

   on_tick => sub { $tick++ },
);

ok( defined $timer, '$timer defined' );
isa_ok( $timer, "IO::Async::Timer", '$timer isa IO::Async::Timer' );

is_oneref( $timer, '$timer has refcount 1 initially' );

$loop->add( $timer );

is_refcount( $timer, 2, '$timer has refcount 2 after adding to Loop' );

is( $timer->start, $timer, '$timer->start returns $timer' );

is_refcount( $timer, 2, '$timer has refcount 2 after starting' );

ok( $timer->is_running, 'Started Timer is running' );

time_between( sub { wait_for { $tick == 1 } },
   1.5, 2.5, 'Timer works' );

ok( $timer->is_running, 'Timer is still running' );

time_between( sub { wait_for { $tick == 2 } },
   1.5, 2.5, 'Timer works a second time' );

$loop->loop_once( 1 * AUT );

$timer->stop;

$loop->loop_once( 2 * AUT );

ok( $tick == 2, "Stopped timer doesn't tick" );

is_refcount( $timer, 2, '$timer has refcount 2 before removing from Loop' );

$loop->remove( $timer );

is_oneref( $timer, '$timer has refcount 1 after removing from Loop' );

ok( !$timer->is_running, 'Removed timer not running' );

$loop->add( $timer );

$timer->configure( interval => 1 * AUT );

$timer->start;

time_between( sub { wait_for { $tick == 3 } },
   0.5, 1.5, 'Reconfigured timer interval works' );

dies_ok( sub { $timer->configure( interval => 5 ); },
         'Configure a running timer fails' );

$loop->remove( $timer );

is_oneref( $timer, 'Timer has refcount 1 finally' );

undef $timer;

## Subclass

my $sub_tick = 0;

$timer = TestTimer->new(
   interval => 2 * AUT,
);

ok( defined $timer, 'subclass $timer defined' );
isa_ok( $timer, "IO::Async::Timer", 'subclass $timer isa IO::Async::Timer' );

is_oneref( $timer, 'subclass $timer has refcount 1 initially' );

$loop->add( $timer );

is_refcount( $timer, 2, 'subclass $timer has refcount 2 after adding to Loop' );

$timer->start;

is_refcount( $timer, 2, 'subclass $timer has refcount 2 after starting' );

ok( $timer->is_running, 'Started subclass Timer is running' );

time_between( sub { wait_for { $sub_tick == 1 } },
   1.5, 2.5, 'subclass Timer works' );

is_refcount( $timer, 2, 'subclass $timer has refcount 2 before removing from Loop' );

$loop->remove( $timer );

is_oneref( $timer, 'subclass $timer has refcount 1 after removing from Loop' );

undef $timer;

package TestTimer;
use base qw( IO::Async::Timer::Periodic );

sub on_tick { $sub_tick++ }
