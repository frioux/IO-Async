#!/usr/bin/perl -w

use strict;

use Test::More tests => 23;
use Test::Exception;

use IO::Socket::UNIX;
use IO::Async::Notifier;

use IO::Async::Set::Select;

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

my $set = IO::Async::Set::Select->new();

my $testvec = '';
vec( $testvec, $S1->fileno, 1 ) = 1;

my ( $rvec, $wvec, $evec ) = ('') x 3;
my $timeout;

# Idle;
$set->pre_select( \$rvec, \$wvec, \$evec, \$timeout );

is( $rvec, '', '$rvec idling pre_select' );
is( $wvec, '', '$wvec idling pre_select' );
is( $evec, '', '$evec idling pre_select' );

is( $timeout, undef, '$timeout idling pre_select' );

$set->add( $notifier );

is( $notifier->__memberof_set, $set, '$notifier->__memberof_set == $set' );

dies_ok( sub { $set->add( $notifier ) }, 'adding again produces error' );

# Read-ready
$set->pre_select( \$rvec, \$wvec, \$evec, \$timeout );

is( $rvec, $testvec, '$rvec readready pre_select' );
is( $wvec, '',       '$wvec readready pre_select' );
is( $evec, '',       '$evec readready pre_select' );

is( $timeout, undef, '$timeout readready pre_select' );

# Write-ready
$notifier->want_writeready( 1 );
$set->pre_select( \$rvec, \$wvec, \$evec, \$timeout );

is( $rvec, $testvec, '$rvec writeready pre_select' );
is( $wvec, $testvec, '$wvec writeready pre_select' );
is( $evec, '',       '$evec writeready pre_select' );

is( $timeout, undef, '$timeout writeready pre_select' );

### Post-select

# Read-ready
$rvec = $testvec;
$wvec = '';
$evec = '';

$set->post_select( $rvec, $wvec, $evec );

is( $readready,  1, '$readready readready post_select' );
is( $writeready, 0, '$writeready readready post_select' );

$readready = 0;

# Write-ready
$rvec = '';
$wvec = $testvec;
$evec = '';

$set->post_select( $rvec, $wvec, $evec );

is( $readready,  0, '$readready writeready post_select' );
is( $writeready, 1, '$writeready writeready post_select' );

$readready = 0;

# Removal

$set->remove( $notifier );

is( $notifier->__memberof_set, undef, '$notifier->__memberof_set is undef' );

$rvec = '';
$wvec = '';
$evec = '';
$timeout = undef;

$set->pre_select( \$rvec, \$wvec, \$evec, \$timeout );

is( $rvec, '', '$rvec idling pre_select' );
is( $wvec, '', '$wvec idling pre_select' );
is( $evec, '', '$evec idling pre_select' );

is( $timeout, undef, '$timeout idling pre_select' );

