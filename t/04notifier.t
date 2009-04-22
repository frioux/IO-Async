#!/usr/bin/perl -w

use strict;

use Test::More tests => 12;
use Test::Exception;
use Test::Refcount;

use IO::Async::Loop;
use IO::Async::Notifier;

my $loop = IO::Async::Loop->new;

is_oneref( $loop, '$loop has refcount 1 initially' );

my $notifier = IO::Async::Notifier->new( );

ok( defined $notifier, '$notifier defined' );
isa_ok( $notifier, "IO::Async::Notifier", '$notifier isa IO::Async::Notifier' );

is_oneref( $notifier, '$notifier has refcount 1 initially' );

is( $notifier->get_loop, undef, 'get_loop undef' );

$loop->add( $notifier );

is_oneref( $loop, '$loop has refcount 1 adding Notifier' );
is_refcount( $notifier, 2, '$notifier has refcount 2 after adding to Loop' );

is( $notifier->get_loop, $loop, 'get_loop $loop' );

dies_ok( sub { $loop->add( $notifier ) }, 'adding again produces error' );

$loop->remove( $notifier );

is( $notifier->get_loop, undef, '$notifier->get_loop is undef' );

is_oneref( $loop, '$loop has refcount 1 finally' );
is_oneref( $notifier, '$notifier has refcount 1 finally' );
