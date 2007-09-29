#!/usr/bin/perl -w

use strict;

use constant MAIN_TESTS => 2;

use Test::More tests => MAIN_TESTS;

use Time::HiRes qw( time );

use IO::Socket::UNIX;

use IO::Async::Set::GMainLoop;

SKIP: { # Don't indent because most of this script is within the block; it would look messy

if( !defined eval { require Glib } ) {
   skip "No Glib available", MAIN_TESTS;
   exit 0;
}

my $set = IO::Async::Set::GMainLoop->new();

my $context = Glib::MainContext->default;

ok( ! $context->pending, 'nothing pending empty' );

my $done = 0;

$set->enqueue_timer( delay => 2, code => sub { $done = 1; } );

my ( $now, $took );

$SIG{ALRM} = sub { die "Test timed out" };
alarm 4;

$now = time;
# GLib might return just a little early, such that the TimerQueue
# doesn't think anything is ready yet. We need to handle that case.
$context->iteration( 1 ) while !$done;
$took = time - $now;

alarm 0;

is( $done, 1, '$done after iteration while waiting for timer' );

} # for SKIP block
