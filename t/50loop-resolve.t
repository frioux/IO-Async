#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 6;
use Test::Exception;

use Socket qw( AF_INET SOCK_STREAM );
use Socket::GetAddrInfo qw( :Socket6api getaddrinfo );

use IO::Async::Loop::IO_Poll;

my $loop = IO::Async::Loop::IO_Poll->new();

testing_loop( $loop );

my $result;

my @pwuid = getpwuid( $< );

$loop->resolve(
   type => 'getpwuid',
   data => [ $< ], 
   on_resolved => sub { $result = [ @_ ] },
   on_error => sub { die "Test died early" },
);

wait_for { $result };

is_deeply( $result, \@pwuid, 'getpwuid' );

SKIP: {
   my $user_name = $result->[0];
   skip "getpwnam - No user name", 1 unless defined $user_name;

   my @pwnam = getpwnam( $user_name );

   undef $result;

   $loop->resolve(
      type => 'getpwnam',
      data => [ $user_name ],
      on_resolved => sub { $result = [ @_ ] },
      on_error => sub { die "Test died early" },
   );

   wait_for { $result };

   is_deeply( $result, \@pwnam, 'getpwnam' );
}

my @proto = getprotobyname( "tcp" );

undef $result;

$loop->resolve(
   type => 'getprotobyname',
   data => [ "tcp" ],
   on_resolved => sub { $result = [ @_ ] },
   on_error => sub { die "Test died early" },
);

wait_for { $result };

is_deeply( $result, \@proto, 'getprotobyname' );

SKIP: {
   my $proto_number = $result->[2];
   skip "getprotobynumber - No protocol number", 1 unless defined $proto_number;

   my @proto = getprotobynumber( $proto_number );

   undef $result;

   $loop->resolve(
      type => 'getprotobynumber',
      data => [ $proto_number ],
      on_resolved => sub { $result = [ @_ ] },
      on_error => sub { die "Test died early" },
   );

   wait_for { $result };

   is_deeply( $result, \@proto, 'getprotobynumber' );
}

# getaddrinfo is a little more difficult, as it will mangle the result

# Also, some systems seem to mangle the order of results between PF_INET and
# PF_INET6 depending on who asks. We'll hint AF_INET + SOCK_STREAM to minimise
# the risk of a spurious test failure because of ordering issues

my @gai = getaddrinfo( "localhost", "www", AF_INET, SOCK_STREAM );

undef $result;

$loop->resolve(
   type => 'getaddrinfo',
   data => [ "localhost", "www", AF_INET, SOCK_STREAM ],
   on_resolved => sub { $result = [ 'resolved', @_ ] },
   on_error    => sub { $result = [ 'error',    @_ ] },
);

wait_for { $result };

if( @gai == 1 ) {
   is( $result->[0], "error", 'getaddrinfo - error' );
   is_deeply( $result->[1], "$gai[0]\n", 'getaddrinfo - error message' );
}
else {
   is( $result->[0], "resolved", 'getaddrinfo - resolved' );
   my @addrs = @{$result}[1..$#$result];

   my @expect = map { [ splice @gai, 0, 5 ] } ( 0 .. $#gai/5 );

   # There's a chance that system resolvers have randomised the order in these
   # results, in order to roundrobin properly. We should sort them so we get
   # consistent results

   @addrs  = sort { $a->[0] <=> $b->[0] or $a->[1] <=> $b->[1] or $a->[2] <=> $b->[2] or $a->[3] cmp $b->[3] } @addrs;
   @expect = sort { $a->[0] <=> $b->[0] or $a->[1] <=> $b->[1] or $a->[2] <=> $b->[2] or $a->[3] cmp $b->[3] } @expect;

   is_deeply( \@addrs, \@expect, 'getaddrinfo - resolved addresses' );
}
