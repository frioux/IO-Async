#!/usr/bin/perl

use strict;
use warnings;

use IO::Async::Test;

use Test::More;
use Test::Fatal;
use Test::Refcount;
use t::TimeAbout;

use IO::Async::Timer::Periodic;

use IO::Async::Loop;

use constant AUT => $ENV{TEST_QUICK_TIMERS} ? 0.1 : 1;

my $loop = IO::Async::Loop->new_builtin;

testing_loop( $loop );

{
   my $tick = 0;
   my @targs;

   my $timer = IO::Async::Timer::Periodic->new(
      interval => 2 * AUT,

      on_tick => sub { @targs = @_; $tick++ },
   );

   ok( defined $timer, '$timer defined' );
   isa_ok( $timer, "IO::Async::Timer", '$timer isa IO::Async::Timer' );

   is_oneref( $timer, '$timer has refcount 1 initially' );

   $loop->add( $timer );

   is_refcount( $timer, 2, '$timer has refcount 2 after adding to Loop' );

   is( $timer->start, $timer, '$timer->start returns $timer' );

   is_refcount( $timer, 2, '$timer has refcount 2 after starting' );

   ok( $timer->is_running, 'Started Timer is running' );

   time_about( sub { wait_for { $tick == 1 } }, 2, 'Timer works' );
   is_deeply( \@targs, [ $timer ], 'on_tick args' );

   ok( $timer->is_running, 'Timer is still running' );

   time_about( sub { wait_for { $tick == 2 } }, 2, 'Timer works a second time' );

   $loop->loop_once( 1 * AUT );

   $timer->stop;

   $timer->stop;

   ok( 1, "Timer can be stopped a second time" );

   $loop->loop_once( 2 * AUT );

   ok( $tick == 2, "Stopped timer doesn't tick" );

   undef @targs;

   is_refcount( $timer, 2, '$timer has refcount 2 before removing from Loop' );

   $loop->remove( $timer );

   is_oneref( $timer, '$timer has refcount 1 after removing from Loop' );

   ok( !$timer->is_running, 'Removed timer not running' );

   $loop->add( $timer );

   $timer->configure( interval => 1 * AUT );

   $timer->start;

   time_about( sub { wait_for { $tick == 3 } }, 1, 'Reconfigured timer interval works' );

   $timer->stop;

   $timer->configure( interval => 2 * AUT, first_interval => 0 );

   $timer->start;
   is( $tick, 3, 'Zero first_interval start not invoked yet' );
   time_about( sub { wait_for { $tick == 4 } }, 0, 'Zero first_interval invokes callback async' );

   time_about( sub { wait_for { $tick == 5 } }, 2, 'Normal interval used after first invocation' );

   ok( exception { $timer->configure( interval => 5 ); },
       'Configure a running timer fails' );

   $loop->remove( $timer );

   undef @targs;

   is_oneref( $timer, 'Timer has refcount 1 finally' );
}

# reschedule => "skip"
{
   my $tick = 0;

   my $timer = IO::Async::Timer::Periodic->new(
      interval => 1 * AUT,
      reschedule => "skip",

      on_tick => sub { $tick++ },
   );

   $loop->add( $timer );
   $timer->start;

   time_about( sub { wait_for { $tick == 1 } }, 1, 'skip Timer works' );

   ok( $timer->is_running, 'skip Timer is still running' );

   time_about( sub { wait_for { $tick == 2 } }, 1, 'skip Timer ticks a second time' );

   $loop->remove( $timer );
}

# reschedule => "drift"
{
   my $tick = 0;

   my $timer = IO::Async::Timer::Periodic->new(
      interval => 1 * AUT,
      reschedule => "drift",

      on_tick => sub { $tick++ },
   );

   $loop->add( $timer );
   $timer->start;

   time_about( sub { wait_for { $tick == 1 } }, 1, 'drift Timer works' );

   ok( $timer->is_running, 'drift Timer is still running' );

   time_about( sub { wait_for { $tick == 2 } }, 1, 'drift Timer ticks a second time' );

   $loop->remove( $timer );
}

# Self-stopping
{
   my $count = 0;
   my $timer = IO::Async::Timer::Periodic->new(
      interval => 0.1 * AUT,

      on_tick => sub { $count++; shift->stop if $count >= 5 },
   );

   $loop->add( $timer );
   $timer->start;

   my $timedout;
   my $id = $loop->watch_time( after => 1 * AUT, code => sub { $timedout++ } );

   wait_for { $timedout };

   is( $count, 5, 'Self-stopping timer can stop itself' );

   $loop->remove( $timer );
   $loop->unwatch_time( $id );
}

## Subclass

my $sub_tick = 0;

{
   my $timer = TestTimer->new(
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

   time_about( sub { wait_for { $sub_tick == 1 } }, 2, 'subclass Timer works' );

   is_refcount( $timer, 2, 'subclass $timer has refcount 2 before removing from Loop' );

   $loop->remove( $timer );

   is_oneref( $timer, 'subclass $timer has refcount 1 after removing from Loop' );
}

done_testing;

package TestTimer;
use base qw( IO::Async::Timer::Periodic );

sub on_tick { $sub_tick++ }
