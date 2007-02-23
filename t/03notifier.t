#!/usr/bin/perl -w

use strict;

use Test::More tests => 20;
use Test::Exception;

use IO::Socket::UNIX;

use IO::Async::Notifier;

use IO::Handle;

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

is( $ioan->read_handle,  $S1, '->read_handle returns S1' );
is( $ioan->write_handle, $S1, '->write_handle returns S1' );

is( $ioan->read_fileno,  fileno($S1), '->read_fileno returns fileno(S1)' );
is( $ioan->write_fileno, fileno($S1), '->write_fileno returns fileno(S1)' );

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

undef $ioan;
$ioan = IO::Async::Notifier->new(
   read_handle  => IO::Handle->new_from_fd(fileno(STDIN),  'r'),
   write_handle => IO::Handle->new_from_fd(fileno(STDOUT), 'w'),
   want_writeready => 0,
   read_ready  => sub {},
   write_ready => sub {},
);

ok( defined $ioan, 'defined $ioan around STDIN/STDOUT' );
is( $ioan->read_fileno,  fileno(STDIN),  '->read_fileno returns fileno(STDIN)' );
is( $ioan->write_fileno, fileno(STDOUT), '->write_fileno returns fileno(STDOUT)' );

$ioan->want_writeready( 1 );
is( $ioan->want_writeready, 1, 'wantwriteready STDOUT 1' );

undef $ioan;
$ioan = IO::Async::Notifier->new(
   read_handle  => \*STDIN,
   want_writeready => 0,
   read_ready  => sub {},
);

ok( defined $ioan, 'defined $ioan around STDIN/undef' );
is( $ioan->read_fileno,  fileno(STDIN), '->read_fileno returns fileno(STDIN)' );
is( $ioan->write_fileno, undef,         '->write_fileno returns undef' );

dies_ok( sub { $ioan->want_writeready( 1 ); },
         'setting want_writeready with write_handle == undef dies' );
is( $ioan->want_writeready, 0, 'wantwriteready write_handle == undef 1' );
