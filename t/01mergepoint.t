#!/usr/bin/perl -w

use strict;

use Test::More tests => 11;
use Test::Exception;

use IO::Async::MergePoint;

dies_ok( sub { IO::Async::MergePoint->new( on_finished => sub { "DUMMY" } ) },
         'No needs' );

dies_ok( sub { IO::Async::MergePoint->new( needs => ['foo'] ) },
         'No on_finished' );

dies_ok( sub { IO::Async::MergePoint->new( needs => "hello", on_finished => sub { "DUMMY" } ) },
         'needs not ARRAY' );

dies_ok( sub { IO::Async::MergePoint->new( needs => ['foo'], on_finished => "goodbye" ) },
         'on_finished not CODE' );

my %items;

my $merge = IO::Async::MergePoint->new(
   needs => [qw( red )],

   on_finished => sub { %items = @_; },
);

ok( defined $merge, '$merge defined' );
isa_ok( $merge, "IO::Async::MergePoint", '$merge isa IO::Async::MergePoint' );

is_deeply( \%items, {}, '%items before done of one item' );

$merge->done( red => '#f00' );

is_deeply( \%items, { red => '#f00' }, '%items after done of one item' );

%items = ();

$merge = IO::Async::MergePoint->new(
   needs => [qw( blue green )],

   on_finished => sub { %items = @_; },
);

$merge->done( green => '#0f0' );

is_deeply( \%items, {}, '%items after one of 1/2 items' );

$merge->done( blue => '#00f' );

is_deeply( \%items, { blue => '#00f', green => '#0f0' }, '%items after done 2/2 items' );

$merge = IO::Async::MergePoint->new(
   needs => [qw( purple )],
   on_finished => sub { "DUMMY" },
);

dies_ok( sub { $merge->done( "orange" => 1 ) },
         'done something not needed fails' );
