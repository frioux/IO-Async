#!/usr/bin/perl -w

use strict;

use Test::More tests => 4;
use Test::Exception;

use IO::Async::Loop;
use IO::Async::Notifier;

my $loop = IO::Async::Loop->new;

my $ioan = IO::Async::Notifier->new( );

ok( defined $ioan, '$ioan defined' );
isa_ok( $ioan, "IO::Async::Notifier", '$ioan isa IO::Async::Notifier' );

is( $ioan->get_loop, undef, 'get_loop undef' );

$loop->add( $ioan );

is( $ioan->get_loop, $loop, 'get_loop $loop' );
