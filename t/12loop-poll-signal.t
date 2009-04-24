#!/usr/bin/perl -w

use strict;

use Test::More tests => 13;
use Test::Exception;
use Test::Refcount;

use POSIX qw( SIGUSR1 SIGUSR2 SIGTERM );

use IO::Async::Loop::IO_Poll;

my $loop = IO::Async::Loop::IO_Poll->new();

my $caught = "";

$loop->watch_signal( USR1 => sub { $caught .= "1" } );
$loop->watch_signal( USR2 => sub { $caught .= "2" } );

is_oneref( $loop, '$loop has refcount 1' );

my $ready;

# Idle

$ready = $loop->loop_once( 0.1 );
is( $ready,  0,  '$ready idling' );
is( $caught, "", '$caught idling' );

# Raise
kill SIGUSR1, $$;

$ready = $loop->loop_once( 0.1 );
is( $ready,  1,   '$ready after raise' );
is( $caught, "1", '$caught after raise' );

# Count

$caught = "";

kill SIGUSR1, $$;
kill SIGUSR1, $$;

$ready = $loop->loop_once( 0.1 );
is( $ready,  1,    '$ready after double-raise' );
is( $caught, "11", '$caught after double-raise' );

# Ordering

$caught = "";

kill SIGUSR1, $$;
kill SIGUSR2, $$;

$ready = $loop->loop_once( 0.1 );
is( $caught, "12", '$caught after first order test' );

$caught = "";

kill SIGUSR2, $$;
kill SIGUSR1, $$;

$ready = $loop->loop_once( 0.1 );
is( $caught, "21", '$caught after second order test' );

$loop->watch_signal( TERM => sub { $caught .= "T" } );

$caught = "";

kill SIGTERM, $$;

$ready = $loop->loop_once( 0.1 );
is( $caught, "T", '$caught after dynamic watch of SIGTERM' );

$loop->unwatch_signal( "TERM" );
$SIG{TERM} = "IGNORE";

$caught = "";

kill SIGTERM, $$;

$ready = $loop->loop_once( 0.1 );
is( $caught, "", '$caught empty after dynamic removal of SIGTERM' );

dies_ok( sub { $loop->unwatch_signal( "INT" ); },
         'unwatch of non-watched signal fails' );

is_oneref( $loop, '$loop has refcount 1 at EOF' );

$loop->unwatch_signal( "USR1" );
$loop->unwatch_signal( "USR2" );
