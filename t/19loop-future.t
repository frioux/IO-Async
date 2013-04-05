#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Identity;
use t::TimeAbout;

use IO::Async::Loop;

use Future;
use IO::Async::Future;

use constant AUT => $ENV{TEST_QUICK_TIMERS} ? 0.1 : 1;

my $loop = IO::Async::Loop->new;

{
   my $future = Future->new;

   $loop->later( sub { $future->done( "result" ) } );

   my $ret = $loop->await( $future );
   identical( $ret, $future, '$loop->await( $future ) returns $future' );

   is_deeply( [ $future->get ], [ "result" ], '$future->get' );
}

{
   my @futures = map { Future->new } 0 .. 2;

   do { my $id = $_; $loop->later( sub { $futures[$id]->done } ) } for 0 .. 2;

   $loop->await_all( @futures );

   ok( 1, '$loop->await_all' );
   ok( $futures[$_]->is_ready, "future $_ ready" ) for 0 .. 2;
}

{
   my $future = IO::Async::Future->new( $loop );

   identical( $future->loop, $loop, '$future->loop yields $loop' );

   $loop->later( sub { $future->done( "result" ) } );

   is_deeply( [ $future->get ], [ "result" ], '$future->get on IO::Async::Future' );
}

{
   my $future = $loop->new_future;

   $loop->later( sub { $future->done( "result" ) } );

   is_deeply( [ $future->get ], [ "result" ], '$future->get on IO::Async::Future from $loop->new_future' );
}

# delay_future
{
   my $future = $loop->delay_future( after => 1 * AUT );

   time_about( sub { $loop->await( $future ) }, 1, '->delay_future is ready' );

   ok( $future->is_ready, '$future is ready from delay_future' );
   is_deeply( [ $future->get ], [], '$future->get returns empty list on delay_future' );

   # Check that ->cancel does not crash
   $loop->delay_future( after => 1 * AUT )->cancel;
}

# timeout_future
{
   my $future = $loop->timeout_future( after => 1 * AUT );

   time_about( sub { $loop->await( $future ) }, 1, '->timeout_future is ready' );

   ok( $future->is_ready, '$future is ready from timeout_future' );
   is( $future->failure, "Timeout", '$future failed with "Timeout" for timeout_future' );

   # Check that ->cancel does not crash
   $loop->timeout_future( after => 1 * AUT )->cancel;
}

done_testing;
