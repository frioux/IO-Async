#!/usr/bin/perl -w

use strict;

use Test::More tests => 10;
use Test::Exception;
use Test::Refcount;

use IO::Async::Loop;

use IO::Async::Notifier;

my $loop = IO::Async::Loop->new();

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my $readready = 0;
my $writeready = 0;

my $notifier = IO::Async::Notifier->new(
   handle => $S1,
   on_read_ready  => sub { $readready = 1 },
   on_write_ready => sub { $writeready = 1 },
);

$loop->add( $notifier );

is( $notifier->get_loop, $loop, '$notifier->get_loop is $loop' );

is_oneref( $loop, '$loop has refcount 1 adding Notifier' );

dies_ok( sub { $loop->add( $notifier ) }, 'adding again produces error' );

$loop->loop_once( 0.1 );

is( $readready,  0, '$readready while idle' );
is( $writeready, 0, '$writeready while idle' );

# Read-ready

$S2->syswrite( "data\n" );

$loop->loop_once( 0.1 );

is( $readready,  1, '$readready while readable' );
is( $writeready, 0, '$writeready while readable' );

$readready = 0;

# Ready $S1 to clear the data
$S1->getline(); # ignore return

$notifier->want_writeready( 1 );

$loop->loop_once( 0.1 );

is( $readready,  0, '$readready while writeable' );
is( $writeready, 1, '$writeready while writeable' );

$loop->remove( $notifier );

is( $notifier->get_loop, undef, '$notifier->get_loop is undef' );
