#!/usr/bin/perl -w

use strict;

use Test::More tests => 39;
use Test::Exception;
use Test::Refcount;

use IO::Poll;

use IO::Async::Loop::Poll;

my $poll = IO::Poll->new();
my $loop = IO::Async::Loop::Poll->new( poll => $poll );

ok( defined $loop, '$loop defined' );
isa_ok( $loop, "IO::Async::Loop::Poll", '$loop isa IO::Async::Loop::Poll' );

is_oneref( $loop, '$loop has refcount 1' );

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

# Empty

my @handles;
@handles = $poll->handles();

is( scalar @handles, 0, '@handles empty' );

my $count = $loop->post_poll();
is( $count, 0, '$count while empty' );

# Idle

my $readready = 0;

$loop->watch_io(
   handle => $S1,
   on_read_ready  => sub { $readready = 1 },
);

my $ready;
$ready = $poll->poll( 0.1 );

is( $ready, 0, '$ready idle' );

$count = $loop->post_poll();
is( $count, 0, '$count while idle' );

@handles = $poll->handles();
is_deeply( \@handles, [ $S1 ] , '@handles idle' );

# Read-ready

$S2->syswrite( "data\n" );

# We should still wait a little while even thought we expect to be ready
# immediately, because talking to ourself with 0 poll timeout is a race
# condition - we can still race with the kernel.

$ready = $poll->poll( 0.1 );

is( $ready, 1, '$ready readready' );

is( $readready, 0, '$readready before post_poll' );
$count = $loop->post_poll();
is( $count, 1, '$count after post_poll' );
is( $readready, 1, '$readready after post_poll' );

# Ready $S1 to clear the data
$S1->getline(); # ignore return

my $writeready = 0;

$loop->watch_io(
   handle => $S1,
   on_write_ready => sub { $writeready = 1 },
);

$ready = $poll->poll( 0.1 );

is( $ready, 1, '$ready writeready' );

is( $writeready, 0, '$writeready before post_poll' );
$count = $loop->post_poll();
is( $count, 1, '$count after post_poll' );
is( $writeready, 1, '$writeready after post_poll' );

# loop_once

$writeready = 0;

$ready = $loop->loop_once( 0.1 );

is( $ready, 1, '$ready after loop_once' );
is( $writeready, 1, '$writeready after loop_once' );

# loop_forever

$loop->watch_io(
   handle => \*STDOUT,
   on_write_ready => sub { $loop->loop_stop() },
);

@handles = $poll->handles();
# We can't guarantee the order here, but we can get 'sort' to do that
is_deeply( [ sort @handles ],
           [ sort ( $S1, \*STDOUT ) ],
           '@handles after watching STDOUT' );

$writeready = 0;

$SIG{ALRM} = sub { die "Test timed out"; };
alarm( 1 );

$loop->loop_forever();

alarm( 0 );

is( $writeready, 1, '$writeready after loop_forever' );

$loop->unwatch_io(
   handle => \*STDOUT,
   on_write_ready => 1,
);

is_oneref( $loop, '$loop has refcount 1 after removing cyclic iowatch' );

@handles = $poll->handles();
is_deeply( \@handles, [ $S1 ], '@handles after unwatching STDOUT' );

# HUP

$loop->unwatch_io(
   handle => $S1,
   on_write_ready => 1,
);

$readready = 0;
$ready = $loop->loop_once( 0.1 );

is( $ready, 0, '$ready before HUP' );
is( $readready, 0, '$readready before HUP' );

close( $S2 );

$readready = 0;
$ready = $loop->loop_once( 0.1 );

is( $ready, 1, '$ready after HUP' );
is( $readready, 1, '$readready after HUP' );

# Removal
$loop->unwatch_io(
   handle => $S1,
   on_read_ready => 1,
);

@handles = $poll->handles();
is( scalar @handles, 0, '@handles after removal' );

# Removal is clean (tests for workaround to bug in IO::Poll version 0.05)

my ( $P1, $P2 ) = $loop->pipepair() or die "Cannot pipepair - $!";

# Just to make the loop non-empty
$loop->watch_io( handle => $P2, on_read_ready => sub {} );

$loop->watch_io(
   handle => \*STDOUT,
   on_write_ready => sub {}
);

@handles = $poll->handles();
is( scalar @handles, 2, '@handles before removal in clean removal test' );

$loop->unwatch_io(
   handle => \*STDOUT,
   on_write_ready => 1,
);

@handles = $poll->handles();
is( scalar @handles, 1, '@handles after removal in clean removal test' );

$ready = $loop->loop_once( 0 );

is( $ready, 0, '$ready after clean removal test' );

$loop->unwatch_io( handle => $P2, on_read_ready => 1 );

# HUP of pipe

( $P1, $P2 ) = $loop->pipepair() or die "Cannot pipepair - $!";

$loop->watch_io(
   handle => $P1,
   on_read_ready => sub { $readready = 1 },
);

@handles = $poll->handles();
is_deeply( \@handles, [ $P1 ], '@handles after watching pipe' );

$readready = 0;
$ready = $loop->loop_once( 0.1 );

is( $ready, 0, '$ready before pipe HUP' );
is( $readready, 0, '$readready before pipe HUP' );

close( $P2 );

$readready = 0;
$ready = $loop->loop_once( 0.1 );

is( $ready, 1, '$ready after pipe HUP' );
is( $readready, 1, '$readready after pipe HUP' );

$loop->unwatch_io(
   handle => $P1,
   on_read_ready => 1,
);

@handles = $poll->handles();
is( scalar @handles, 0, '@handles after unwatching pipe' );

# Constructor with implied poll object

undef $loop;
$loop = IO::Async::Loop::Poll->new();

$loop->watch_io(
   handle => $S1,
   on_write_ready => sub { $writeready = 1 },
);

$writeready = 0;

$ready = $loop->loop_once( 0.1 );
is( $ready, 1, '$ready after loop_once with implied IO::Poll' );
is( $writeready, 1, '$writeready after loop_once with implied IO::Poll' );

is_oneref( $loop, '$loop has refcount 1 at EOF' );
