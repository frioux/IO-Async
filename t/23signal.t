#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 8;
use Test::Exception;
use Test::Refcount;

use POSIX qw( SIGTERM );

use IO::Async::Signal;

use IO::Async::Loop;

my $loop = IO::Async::Loop->new();

testing_loop( $loop );

my $caught = 0;

my $signal = IO::Async::Signal->new(
   name => 'TERM',
   on_receipt => sub { $caught++ },
);

ok( defined $signal, '$signal defined' );
isa_ok( $signal, "IO::Async::Signal", '$signal isa IO::Async::Signal' );

is_oneref( $signal, '$signal has refcount 1 initially' );

$loop->add( $signal );

is_refcount( $signal, 2, '$signal has refcount 2 after adding to Loop' );

# Idle

$loop->loop_once( 0.1 );

is( $caught, 0, '$caught idling' );

# Raise
kill SIGTERM, $$;

wait_for { $caught };

is( $caught, 1, '$caught after raise' );

is_refcount( $signal, 2, '$signal has refcount 2 before removing from Loop' );

$loop->remove( $signal );

is_oneref( $signal, '$signal has refcount 1 finally' );
