#!/usr/bin/perl -w

use strict;

use Test::More tests => 14;
use Test::Exception;

use IO::Socket::UNIX;
use IO::Async::Notifier;

use Glib;

use IO::Async::Set::GMainLoop;

( my $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my $readready = 0;
my $writeready = 0;

my $notifier = IO::Async::Notifier->new( handle => $S1,
   read_ready  => sub { $readready = 1 },
   write_ready => sub { $writeready = 1 },
);

my $set = IO::Async::Set::GMainLoop->new();

# Empty

my $context = Glib::MainContext->default;

ok( ! $context->pending, 'nothing pending empty' );

# Idle

$set->add( $notifier );

is( $notifier->__memberof_set, $set, '$notifier->__memberof_set == $set' );

dies_ok( sub { $set->add( $notifier ) }, 'adding again produces error' );

$context->iteration( 0 );

ok( ! $context->pending, 'nothing pending idle' );

# Read-ready

$S2->print( "data\n" );

ok( $context->pending, 'pending before readready' );
is( $readready, 0, '$readready before iteration' );

$context->iteration( 0 );

# Ready $S1 to clear the data
$S1->getline(); # ignore return

ok( ! $context->pending, 'nothing pending after readready' );
is( $readready, 1, '$readready after iteration' );

# Write-ready
$notifier->want_writeready( 1 );

ok( $context->pending, 'pending before writeready' );
is( $writeready, 0, '$writeready before iteration' );

$context->iteration( 0 );
$notifier->want_writeready( 0 );

ok( ! $context->pending, 'nothing pending after writeready' );
is( $writeready, 1, '$writeready after iteration' );

# Removal

$set->remove( $notifier );

is( $notifier->__memberof_set, undef, '$notifier->__memberof_set is undef' );

ok( ! $context->pending, 'nothing pending after removal' );
