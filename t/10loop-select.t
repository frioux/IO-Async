#!/usr/bin/perl -w

use strict;

use Test::More tests => 25;
use Test::Exception;

use IO::Socket::UNIX;
use IO::Async::Notifier;

use IO::Async::Loop::Select;

( my $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my $readready = 0;
my $writeready = 0;

my $notifier = IO::Async::Notifier->new( handle => $S1,
   on_read_ready  => sub { $readready = 1 },
   on_write_ready => sub { $writeready = 1 },
);

my $loop = IO::Async::Loop::Select->new();

ok( defined $loop, '$loop defined' );
is( ref $loop, "IO::Async::Loop::Select", 'ref $loop is IO::Async::Loop::Select' );

my $testvec = '';
vec( $testvec, $S1->fileno, 1 ) = 1;

my ( $rvec, $wvec, $evec ) = ('') x 3;
my $timeout;

# Idle;
$loop->pre_select( \$rvec, \$wvec, \$evec, \$timeout );

is( $rvec, '', '$rvec idling pre_select' );
is( $wvec, '', '$wvec idling pre_select' );
is( $evec, '', '$evec idling pre_select' );

is( $timeout, undef, '$timeout idling pre_select' );

$loop->add( $notifier );

is( $notifier->__memberof_loop, $loop, '$notifier->__memberof_loop == $loop' );

dies_ok( sub { $loop->add( $notifier ) }, 'adding again produces error' );

# Read-ready
$loop->pre_select( \$rvec, \$wvec, \$evec, \$timeout );

is( $rvec, $testvec, '$rvec readready pre_select' );
is( $wvec, '',       '$wvec readready pre_select' );
is( $evec, '',       '$evec readready pre_select' );

is( $timeout, undef, '$timeout readready pre_select' );

# Write-ready
$notifier->want_writeready( 1 );
$loop->pre_select( \$rvec, \$wvec, \$evec, \$timeout );

is( $rvec, $testvec, '$rvec writeready pre_select' );
is( $wvec, $testvec, '$wvec writeready pre_select' );
is( $evec, '',       '$evec writeready pre_select' );

is( $timeout, undef, '$timeout writeready pre_select' );

### Post-select

# Read-ready
$rvec = $testvec;
$wvec = '';
$evec = '';

$loop->post_select( $rvec, $wvec, $evec );

is( $readready,  1, '$readready readready post_select' );
is( $writeready, 0, '$writeready readready post_select' );

$readready = 0;

# Write-ready
$rvec = '';
$wvec = $testvec;
$evec = '';

$loop->post_select( $rvec, $wvec, $evec );

is( $readready,  0, '$readready writeready post_select' );
is( $writeready, 1, '$writeready writeready post_select' );

$readready = 0;

# Removal

$loop->remove( $notifier );

is( $notifier->__memberof_loop, undef, '$notifier->__memberof_loop is undef' );

$rvec = '';
$wvec = '';
$evec = '';
$timeout = undef;

$loop->pre_select( \$rvec, \$wvec, \$evec, \$timeout );

is( $rvec, '', '$rvec idling pre_select' );
is( $wvec, '', '$wvec idling pre_select' );
is( $evec, '', '$evec idling pre_select' );

is( $timeout, undef, '$timeout idling pre_select' );

