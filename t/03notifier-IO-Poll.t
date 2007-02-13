#!/usr/bin/perl -w

use strict;

use Test::More tests => 13;
use Test::Exception;

use lib qw( t );
use Listener;

use Socket;
use Fcntl;
use IO::Poll qw( POLLIN POLLOUT );
use IO::Socket::UNIX;

use IO::Async::Notifier;

sub poll_no_timeout($)
{
   my $ret = $_[0]->poll( 0 );
   return if $ret > 0;

   die "poll() had nothing ready";
}

( my $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

our $readready = 0;
our $writeready = 0;

my $listener = Listener->new();

my $ioan = IO::Async::Notifier->new( sock => $S1, listener => $listener, want_writeready => 0 );

#### Pre-poll;

my $poll = IO::Poll->new();

my $timeout;

# Idle;

$ioan->pre_poll( $poll, \$timeout );

is( $poll->mask($S1), POLLIN, 'mask idling' );
is( $timeout, undef, '$timeout idling' );

# Send-waiting;

undef $timeout;
$ioan->want_writeready( 1 );
$ioan->pre_poll( $poll, \$timeout );

is( $poll->mask($S1), POLLIN|POLLOUT, 'mask sendwaiting' );
is( $timeout, undef, '$timeout sendwaiting' );

#### Poll() loop;

# Receive-waiting;

$S2->syswrite( "some data" );

undef $timeout;
$ioan->want_writeready( 0 );
$ioan->pre_poll( $poll, \$timeout );

is( $poll->mask($S1), POLLIN, 'mask receivewaiting' );
is( $timeout, undef, '$timeout receivewaiting' );

poll_no_timeout( $poll );

is( $readready, 0, '$readready receivewaiting before post_poll' );

$ioan->post_poll( $poll );

is( $readready, 1, '$readready receivewaiting after post_poll' );

# Clear the read-ready flag by reading the data
my $buffer;
my $n = $S1->sysread( $buffer, 8192 );
ok( defined $n, 'sysread()' );

# Send-ready;

undef $timeout;
$ioan->want_writeready( 1 );
$ioan->pre_poll( $poll, \$timeout );

is( $poll->mask($S1), POLLIN|POLLOUT, 'mask sendready' );
is( $timeout, undef, '$timeout sendready' );

poll_no_timeout( $poll );

is( $writeready, 0, '$writeready sendready before post_poll' );

$ioan->post_poll( $poll );

is( $writeready, 1, '$writeready sendready after post_poll' );
