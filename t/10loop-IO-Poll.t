#!/usr/bin/perl -w

use strict;

use Test::More tests => 39;
use Test::Exception;

use IO::Socket::UNIX;
use IO::Async::Notifier;

use IO::Poll;

use IO::Async::Loop::IO_Poll;

( my $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my $readready = 0;
my $writeready = 0;

my $notifier = IO::Async::Notifier->new( handle => $S1,
   on_read_ready  => sub { $readready = 1 },
   on_write_ready => sub { $writeready = 1 },
);

my $poll = IO::Poll->new();

my $loop = IO::Async::Loop::IO_Poll->new( poll => $poll );

ok( defined $loop, '$loop defined' );
is( ref $loop, "IO::Async::Loop::IO_Poll", 'ref $loop is IO::Async::Loop::IO_Poll' );

# Empty

my @handles;
@handles = $poll->handles();

is( scalar @handles, 0, '@handles empty' );

my $count = $loop->post_poll();
is( $count, 0, '$count while empty' );

# Idle

$loop->add( $notifier );

is( $notifier->get_loop, $loop, '$notifier->__memberof_loop == $loop' );

dies_ok( sub { $loop->add( $notifier ) }, 'adding again produces error' );

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

# Write-ready
$notifier->want_writeready( 1 );

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

my $stdout_notifier = IO::Async::Notifier->new( handle => \*STDOUT,
   on_read_ready => sub { },
   on_write_ready => sub { $loop->loop_stop() },
   want_writeready => 1,
);
$loop->add( $stdout_notifier );

@handles = $poll->handles();
# We can't guarantee the order here, but we can get 'sort' to do that
is_deeply( [ sort @handles ],
           [ sort ( $S1, \*STDOUT ) ],
           '@handles after adding stdout_notifier' );

$writeready = 0;

$SIG{ALRM} = sub { die "Test timed out"; };
alarm( 1 );

$loop->loop_forever();

alarm( 0 );

is( $writeready, 1, '$writeready after loop_forever' );

$loop->remove( $stdout_notifier );

@handles = $poll->handles();
is_deeply( \@handles, [ $S1 ], '@handles after removing stdout_notifier' );

# HUP

$notifier->want_writeready( 0 );
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

$loop->remove( $notifier );

is( $notifier->get_loop, undef, '$notifier->__memberof_loop is undef' );

@handles = $poll->handles();
is( scalar @handles, 0, '@handles after removal' );

# Removal is clean (tests for workaround to bug in IO::Poll version 0.05)

$loop->add( $stdout_notifier ); # Just to make the loop non-empty

pipe( my ( $P1, $P2 ) ) or die "Cannot pipe() - $!";
my ( $N1, $N2 ) = map {
   IO::Async::Notifier->new( 
      read_handle => $_,
      on_read_ready   => sub {},
   ) } ( $P1, $P2 );

$loop->add( $N1 );
$loop->add( $N2 );

$N1->close;
$N2->close;

@handles = $poll->handles();
is( scalar @handles, 1, '@handles before clean removal test' );

$ready = $loop->loop_once( 0 );

is( $ready, 1, '$ready after clean removal test' );

$loop->remove( $stdout_notifier );

# Write-only

my $write_only_notifier = IO::Async::Notifier->new(
   write_handle => $S1,
   want_writeready => 1,
   on_write_ready => sub { $writeready = 1 },
);

$loop->add( $write_only_notifier );

$writeready = 0;
$loop->loop_once( 0 );

is( $writeready, 1, '$writeready after writeonly notifier' );

$loop->remove( $write_only_notifier );

# HUP of pipe

pipe( ( $P1, $P2 ) ) or die "Cannot pipe() - $!";
( $N1, $N2 ) = map {
   IO::Async::Notifier->new(
      read_handle => $_,
      on_read_ready   => sub { $readready = 1; },
   ) } ( $P1, $P2 );

$loop->add( $N1 );

@handles = $poll->handles();
is_deeply( \@handles, [ $P1 ], '@handles after adding pipe_notifier' );

$readready = 0;
$ready = $loop->loop_once( 0.1 );

is( $ready, 0, '$ready before pipe HUP' );
is( $readready, 0, '$readready before pipe HUP' );

undef $N2;
close( $P2 );

$readready = 0;
$ready = $loop->loop_once( 0.1 );

is( $ready, 1, '$ready after pipe HUP' );
is( $readready, 1, '$readready after pipe HUP' );

$loop->remove( $N1 );

@handles = $poll->handles();
is( scalar @handles, 0, '@handles after removing pipe_notifier' );

# Constructor with implied poll object

undef $loop;
$loop = IO::Async::Loop::IO_Poll->new();

$loop->add( $notifier );
$notifier->want_writeready( 1 );

$writeready = 0;

$ready = $loop->loop_once( 0.1 );
is( $ready, 2, '$ready after loop_once with implied IO::Poll' );
is( $writeready, 1, '$writeready after loop_once with implied IO::Poll' );
