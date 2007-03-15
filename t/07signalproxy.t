#!/usr/bin/perl -w

use strict;

use Test::More tests => 13;
use Test::Exception;

use POSIX qw( SIGUSR1 SIGUSR2 SIGTERM );

use IO::Async::SignalProxy;

# Check some error conditions

dies_ok( sub { IO::Async::SignalProxy->new( 
                  signal_DOESNOTEXIST => sub { },
               ); },
         'Nonexistent signal name fails to construct' );

$SIG{HUP} = sub { };
dies_ok( sub { IO::Async::SignalProxy->new(
                  signal_HUP => sub { },
               ); },
         'Overridden signal fails to construct' );

$SIG{HUP} = "IGNORE";
lives_ok( sub { IO::Async::SignalProxy->new(
                   signal_HUP => sub { },
                ); },
          'IGNOREd signal constructs' );

is( $SIG{HUP}, "IGNORE", 'Object destructor restores old value' );

$SIG{HUP} = "DEFAULT";
lives_ok( sub { IO::Async::SignalProxy->new(
                   signal_HUP => sub { },
                ); },
          'DEFAULT signal constructs' );

my $caught = "";

my $proxy = IO::Async::SignalProxy->new(
   signal_USR1 => sub { $caught .= "1" },
   signal_USR2 => sub { $caught .= "2" },
);

# Idle

$proxy->on_read_ready;
is( $caught, "", '$caught idling' );

# Raise
kill SIGUSR1, $$;

$proxy->on_read_ready;
is( $caught, "1", '$caught after raise' );

# Count

$caught = "";

kill SIGUSR1, $$;
kill SIGUSR1, $$;

$proxy->on_read_ready;
is( $caught, "11", '$caught after double-raise' );

# Ordering

$caught = "";

kill SIGUSR1, $$;
kill SIGUSR2, $$;

$proxy->on_read_ready;
is( $caught, "12", '$caught after first order test' );

$caught = "";

kill SIGUSR2, $$;
kill SIGUSR1, $$;

$proxy->on_read_ready;
is( $caught, "21", '$caught after second order test' );

# Dynamic attachment

$proxy->attach( TERM => sub { $caught .= "T" } );

$caught = "";

kill SIGTERM, $$;

$proxy->on_read_ready;
is( $caught, "T", '$caught after dynamic attachment of SIGTERM' );

$proxy->detach( "TERM" );
$SIG{TERM} = "IGNORE";

$caught = "";

kill SIGTERM, $$;

$proxy->on_read_ready;
is( $caught, "", '$caught empty after dynamic removal of SIGTERM' );

dies_ok( sub { $proxy->detach( "INT" ); },
         'Detachment of non-attached signal fails' );
