#!/usr/bin/perl -w

use strict;

use Test::More tests => 4;
use Test::Exception;
use Test::Refcount;

use IO::Async::Loop;

use IO::Async::Notifier;

my $loop = IO::Async::Loop->new();

my $readready = 0;
my $writeready = 0;

my $notifier = IO::Async::Notifier->new();

$loop->add( $notifier );

is( $notifier->get_loop, $loop, '$notifier->get_loop is $loop' );

is_oneref( $loop, '$loop has refcount 1 adding Notifier' );

dies_ok( sub { $loop->add( $notifier ) }, 'adding again produces error' );

$loop->remove( $notifier );

is( $notifier->get_loop, undef, '$notifier->get_loop is undef' );
