#!/usr/bin/perl -w

use strict;

use Test::More tests => 2;
use Test::Identity;

use IO::Async::Loop;

use CPS::Future;

my $loop = IO::Async::Loop->new;

my $task = CPS::Future->new;

$loop->later( sub { $task->done( "result" ) } );

my $ret;
$ret = $loop->await( $task );
identical( $ret, $task, '$loop->await( $task ) returns $task' );

is_deeply( [ $task->get ], [ "result" ], '$task->get' );
