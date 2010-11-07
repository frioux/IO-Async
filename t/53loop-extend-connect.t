#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 5;
use Test::Identity;

use IO::Async::Loop::Poll;

my $loop = IO::Async::Loop::Poll->new();

testing_loop( $loop );

my %connectargs;
sub IO::Async::Loop::FOO_connect
{
   my $self = shift;
   %connectargs = @_;

   identical( $self, $loop, 'FOO_connect invocant is $loop' );
}

my $sock;

$loop->connect(
   extensions => [qw( FOO )],
   some_param => "here",
   on_connected => sub { $sock = shift },
);

is( ref delete $connectargs{on_connected}, "CODE", 'FOO_connect received on_connected continuation' );
is_deeply( \%connectargs,
           { some_param => "here" },
           'FOO_connect received some_param and no others' );

$loop->connect(
   extensions => [qw( FOO BAR )],
   param1 => "one",
   param2 => "two",
   on_connected => sub { $sock = shift },
);

delete $connectargs{on_connected};
is_deeply( \%connectargs,
           { extensions => [qw( BAR )],
             param1 => "one",
             param2 => "two" },
           'FOO_connect still receives other extensions' );
