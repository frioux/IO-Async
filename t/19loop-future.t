#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Identity;

use IO::Async::Loop;

use Future;
use IO::Async::Future;

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

   $loop->later( sub { $future->done( "result" ) } );

   is_deeply( [ $future->get ], [ "result" ], '$future->get on IO::Async::Future' );
}

{
   my $future = $loop->new_future;

   $loop->later( sub { $future->done( "result" ) } );

   is_deeply( [ $future->get ], [ "result" ], '$future->get on IO::Async::Future from $loop->new_future' );
}

done_testing;
