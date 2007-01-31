#!/usr/bin/perl -w

use strict;

use Test::More tests => 3;
use Test::Exception;

use lib qw( t );
use Listener;

use IO::Socket::UNIX;

use IO::Async::Notifier;

my $listener = Listener->new();

dies_ok( sub { IO::Async::Notifier->new( sock => "Hello" ) },
         'Not a socket' );

( my $sock, undef ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

my $ioan = IO::Async::Notifier->new( sock => $sock, listener => $listener );
ok( defined $ioan, '$ioan defined' );
is( ref $ioan, "IO::Async::Notifier", 'ref $ioan is IO::Async::Notifier' );
