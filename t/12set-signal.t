#!/usr/bin/perl -w

use strict;

use Test::More tests => 9;
use Test::Exception;

use POSIX qw( SIGUSR1 );

use IO::Async::Set::IO_Poll;

my $set = IO::Async::Set::IO_Poll->new();

my $proxy = $set->get_sigproxy;

ok( defined $proxy, 'defined $proxy' );
ok( ref $proxy, 'ref $proxy' );
ok( $proxy->isa( "IO::Async::SignalProxy" ), '$proxy isa SignalProxy' );

my $caught = "";

$set->attach_signal( USR1 => sub { $caught .= "1" } );

my $ready;

# Idle

$ready = $set->loop_once( 0.1 );
is( $ready,  0,  '$ready idling' );
is( $caught, "", '$caught idling' );

# Raise
kill SIGUSR1, $$;

$ready = $set->loop_once( 0.1 );
is( $ready,  1,   '$ready after raise' );
is( $caught, "1", '$caught after raise' );

# Count

$caught = "";

kill SIGUSR1, $$;
kill SIGUSR1, $$;

$ready = $set->loop_once( 0.1 );
is( $ready,  1,    '$ready after double-raise' );
is( $caught, "11", '$caught after double-raise' );
