#!/usr/bin/perl -w

use strict;

use Test::More tests => 12;
use Test::Exception;

use IO::Async::DetachedCode;

use IO::Async::Set::IO_Poll;

my $set = IO::Async::Set::IO_Poll->new();
$set->enable_childmanager;

my $code = IO::Async::DetachedCode->new(
   set  => $set,
   code => sub { 1 },
);

ok( defined $code, '$code defined' );
is( ref $code, "IO::Async::DetachedCode", 'ref $code is IO::Async::DetachedCode' );

sub test_marshall_args
{
   my ( $name ) = @_;

   my $data = $code->_marshall_args( 1, [] );
   my $args = $code->_unmarshall_args( 1, $data );

   is_deeply( $args, [], "args for args empty list using $name" );

   $data = $code->_marshall_args( 10, [ "hello" ] );
   $args = $code->_unmarshall_args( 10, $data );

   is_deeply( $args, [ "hello" ], "args for args list single string using $name" );

   $data = $code->_marshall_args( 100, [ 10, 20, 30 ] );
   $args = $code->_unmarshall_args( 100, $data );

   is_deeply( $args, [ 10, 20, 30 ], "args for args list of numbers using $name" );

   $data = $code->_marshall_args( 1000, [ undef ] );
   $args = $code->_unmarshall_args( 1000, $data );

   is_deeply( $args, [ undef ], "args for args list with undef using $name" );
}

test_marshall_args( "flat" );

dies_ok( sub { $code->_marshall_args( 2, [ \'a' ] ); },
         "marshalling SCALAR ref dies using flat" );

dies_ok( sub { $code->_marshall_args( 2, [ ['a'] ] ); },
         "marshalling ARRAY ref dies using flat" );

dies_ok( sub { $code->_marshall_args( 2, [ { a => 'A' } ] ); },
         "marshalling HASH ref dies using flat" );

my $record = $code->_marshall_record( 'c', 1, "call data here" );
my ( $type, $id, $data ) = $code->_unmarshall_record( $record );

is( $type, 'c',              "type for record marshall test" );
is( $id,   1,                "id for record marshall test" );
is( $data, "call data here", "data for record marshall test" );
