#!/usr/bin/perl -w

use strict;

use Test::More tests => 14;
use Test::Exception;

use lib qw( t );
use Listener;

use IO::Socket::UNIX;
use IO::Async::Notifier;

use IO::Poll;

use IO::Async::Set::IO_Poll;

( my $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

our $readready = 0;
our $writeready = 0;

my $listener = Listener->new();
my $notifier = IO::Async::Notifier->new( sock => $S1, listener => $listener );

my $poll = IO::Poll->new();

my $set = IO::Async::Set::IO_Poll->new( poll => $poll );

# Empty

my @handles;
@handles = $poll->handles();

is( scalar @handles, 0, '@handles empty' );

# Idle

$set->add( $notifier );

is( $notifier->__memberof_set, $set, '$notifier->__memberof_set == $set' );

dies_ok( sub { $set->add( $notifier ) }, 'adding again produces error' );

@handles = $poll->handles();
is( scalar @handles, 0, '@handles idle' );

$set->pre_poll();
my $ready;
$ready = $poll->poll( 0 );

is( $ready, 0, '$ready idle' );

@handles = $poll->handles();
is( scalar @handles, 1, '@handles idle' );

# Read-ready

$S2->print( "data\n" );

$set->pre_poll();
$ready = $poll->poll( 0 );

is( $ready, 1, '$ready readready' );

is( $readready, 0, '$readready before post_poll' );
$set->post_poll();
is( $readready, 1, '$readready after post_poll' );

# Ready $S1 to clear the data
$S1->getline(); # ignore return

# Write-ready
$notifier->want_writeready( 1 );

$set->pre_poll();
$ready = $poll->poll( 0 );

is( $ready, 1, '$ready writeready' );

is( $writeready, 0, '$writeready before post_poll' );
$set->post_poll();
is( $writeready, 1, '$writeready after post_poll' );

# Removal

$set->remove( $notifier );

is( $notifier->__memberof_set, undef, '$notifier->__memberof_set is undef' );

$set->pre_poll();

@handles = $poll->handles();
is( scalar @handles, 0, '@handles after removal' );
