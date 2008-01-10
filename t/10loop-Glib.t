#!/usr/bin/perl -w

use strict;

use constant MAIN_TESTS => 17;

use Test::More tests => MAIN_TESTS + 1;
use Test::Exception;

use IO::Socket::UNIX;
use IO::Async::Notifier;

use IO::Async::Loop::Glib;

dies_ok( sub { IO::Async::Loop::Glib->new(); },
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

my $loop = IO::Async::Loop::Glib->new();

ok( defined $loop, '$loop defined' );
is( ref $loop, "IO::Async::Loop::Glib", 'ref $loop is IO::Async::Loop::Glib' );

my $context = Glib::MainContext->default;

# Idle

$loop->add( $notifier );

is( $notifier->get_loop, $loop, '$notifier->__memberof_loop == $loop' );

dies_ok( sub { $loop->add( $notifier ) }, 'adding again produces error' );

$context->iteration( 0 );

# Read-ready

$S2->syswrite( "data\n" );

is( $readready, 0, '$readready before iteration' );

$context->iteration( 0 );

# Ready $S1 to clear the data
$S1->getline(); # ignore return

is( $readready, 1, '$readready after iteration' );

# Write-ready
$notifier->want_writeready( 1 );

is( $writeready, 0, '$writeready before iteration' );

$context->iteration( 0 );
$notifier->want_writeready( 0 );

is( $writeready, 1, '$writeready after iteration' );

# loop_once

$writeready = 0;
$notifier->want_writeready( 1 );

my $ready;
$ready = $loop->loop_once( 0.1 );

is( $ready, 1, '$ready after loop_once' );
is( $writeready, 1, '$writeready after loop_once' );

# HUP

$readready = 0;
$context->iteration( 0 );

is( $readready, 0, '$readready before HUP' );

close( $S2 );

$readready = 0;
$context->iteration( 0 );

is( $readready, 1, '$readready after HUP' );

# loop_forever

my $stdout_notifier = IO::Async::Notifier->new( handle => \*STDOUT,
   on_read_ready => sub { },
   on_write_ready => sub { $loop->loop_stop() },
   want_writeready => 1,
);
$loop->add( $stdout_notifier );

$writeready = 0;

$SIG{ALRM} = sub { die "Test timed out"; };
alarm( 1 );

$loop->loop_forever();

alarm( 0 );

is( $writeready, 1, '$writeready after loop_forever' );

$loop->remove( $stdout_notifier );

# Removal

$loop->remove( $notifier );

is( $notifier->get_loop, undef, '$notifier->__memberof_loop is undef' );

# Write-only

my $write_only_notifier = IO::Async::Notifier->new(
   write_handle => \*STDOUT,
   want_writeready => 1,
   on_write_ready => sub { $writeready = 1 },
);

$loop->add( $write_only_notifier );

$writeready = 0;
$context->iteration( 0 );

is( $writeready, 1, '$writeready after writeonly notifier' );

$loop->remove( $write_only_notifier );

# HUP of pipe

pipe( my ( $P1, $P2 ) ) or die "Cannot pipe() - $!";
my $pipe_io = IO::Handle->new_from_fd( fileno( $P1 ), 'r' );
my $pipe_notifier = IO::Async::Notifier->new(
   read_handle => $pipe_io,
   on_read_ready  => sub { $readready = 1 },
);
$loop->add( $pipe_notifier );

$readready = 0;
$context->iteration( 0 );

is( $readready, 0, '$readready before pipe HUP' );

close( $P2 );

$readready = 0;
$context->iteration( 0 );

is( $readready, 1, '$readready after pipe HUP' );

$loop->remove( $pipe_notifier );

} # for SKIP block
