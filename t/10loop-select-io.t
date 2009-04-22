#!/usr/bin/perl -w

use strict;

use Test::More tests => 25;
use Test::Exception;

use IO::Async::Loop::Select;

my $loop = IO::Async::Loop::Select->new();

ok( defined $loop, '$loop defined' );
isa_ok( $loop, "IO::Async::Loop::Select", '$loop isa IO::Async::Loop::Select' );

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

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

my $readready = 0;

$loop->watch_io(
   handle => $S1,
   on_read_ready => sub { $readready = 1 },
);

# Read-ready

$loop->pre_select( \$rvec, \$wvec, \$evec, \$timeout );

is( $rvec, $testvec, '$rvec readready pre_select' );
is( $wvec, '',       '$wvec readready pre_select' );
is( $evec, '',       '$evec readready pre_select' );

is( $timeout, undef, '$timeout readready pre_select' );

# Write-ready

my $writeready = 0;

$loop->watch_io(
   handle => $S1,
   on_write_ready => sub { $writeready = 1 },
);

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

# loop_once

$writeready = 0;

my $ready;
$ready = $loop->loop_once( 0.1 );

is( $ready, 1, '$ready after loop_once' );
is( $writeready, 1, '$writeready after loop_once' );

# loop_forever

$loop->watch_io(
   handle => \*STDOUT,
   on_write_ready => sub { $loop->loop_stop() },
);

$writeready = 0;

$SIG{ALRM} = sub { die "Test timed out"; };
alarm( 1 );

$loop->loop_forever();

alarm( 0 );

is( $writeready, 1, '$writeready after loop_forever' );

$loop->unwatch_io(
   handle => \*STDOUT,
   on_write_ready => 1,
);

# Removal

$loop->unwatch_io(
   handle => $S1,
   on_read_ready => 1,
   on_write_ready => 1,
);

$rvec = '';
$wvec = '';
$evec = '';
$timeout = undef;

$loop->pre_select( \$rvec, \$wvec, \$evec, \$timeout );

is( $rvec, '', '$rvec idling pre_select' );
is( $wvec, '', '$wvec idling pre_select' );
is( $evec, '', '$evec idling pre_select' );

is( $timeout, undef, '$timeout idling pre_select' );
