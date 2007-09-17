#!/usr/bin/perl -w

use strict;

use constant MAIN_TESTS => 2;

use Test::More tests => MAIN_TESTS;

use Time::HiRes qw( time );

use IO::Socket::UNIX;

use IO::Async::Set::GMainLoop;

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
$context->iteration( 1 );
$took = time - $now;

alarm 0;

# GLib may need to be poked again to actually fire the timeout, since it may
# only have been woken up above
$context->iteration( 0 );

is( $done, 1, '$done after iteration while waiting for timer' );
