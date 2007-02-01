#!/usr/bin/perl -w

use strict;

use Test::More tests => 6;
use Test::Exception;

use lib qw( t );
use Listener;
use Receiver;

use IO::Socket::UNIX;

use IO::Async::Notifier;
use IO::Async::Buffer;

my $listener = Listener->new();
my $receiver = Receiver->new();

dies_ok( sub { IO::Async::Notifier->new( sock => "Hello" ) },
         'Not a socket' );

( my $sock, undef ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

my $ioan = IO::Async::Notifier->new( sock => $sock, listener => $listener );
ok( defined $ioan, '$ioan defined' );
is( ref $ioan, "IO::Async::Notifier", 'ref $ioan is IO::Async::Notifier' );

dies_ok( sub { IO::Async::Buffer->new( sock => $sock, receiver => "Hello" ) },
         'Not a receiver' );

my $ioab = IO::Async::Buffer->new( sock => $sock, receiver => $receiver );
ok( defined $ioab, '$ioab defined' );
is( ref $ioab, "IO::Async::Buffer", 'ref $ioab is IO::Async::Buffer' );
