#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 10;
use Test::Exception;

use Socket qw( AF_INET SOCK_STREAM );
use Socket::GetAddrInfo qw( :newapi getaddrinfo );

use IO::Async::Loop::Poll;

my $loop = IO::Async::Loop::Poll->new();

testing_loop( $loop );

my $resolver = $loop->resolver;
isa_ok( $resolver, "IO::Async::Resolver", '$loop->resolver' );

my $result;

my @pwuid = getpwuid( $< );

$resolver->resolve(
   type => 'getpwuid',
   data => [ $< ], 
   on_resolved => sub { $result = [ @_ ] },
   on_error => sub { die "Test died early" },
);

wait_for { $result };

is_deeply( $result, \@pwuid, 'getpwuid' );

undef $result;

$loop->resolve(
   type => 'getpwuid',
   data => [ $< ],
   on_resolved => sub { $result = [ @_ ] },
   on_error => sub { die "Test died early" },
);

wait_for { $result };

is_deeply( $result, \@pwuid, 'getpwuid via $loop->resolve' );

SKIP: {
   my $user_name = $result->[0];
   skip "getpwnam - No user name", 1 unless defined $user_name;

   my @pwnam = getpwnam( $user_name );

   undef $result;

   $resolver->resolve(
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

$resolver->resolve(
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

   $resolver->resolve(
      type => 'getprotobynumber',
      data => [ $proto_number ],
      on_resolved => sub { $result = [ @_ ] },
      on_error => sub { die "Test died early" },
   );

   wait_for { $result };

   is_deeply( $result, \@proto, 'getprotobynumber' );
}

# Some systems seem to mangle the order of results between PF_INET and
# PF_INET6 depending on who asks. We'll hint AF_INET + SOCK_STREAM to minimise
# the risk of a spurious test failure because of ordering issues

my ( $err, @addrs ) = getaddrinfo( "localhost", "www", { family => AF_INET, socktype => SOCK_STREAM } );

undef $result;

$resolver->resolve(
   type => 'getaddrinfo_array',
   data => [ "localhost", "www", AF_INET, SOCK_STREAM ],
   on_resolved => sub { $result = [ 'resolved', @_ ] },
   on_error    => sub { $result = [ 'error',    @_ ] },
);

wait_for { $result };

if( $err ) {
   is( $result->[0], "error", 'getaddrinfo_array - error' );
   is_deeply( $result->[1], "$err\n", 'getaddrinfo_array - error message' );
}
else {
   is( $result->[0], "resolved", 'getaddrinfo_array - resolved' );

   my @got = @{$result}[1..$#$result];
   my @expect = map { [ @{$_}{qw( family socktype protocol addr canonname )} ] } @addrs;

   is_deeply( \@got, \@expect, 'getaddrinfo_array - resolved addresses' );
}
undef $result;

$resolver->resolve(
   type => 'getaddrinfo_hash',
   data => [ host => "localhost", service => "www", family => AF_INET, socktype => SOCK_STREAM ],
   on_resolved => sub { $result = [ 'resolved', @_ ] },
   on_error    => sub { $result = [ 'error',    @_ ] },
);

wait_for { $result };

if( $err ) {
   is( $result->[0], "error", 'getaddrinfo_hash - error' );
   is_deeply( $result->[1], "$err\n", 'getaddrinfo_hash - error message' );
}
else {
   is( $result->[0], "resolved", 'getaddrinfo_hash - resolved' );

   my @got = @{$result}[1..$#$result];
   my @expect = @addrs;

   is_deeply( \@got, \@expect, 'getaddrinfo_hash - resolved addresses' );
}
