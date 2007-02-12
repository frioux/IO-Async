#!/usr/bin/perl -w

use strict;

use Test::More tests => 37;
use Test::Exception;

use lib qw( t );
use Receiver;

use Socket;
use Fcntl;
use POSIX qw( EAGAIN );
use IO::Socket::UNIX;

use IO::Async::Buffer;

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

sub read_data($)
{
   my ( $s ) = @_;

   my $buffer;
   my $ret = sysread( $s, $buffer, 8192 );

   return $buffer if( defined $ret && $ret > 0 );
   die "Socket closed" if( defined $ret && $ret == 0 );
   return "" if( $! == EAGAIN );
   die "Cannot sysread() - $!";
}

our @received;
our $closed = 0;

my $recv = Receiver->new();

my $buff = IO::Async::Buffer->new( sock => $S1, receiver => $recv );

#### Pre-select;

my $testvec = '';
vec( $testvec, $S1->fileno, 1 ) = 1;

my ( $rvec, $wvec, $evec ) = ('') x 3;
my $timeout;

# Idle;

$buff->pre_select( \$rvec, \$wvec, \$evec, \$timeout );

is( $rvec, $testvec, '$rvec idling' );
is( $wvec, '', '$wvec idling' );
is( $evec, '', '$evec idling' );
is( $timeout, undef, '$timeout idling' );

# Send-waiting;

( $rvec, $wvec, $evec ) = ('') x 3;
undef $timeout;
$buff->send( "message\n" );
$buff->pre_select( \$rvec, \$wvec, \$evec, \$timeout );

is( $rvec, $testvec, '$rvec sendwaiting' );
is( $wvec, $testvec, '$wvec sendwaiting' );
is( $evec, '', '$evec sendwaiting' );
is( $timeout, undef, '$timeout sendwaiting' );

#### Sending select() loop;

# Before;

is( scalar @received, 0,  '@received before sending buffer' );
is( $closed,          0,  '$closed before sending buffer' );
is( read_data( $S2 ), "", 'data before sending buffer' );

# Send buffer;

select_no_timeout( $rvec, $wvec, $evec );

$buff->post_select( $rvec, $wvec, $evec );

is( scalar @received, 0,           '@received after sending buffer' );
is( $closed,          0,           '$closed after sending buffer' );
is( read_data( $S2 ), "message\n", 'data after sending buffer' );

# After;

( $rvec, $wvec, $evec ) = ('') x 3;
$buff->pre_select( \$rvec, \$wvec, \$evec, \$timeout );

is( $rvec, $testvec, '$rvec receivewaiting' );
is( $wvec, '', '$wvec receivewaiting' );
is( $evec, '', '$evec receivewaiting' );
is( $timeout, undef, '$timeout receivewaiting' );

#### Receiving select() loop;

# Before;

( $rvec, $wvec, $evec ) = ('') x 3;
$buff->pre_select( \$rvec, \$wvec, \$evec, \$timeout );

is( $rvec, $testvec, '$rvec receiving before select' );
is( $wvec, '', '$wvec receiving before select' );
is( $evec, '', '$evec receiving before select' );
is( $timeout, undef, '$timeout receiving before select' );

# Receive buffer;

$S2->syswrite( "reply\n" );

select_no_timeout( $rvec, $wvec, $evec );

is( $rvec, $testvec, '$rvec receiving after select' );

$buff->post_select( $rvec, $wvec, $evec );

is( scalar @received, 1,         'scalar @received receiving after select' );
is( $received[0],     "reply\n", '$received[0] receiving after select' );
is( $closed,          0,         '$closed receiving after select' );

@received = ();

#### Buffer chaining;

# Send partial buffer;

$S2->syswrite( "return" );
( $rvec, $wvec, $evec ) = ('') x 3;
$buff->pre_select( \$rvec, \$wvec, \$evec, \$timeout );
select_no_timeout( $rvec, $wvec, $evec );
$buff->post_select( $rvec, $wvec, $evec );

is( scalar @received, 0, 'scalar @received sendpartial 1' );
is( $closed,          0, '$closed sendpartial 1' );

# Finish buffer;

$S2->syswrite( "\n" );
( $rvec, $wvec, $evec ) = ('') x 3;
$buff->pre_select( \$rvec, \$wvec, \$evec, \$timeout );
select_no_timeout( $rvec, $wvec, $evec );
$buff->post_select( $rvec, $wvec, $evec );

is( scalar @received, 1,          'scalar @received receiving after select' );
is( $received[0],     "return\n", '$received[0] sendpartial 2' );
is( $closed,          0,          '$closed sendpartial 2' );

@received = ();

#### Close;

close( $S2 );
undef $S2;

# Notification;

( $rvec, $wvec, $evec ) = ('') x 3;
$buff->pre_select( \$rvec, \$wvec, \$evec, \$timeout );
select_no_timeout( $rvec, $wvec, $evec );
$buff->post_select( $rvec, $wvec, $evec );

is( scalar @received, 0, 'scalar @received receiving after select' );
is( $closed,          1, '$closed after close' );

# Idle;

( $rvec, $wvec, $evec ) = ('') x 3;
$buff->pre_select( \$rvec, \$wvec, \$evec, \$timeout );

is( $rvec, '', '$rvec after close' );
is( $wvec, '', '$wvec after close' );
is( $evec, '', '$evec after close' );
is( $timeout, undef, '$timeout after close' );
