#!/usr/bin/perl -w

use strict;

use Test::More tests => 9;
use Test::Exception;

use IO::Socket::UNIX;

use IO::Async::Notifier;

( my $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my $readready = 0;
my $writeready = 0;

my $ioan = IO::Async::Notifier->new( handle => $S1, want_writeready => 0,
   read_ready  => sub { $readready = 1 },
   write_ready => sub { $writeready = 1 },
);

is( $ioan->handle, $S1, '->handle returns S1' );

is( $ioan->fileno, fileno($S1), '->fileno returns fileno(S1)' );

is( $ioan->want_writeready, 0, 'wantwriteready 0' );

is( $ioan->__memberof_set, undef, '__memberof_set undef' );

$ioan->want_writeready( 1 );
is( $ioan->want_writeready, 1, 'wantwriteready 1' );

is( $readready, 0, '$readready before call' );
$ioan->read_ready;
is( $readready, 1, '$readready after call' );

is( $writeready, 0, '$writeready before call' );
$ioan->write_ready;
is( $writeready, 1, '$writeready after call' );
