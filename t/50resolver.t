#!/usr/bin/perl -w

use strict;

use lib 't';
use TestAsync;

use Test::More tests => 8;
use Test::Exception;

use Socket::GetAddrInfo qw( getaddrinfo );

use IO::Async::Resolver;

use IO::Async::Loop::IO_Poll;

my $loop = IO::Async::Loop::IO_Poll->new();
$loop->enable_childmanager;

testing_loop( $loop );

my $resolver = IO::Async::Resolver->new( loop => $loop );

ok( defined $resolver, '$resolver defined' );
is( ref $resolver, "IO::Async::Resolver", 'ref $resolver is IO::Async::Resolver' );

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

# getaddrinfo is a little more difficult, as it will mangle the result

my @gai = getaddrinfo( "localhost", "www" );

undef $result;

$resolver->resolve(
   type => 'getaddrinfo',
   data => [ "localhost", "www" ],
   on_resolved => sub { $result = [ 'resolved', @_ ] },
   on_error    => sub { $result = [ 'error',    @_ ] },
);

wait_for { $result };

if( @gai == 1 ) {
   is_deeply( $result, [ error => "$gai[0]\n" ], 'getaddrinfo - error' );
}
else {
   my @expect = map { [ splice @gai, 0, 5 ] } ( 0 .. $#gai/5 );
   is_deeply( $result, [ resolved => @expect ], 'getaddrinfo - result' );
}

# Loop integration

undef $result;

$loop->resolve(
   type => 'getpwuid',
   data => [ $< ], 
   on_resolved => sub { $result = [ @_ ] },
   on_error => sub { die "Test died early" },
);

wait_for { $result };

is_deeply( $result, \@pwuid, 'getpwuid using Loop->resolve()' );
