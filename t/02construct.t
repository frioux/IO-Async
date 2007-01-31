#!/usr/bin/perl -w

use strict;

use Test::More tests => 3;
use Test::Exception;

use lib qw( t );
use Listener;

use IO::Socket::UNIX;

use IO::SelectNotifier;

my $listener = Listener->new();

dies_ok( sub { IO::SelectNotifier->new( sock => "Hello" ) },
         'Not a socket' );

( my $sock, undef ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

my $iosn = IO::SelectNotifier->new( sock => $sock, listener => $listener );
ok( defined $iosn, '$iosn defined' );
is( ref $iosn, "IO::SelectNotifier", 'ref $iosn is IO::SelectNotifier' );
