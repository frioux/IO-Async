#!/usr/bin/perl -w

use strict;

use constant MAIN_TESTS => 3;

use Test::More tests => MAIN_TESTS;

use Time::HiRes qw( time );

use IO::Socket::UNIX;

use IO::Async::Loop::Glib;

SKIP: { # Don't indent because most of this script is within the block; it would look messy

if( !defined eval { require Glib } ) {
   skip "No Glib available", MAIN_TESTS;
   exit 0;
}

my $loop = IO::Async::Loop::Glib->new();

my $context = Glib::MainContext->default;

my $done = 0;

$loop->enqueue_timer( delay => 2, code => sub { $done = 1; } );

my $id = $loop->enqueue_timer( delay => 5, code => sub { die "This timer should have been cancelled" } );
$loop->cancel_timer( $id );

undef $id;

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

cmp_ok( $took, '>', 1.9, 'iteration while waiting for timer takes at least 1.9 seconds' );
cmp_ok( $took, '<', 10, 'iteration while waiting for timer no more than 10 seconds' );
if( $took > 2.5 ) {
   diag( "iteration while waiting for timer took more than 2.5 seconds.\n" .
         "This is not itself a bug, and may just be an indication of a busy testing machine" );
}

} # for SKIP block
