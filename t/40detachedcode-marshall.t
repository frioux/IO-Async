#!/usr/bin/perl -w

use strict;

use Test::More tests => 22;
use Test::Exception;

use IO::Async::DetachedCode;

use IO::Async::DetachedCode::FlatMarshaller;
use IO::Async::DetachedCode::StorableMarshaller;

use IO::Async::Set::IO_Poll;

sub test_marshall_args
{
   my ( $marshaller, $name ) = @_;

   my $data = $marshaller->marshall_args( 1, [] );
   my $args = $marshaller->unmarshall_args( 1, $data );

   is_deeply( $args, [], "args for args empty list using $name" );

   $data = $marshaller->marshall_args( 10, [ "hello" ] );
   $args = $marshaller->unmarshall_args( 10, $data );

   is_deeply( $args, [ "hello" ], "args for args list single string using $name" );

   $data = $marshaller->marshall_args( 100, [ 10, 20, 30 ] );
   $args = $marshaller->unmarshall_args( 100, $data );

   is_deeply( $args, [ 10, 20, 30 ], "args for args list of numbers using $name" );

   $data = $marshaller->marshall_args( 1000, [ undef ] );
   $args = $marshaller->unmarshall_args( 1000, $data );

   is_deeply( $args, [ undef ], "args for args list with undef using $name" );
}

sub test_marshall_args_ref
{
   my ( $marshaller, $name ) = @_;

   my $data = $marshaller->marshall_args( 3, [ \'a' ] );
   my $args = $marshaller->unmarshall_args( 3, $data );

   is_deeply( $args, [ \'a' ], "args for SCALAR ref using $name" );

   $data = $marshaller->marshall_args( 30, [ [ 'a' ] ] );
   $args = $marshaller->unmarshall_args( 30, $data );

   is_deeply( $args, [ [ 'a' ] ], "args for ARRAY ref using $name" );

   $data = $marshaller->marshall_args( 300, [ { a => 'A' } ] );
   $args = $marshaller->unmarshall_args( 300, $data );

   is_deeply( $args, [ { a => 'A' } ], "args for HASH ref using $name" );

   $data = $marshaller->marshall_args( 3000, [ [ [ 'a' ] ] ] );
   $args = $marshaller->unmarshall_args( 3000, $data );

   is_deeply( $args, [ [ [ 'a' ] ] ], "args for deep ARRAY ref using $name" );
}

my $marshaller = IO::Async::DetachedCode::FlatMarshaller->new();

ok( defined $marshaller, '$marshaller defined' );
is( ref $marshaller, "IO::Async::DetachedCode::FlatMarshaller", 'ref $marshaller is IO::Async::DetachedCode::FlatMarshaller' );

test_marshall_args( $marshaller, "flat" );

dies_ok( sub { $marshaller->marshall_args( 2, [ \'a' ] ); },
         "marshalling SCALAR ref dies using flat" );

dies_ok( sub { $marshaller->marshall_args( 2, [ ['a'] ] ); },
         "marshalling ARRAY ref dies using flat" );

dies_ok( sub { $marshaller->marshall_args( 2, [ { a => 'A' } ] ); },
         "marshalling HASH ref dies using flat" );

$marshaller = IO::Async::DetachedCode::StorableMarshaller->new();

ok( defined $marshaller, '$marshaller defined' );
is( ref $marshaller, "IO::Async::DetachedCode::StorableMarshaller", 'ref $marshaller is IO::Async::DetachedCode::StorableMarshaller' );

test_marshall_args( $marshaller, "storable" );
test_marshall_args_ref( $marshaller, "storable" );

my $set = IO::Async::Set::IO_Poll->new();
$set->enable_childmanager;

my $record = IO::Async::DetachedCode::_marshall_record( 'c', 1, "call data here" );
my ( $type, $id, $data ) = IO::Async::DetachedCode::_unmarshall_record( $record );

is( $type, 'c',              "type for record marshall test" );
is( $id,   1,                "id for record marshall test" );
is( $data, "call data here", "data for record marshall test" );
