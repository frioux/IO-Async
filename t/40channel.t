#!/usr/bin/perl -w

use strict;

use Test::More tests => 1;

use IO::Async::Channel;

use IO::Async::Loop::Poll;

my $loop = IO::Async::Loop::Poll->new;

my ( $pipe_rd, $pipe_wr ) = $loop->pipepair;

my $channel_rd = IO::Async::Channel->new;
$channel_rd->setup_sync_mode( $pipe_rd );

my $channel_wr = IO::Async::Channel->new;
$channel_wr->setup_sync_mode( $pipe_wr );

$channel_wr->send( [ structure => "here" ] );

is_deeply( $channel_rd->recv, [ structure => "here" ], 'Sync mode channels can send/recv structures' );
