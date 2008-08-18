#!/usr/bin/perl -w

use strict;

use Test::More tests => 4;
use Test::Refcount;
use IO::Async::Test;

use IO::Async::Stream;
use IO::Async::Loop;

my $loop = IO::Async::Loop->new();

is_oneref( $loop, '$loop has refcount 1' );

testing_loop( $loop );

is_refcount( $loop, 2, '$loop has refcount 2 after adding to IO::Async::Test' );

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

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
