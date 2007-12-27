#!/usr/bin/perl -w

use strict;

use Test::More tests => 6;
use Test::Exception;

use POSIX qw( SIGUSR1 );

use IO::Async::Loop::IO_Poll;

my $loop = IO::Async::Loop::IO_Poll->new();

my $caught = "";

$loop->attach_signal( USR1 => sub { $caught .= "1" } );

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
