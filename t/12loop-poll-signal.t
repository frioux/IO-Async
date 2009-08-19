#!/usr/bin/perl -w

use strict;

use Test::More tests => 12;
use Test::Exception;
use Test::Refcount;

use POSIX qw( SIGTERM );

use IO::Async::Loop::Poll;

my $loop = IO::Async::Loop::Poll->new();

is_oneref( $loop, '$loop has refcount 1 initally' );

my $caught;

$loop->watch_signal( TERM => sub { $caught = 1 } );

is_oneref( $loop, '$loop has refcount 1 after watch_signal()' );

$loop->loop_once( 0.1 );

is( $caught, undef, '$caught idling' );

kill SIGTERM, $$;

$loop->loop_once( 0.1 );

is( $caught, 1, '$caught after raise' );

is_oneref( $loop, '$loop has refcount 1 before unwatch_signal()' );

$loop->unwatch_signal( 'TERM' );

is_oneref( $loop, '$loop has refcount 1 after unwatch_signal()' );

my ( $cA, $cB );

my $idA = $loop->attach_signal( TERM => sub { $cA = 1 } );
my $idB = $loop->attach_signal( TERM => sub { $cB = 1 } );

is_oneref( $loop, '$loop has refcount 1 after 2 * attach_signal()' );

kill SIGTERM, $$;

$loop->loop_once( 0.1 );

is( $cA, 1, '$cA after raise' );
is( $cB, 1, '$cB after raise' );

$loop->detach_signal( 'TERM', $idA );

undef $cA;
undef $cB;

kill SIGTERM, $$;

$loop->loop_once( 0.1 );

is( $cA, undef, '$cA after raise' );
is( $cB, 1,     '$cB after raise' );

$loop->detach_signal( 'TERM', $idB );

is_oneref( $loop, '$loop has refcount 1 finally' );
