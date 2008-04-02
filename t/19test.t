#!/usr/bin/perl -w

use strict;

use Test::More tests => 2;
use IO::Async::Test;

use IO::Socket::UNIX;

use IO::Async::Stream;
use IO::Async::Loop::IO_Poll;

my $loop = IO::Async::Loop::IO_Poll->new();
testing_loop( $loop );

( my $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

my $readbuffer = "";

my $stream = IO::Async::Stream->new( 
   handle => $S1,
   on_read => sub {
      my ( $stream, $buffref, $closed ) = @_;
      $readbuffer .= $$buffref;
      $$buffref = "";
   },
);

$loop->add( $stream );

# This is just a token "does it run once?" test. A test of a test script. 
# Mmmmmm. Meta-testing.
# Coming up with a proper test that would guarantee multiple loop_once()
# cycles, etc.. is difficult. TODO for later I feel.
# In any case, the wait_for() function is effectively tested to death in later
# test scripts which use it. If it fails to work, they'd notice it.

$S2->syswrite( "A line\n" );

wait_for { $readbuffer =~ m/\n/ };

is( $readbuffer, "A line\n", 'Single-wait' );

$loop->remove( $stream );

# Now the automatic version

$readbuffer = "";

$S2->syswrite( "Another line\n" );

wait_for_stream { $readbuffer =~ m/\n/ } $S1 => $readbuffer;

is( $readbuffer, "Another line\n", 'Automatic stream read wait' );
