#!/usr/bin/perl -w

use strict;

use Test::More tests => 10;
use Test::Exception;

use lib qw( t );
use Listener;
use Receiver;

use IO::Socket::UNIX;

use IO::Async::Notifier;
use IO::Async::Buffer;

use IO::Async::Set::Select;
use IO::Async::Set::IO_Poll;

my $listener = Listener->new();
my $receiver = Receiver->new();

dies_ok( sub { IO::Async::Notifier->new( handle => "Hello" ) },
         'Not a socket' );

( my $sock, undef ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

my $ioan = IO::Async::Notifier->new( handle => $sock, listener => $listener );
ok( defined $ioan, '$ioan defined' );
is( ref $ioan, "IO::Async::Notifier", 'ref $ioan is IO::Async::Notifier' );

dies_ok( sub { IO::Async::Buffer->new( handle => $sock, receiver => "Hello" ) },
         'Not a receiver' );

my $ioab = IO::Async::Buffer->new( handle => $sock, receiver => $receiver );
ok( defined $ioab, '$ioab defined' );
is( ref $ioab, "IO::Async::Buffer", 'ref $ioab is IO::Async::Buffer' );

my $ioass = IO::Async::Set::Select->new();
ok( defined $ioass, '$ioass defined' );
is( ref $ioass, "IO::Async::Set::Select", 'ref $ioass is IO::Async::Set::Select' );

my $ioasip = IO::Async::Set::IO_Poll->new();
ok( defined $ioasip, '$ioasip defined' );
is( ref $ioasip, "IO::Async::Set::IO_Poll", 'ref $ioasip is IO::Async::Set::IO_Poll' );
