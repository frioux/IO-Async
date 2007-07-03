#!/usr/bin/perl -w

use strict;

use constant MAIN_TESTS => 20;

use Test::More tests => MAIN_TESTS + 1;
use Test::Exception;

use IO::Socket::UNIX;
use IO::Async::Notifier;

use IO::Async::Set::GMainLoop;

dies_ok( sub { IO::Async::Set::GMainLoop->new(); },
         'No Glib loaded' );

SKIP: { # Don't indent because most of this script is within the block; it would look messy

if( !defined eval { require Glib } ) {
   skip "No Glib available", MAIN_TESTS;
   exit 0;
}

( my $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my $readready = 0;
my $writeready = 0;

my $notifier = IO::Async::Notifier->new( handle => $S1,
   on_read_ready  => sub { $readready = 1; return 0 },
   on_write_ready => sub { $writeready = 1; return 0 },
);

my $set = IO::Async::Set::GMainLoop->new();

ok( defined $set, '$set defined' );
is( ref $set, "IO::Async::Set::GMainLoop", 'ref $set is IO::Async::Set::GMainLoop' );

# Empty

my $context = Glib::MainContext->default;

ok( ! $context->pending, 'nothing pending empty' );

# Idle

$set->add( $notifier );

is( $notifier->__memberof_set, $set, '$notifier->__memberof_set == $set' );

dies_ok( sub { $set->add( $notifier ) }, 'adding again produces error' );

$context->iteration( 0 );

ok( ! $context->pending, 'nothing pending idle' );

# Read-ready

$S2->syswrite( "data\n" );

ok( $context->pending, 'pending before readready' );
is( $readready, 0, '$readready before iteration' );

$context->iteration( 0 );

# Ready $S1 to clear the data
$S1->getline(); # ignore return

ok( ! $context->pending, 'nothing pending after readready' );
is( $readready, 1, '$readready after iteration' );

# Write-ready
$notifier->want_writeready( 1 );

ok( $context->pending, 'pending before writeready' );
is( $writeready, 0, '$writeready before iteration' );

$context->iteration( 0 );
$notifier->want_writeready( 0 );

ok( ! $context->pending, 'nothing pending after writeready' );
is( $writeready, 1, '$writeready after iteration' );

# HUP

$readready = 0;
$context->iteration( 0 );

is( $readready, 0, '$readready before HUP' );

close( $S2 );

$readready = 0;
$context->iteration( 0 );

is( $readready, 1, '$readready after HUP' );

# Removal

$set->remove( $notifier );

is( $notifier->__memberof_set, undef, '$notifier->__memberof_set is undef' );

ok( ! $context->pending, 'nothing pending after removal' );

# HUP of pipe

pipe( my ( $P1, $P2 ) ) or die "Cannot pipe() - $!";
my $pipe_io = IO::Handle->new_from_fd( fileno( $P1 ), 'r' );
my $pipe_notifier = IO::Async::Notifier->new( handle => $pipe_io,
   on_read_ready  => sub { $readready = 1 },
   want_writeready => 0,
);
$set->add( $pipe_notifier );

$readready = 0;
$context->iteration( 0 );

is( $readready, 0, '$readready before pipe HUP' );

close( $P2 );

$readready = 0;
$context->iteration( 0 );

is( $readready, 1, '$readready after pipe HUP' );

$set->remove( $pipe_notifier );

} # for SKIP block
