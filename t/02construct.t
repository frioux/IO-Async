#!/usr/bin/perl -w

use strict;

use Test::More tests => 18;
use Test::Exception;

use IO::Socket::UNIX;

use IO::Async::Notifier;
use IO::Async::Buffer;
use IO::Async::SignalProxy;

use IO::Async::Set::Select;
use IO::Async::Set::IO_Poll;
use IO::Async::Set::GMainLoop;

use IO::Async::ChildManager;

dies_ok( sub { IO::Async::Notifier->new( handle => "Hello" ) },
         'Not a socket' );

( my $sock, undef ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

dies_ok( sub { IO::Async::Notifier->new( handle => $sock ) },
         'No on_read_ready' );

my $ioan = IO::Async::Notifier->new( handle => $sock, on_read_ready => sub { } );
ok( defined $ioan, '$ioan defined' );
is( ref $ioan, "IO::Async::Notifier", 'ref $ioan is IO::Async::Notifier' );

dies_ok( sub { IO::Async::Buffer->new( handle => $sock ) },
         'No on_incoming_data' );

my $ioab = IO::Async::Buffer->new( handle => $sock, on_incoming_data => sub { } );
ok( defined $ioab, '$ioab defined' );
is( ref $ioab, "IO::Async::Buffer", 'ref $ioab is IO::Async::Buffer' );

my $ioasp = IO::Async::SignalProxy->new();
ok( defined $ioasp, '$ioasp defined' );
is( ref $ioasp, "IO::Async::SignalProxy", 'ref $ioasp is IO::Async::SignalProxy' );

my $ioass = IO::Async::Set::Select->new();
ok( defined $ioass, '$ioass defined' );
is( ref $ioass, "IO::Async::Set::Select", 'ref $ioass is IO::Async::Set::Select' );

my $ioasip = IO::Async::Set::IO_Poll->new();
ok( defined $ioasip, '$ioasip defined' );
is( ref $ioasip, "IO::Async::Set::IO_Poll", 'ref $ioasip is IO::Async::Set::IO_Poll' );

dies_ok( sub { IO::Async::Set::GMainLoop->new(); },
         'No Glib loaded' );

SKIP: {
   skip "No Glib available", 2 unless defined eval { require Glib };

   my $ioasgml = IO::Async::Set::GMainLoop->new();
   ok( defined $ioasgml, '$ioasgml defined' );
   is( ref $ioasgml, "IO::Async::Set::GMainLoop", 'ref $ioasgml is IO::Async::Set::GMainLoop' );
}

my $ioacm = IO::Async::ChildManager->new();
ok( defined $ioacm, '$ioacm defined' );
is( ref $ioacm, "IO::Async::ChildManager", 'ref $ioacm is IO::Async::ChildManager' );
