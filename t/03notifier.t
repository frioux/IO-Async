#!/usr/bin/perl -w

use strict;

use Test::More tests => 21;
use Test::Exception;

use lib qw( t );
use Listener;

use Socket;
use Fcntl;
use POSIX qw( EAGAIN );
use IO::Socket::UNIX;

use IO::SelectNotifier;

sub select_no_timeout($$$)
{
   my $ret = select( $_[0], $_[1], $_[2], 0 );
   return if $ret > 0;

   die "select() had nothing ready";
}

( my $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

our $readready = 0;
our $want_writeready = 0;
our $writeready = 0;

my $listener = Listener->new();

my $iosn = IO::SelectNotifier->new( sock => $S1, listener => $listener );

#### Pre-select;

my $testvec = '';
vec( $testvec, $S1->fileno, 1 ) = 1;

my ( $rvec, $wvec, $evec ) = ('') x 3;
my $timeout;

# Idle;

$iosn->pre_select( \$rvec, \$wvec, \$evec, \$timeout );

is( $rvec, $testvec, '$rvec idling' );
is( $wvec, '', '$wvec idling' );
is( $evec, '', '$evec idling' );
is( $timeout, undef, '$timeout idling' );

# Send-waiting;

( $rvec, $wvec, $evec ) = ('') x 3;
undef $timeout;
$want_writeready = 1;
$iosn->pre_select( \$rvec, \$wvec, \$evec, \$timeout );

is( $rvec, $testvec, '$rvec sendwaiting' );
is( $wvec, $testvec, '$wvec sendwaiting' );
is( $evec, '', '$evec sendwaiting' );
is( $timeout, undef, '$timeout sendwaiting' );

#### Select() loop;

# Receive-waiting;

$S2->syswrite( "some data" );

( $rvec, $wvec, $evec ) = ('') x 3;
undef $timeout;
$want_writeready = 0;
$iosn->pre_select( \$rvec, \$wvec, \$evec, \$timeout );

is( $rvec, $testvec, '$rvec receivewaiting' );
is( $wvec, '', '$wvec receivewaiting' );
is( $evec, '', '$evec receivewaiting' );
is( $timeout, undef, '$timeout receivewaiting' );

select_no_timeout( $rvec, $wvec, $evec );

is( $readready, 0, '$readready receivewaiting before post_select' );

$iosn->post_select( $rvec, $wvec, $evec );

is( $readready, 1, '$readready receivewaiting after post_select' );

# Clear the read-ready flag by reading the data
my $buffer;
my $n = $S1->sysread( $buffer, 8192 );
ok( defined $n, 'sysread()' );

# Send-ready;

( $rvec, $wvec, $evec ) = ('') x 3;
undef $timeout;
$want_writeready = 1;
$iosn->pre_select( \$rvec, \$wvec, \$evec, \$timeout );

is( $rvec, $testvec, '$rvec sendready' );
is( $wvec, $testvec, '$wvec sendready' );
is( $evec, '', '$evec sendready' );
is( $timeout, undef, '$timeout sendready' );

select_no_timeout( $rvec, $wvec, $evec );

is( $writeready, 0, '$writeready sendready before post_select' );

$iosn->post_select( $rvec, $wvec, $evec );

is( $writeready, 1, '$writeready sendready after post_select' );
