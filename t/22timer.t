#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 38;
use Test::Exception;
use Test::Refcount;

use Time::HiRes qw( time );

use IO::Async::Timer;

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

my $expired;

my $timer = IO::Async::Timer->new(
   mode  => 'countdown',
   delay => 2 * AUT,

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
   1.5, 2.5, 'Timer works' );

ok( !$timer->is_running, 'Expired Timer is no longer running' );

is_refcount( $timer, 2, '$timer has refcount 2 before removing from Loop' );

$loop->remove( $timer );

is_oneref( $timer, '$timer has refcount 1 after removing from Loop' );

undef $expired;

$loop->add( $timer );

$timer->start;

time_between( sub { wait_for { $expired } },
   1.5, 2.5, 'Timer works a second time' );

undef $expired;
$timer->start;

$loop->loop_once( 1 * AUT );

$timer->stop;

$loop->loop_once( 2 * AUT );

ok( !$expired, "Stopped timer doesn't expire" );

undef $expired;
$timer->start;

$loop->loop_once( 1 * AUT );

my $now = time;
$timer->reset;

$loop->loop_once( 1.5 * AUT );

ok( !$expired, "Reset Timer hasn't expired yet" );

wait_for { $expired };
my $took = (time - $now) / AUT;

cmp_ok( $took, '>', 1.5, "Timer has now expired took at least 1.5" );
cmp_ok( $took, '<', 2.5, "Timer has now expired took no more than 2.5" );

undef $expired;
$timer->start;

$loop->remove( $timer );

$loop->loop_once( 3 * AUT );

ok( !$expired, "Removed Timer does not expire" );

$timer->start;

$loop->add( $timer );

ok( $timer->is_running, 'Pre-started Timer is running after adding' );

time_between( sub { wait_for { $expired } },
   1.5, 2.5, 'Pre-started Timer works' );

$timer->configure( delay => 1 * AUT );

undef $expired;
$timer->start;

time_between( sub { wait_for { $expired } },
   0.5, 1.5, 'Reconfigured timer delay works' );

my $new_expired;
$timer->configure( on_expire => sub { $new_expired = 1 } );

$timer->start;

time_between( sub { wait_for { $new_expired } },
   0.5, 1.5, 'Reconfigured timer on_expire works' );

$timer->start;
dies_ok( sub { $timer->configure( delay => 5 ); },
         'Configure a running timer fails' );

$loop->remove( $timer );

is_oneref( $timer, 'Timer has refcount 1 finally' );

undef $timer;

## Subclass

my $sub_expired;

$timer = TestTimer->new(
   mode  => 'countdown',
   delay => 2 * AUT,
);

ok( defined $timer, 'subclass $timer defined' );
isa_ok( $timer, "IO::Async::Timer", 'subclass $timer isa IO::Async::Timer' );

is_oneref( $timer, 'subclass $timer has refcount 1 initially' );

$loop->add( $timer );

is_refcount( $timer, 2, 'subclass $timer has refcount 2 after adding to Loop' );

$timer->start;

is_refcount( $timer, 2, 'subclass $timer has refcount 2 after starting' );

ok( $timer->is_running, 'Started subclass Timer is running' );

time_between( sub { wait_for { $sub_expired } },
   1.5, 2.5, 'subclass Timer works' );

ok( !$timer->is_running, 'Expired subclass Timer is no longer running' );

is_refcount( $timer, 2, 'subclass $timer has refcount 2 before removing from Loop' );

$loop->remove( $timer );

is_oneref( $timer, 'subclass $timer has refcount 1 after removing from Loop' );

undef $timer;

package TestTimer;
use base qw( IO::Async::Timer );

sub on_expire { $sub_expired = 1 }
