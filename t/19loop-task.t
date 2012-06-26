#!/usr/bin/perl -w

use strict;

use Test::More tests => 6;
use Test::Identity;

use IO::Async::Loop;

use CPS::Future;

my $loop = IO::Async::Loop->new;

{
   my $task = CPS::Future->new;

   $loop->later( sub { $task->done( "result" ) } );

   my $ret = $loop->await( $task );
   identical( $ret, $task, '$loop->await( $task ) returns $task' );

   is_deeply( [ $task->get ], [ "result" ], '$task->get' );
}

{
   my @tasks = map { CPS::Future->new } 0 .. 2;

   do { my $id = $_; $loop->later( sub { $tasks[$id]->done } ) } for 0 .. 2;

   $loop->await_all( @tasks );

   ok( 1, '$loop->await_all' );
   ok( $tasks[$_]->is_ready, "task $_ ready" ) for 0 .. 2;
}
