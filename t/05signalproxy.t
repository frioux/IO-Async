#!/usr/bin/perl -w

use strict;

use Test::More tests => 10;
use Test::Exception;

use POSIX qw( SIGUSR1 SIGUSR2 SIGTERM );

use IO::Async::SignalProxy;

my $caught = "";

# Avoid the deprecation warning
my $proxy;
{
   no warnings 'deprecated';
   $proxy = IO::Async::SignalProxy->new();
}

ok( defined $proxy, '$proxy defined' );
is( ref $proxy, "IO::Async::SignalProxy", 'ref $proxy is IO::Async::SignalProxy' );

$proxy->attach( USR1 => sub { $caught .= "1" } );
$proxy->attach( USR2 => sub { $caught .= "2" } );

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
