#!/usr/bin/perl -w

use strict;

use Test::More tests => 29;
use Test::Exception;

use IO::Async::DetachedCode;

use IO::Async::Set::IO_Poll;

my $set = IO::Async::Set::IO_Poll->new();
$set->enable_childmanager;

my $code = IO::Async::DetachedCode->new(
   set  => $set,
   code => sub { return $_[0] + $_[1] },
);

ok( defined $code, '$code defined' );
is( ref $code, "IO::Async::DetachedCode", 'ref $code is IO::Async::DetachedCode' );

dies_ok( sub { $code->call( args => [], on_result => "hello" ) },
         'call with on_result not CODE ref fails' );

dies_ok( sub { $code->call( args => [], on_return => sub {} ) },
         'call missing on_error ref fails' );

dies_ok( sub { $code->call( args => [], on_error => sub {} ) },
         'call missing on_return ref fails' );

dies_ok( sub { $code->call( args => [], on_return => "hello", on_error => sub {} ) },
         'call with on_return not a CODE ref fails' );

dies_ok( sub { $code->call( args => [], on_return => sub {}, on_error => "hello" ) },
         'call with on_error not a CODE ref fails' );

my $result;

sub wait_for(&)
{
   my ( $cond ) = @_;

   my $ready = 0;
   undef $result;

   my ( undef, $callerfile, $callerline ) = caller();

   while( !$cond->() ) {
      $_ = $set->loop_once( 10 ); # Give code a generous 10 seconds to do something
      die "Nothing was ready after 10 second wait; called at $callerfile line $callerline\n" if $_ == 0;
      $ready += $_;
   }

   $ready;
}

$code->call(
   args => [ 10, 20 ],
   on_return => sub { $result = shift },
   on_error  => sub { die "Test failed early - @_" },
);

is( $result, undef, '$result before call returns' );

my $ready;
$ready = wait_for { defined $result };

cmp_ok( $ready, '>=', 2, '$ready after call returns' );
is( $result, 30, '$result after call returns' );

my @result;

$code->call(
   args => [ 1, 2 ],
   on_return => sub { push @result, shift },
   on_error  => sub { die "Test failed early - @_" },
);
$code->call(
   args => [ 3, 4 ],
   on_return => sub { push @result, shift },
   on_error  => sub { die "Test failed early - @_" },
);

$ready = wait_for { @result == 2 };

cmp_ok( $ready, '>=', 2, '$ready after both calls return' );
is_deeply( \@result, [ 3, 7 ], '@result after both calls return' );

$code->shutdown;
undef $code;

$code = IO::Async::DetachedCode->new(
   set  => $set,
   code => sub { return $_[0] + $_[1] },
   stream => "socket",
);

$code->call(
   args => [ 5, 6 ],
   on_return => sub { $result = shift },
   on_error  => sub { die "Test failed early - @_" },
);

undef $result;
$ready = wait_for { defined $result };

cmp_ok( $ready, '>=', 2, '$ready after call to code over socket' );
is( $result, 11, '$result of code over socket' );

$code->shutdown;
undef $code;

$code = IO::Async::DetachedCode->new(
   set  => $set,
   code => sub { return $_[0] + $_[1] },
   stream => "pipe",
);

$code->call(
   args => [ 5, 6 ],
   on_return => sub { $result = shift },
   on_error  => sub { die "Test failed early - @_" },
);

undef $result;
$ready = wait_for { defined $result };

cmp_ok( $ready, '>=', 2, '$ready after call to code over pipe' );
is( $result, 11, '$result of code over pipe' );

$code->shutdown;
undef $code;

dies_ok( sub { IO::Async::DetachedCode->new(
                  set  => $set,
                  code => sub { return $_[0] },
                  stream => "oranges",
               ); },
         'Unrecognised stream type fails' );

$code = IO::Async::DetachedCode->new(
   set  => $set,
   code => sub { return $_[0] + $_[1] },
   marshaller => "flat",
);

$code->call(
   args => [ 7, 8 ],
   on_return => sub { $result = shift },
   on_error  => sub { die "Test failed early - @_" },
);

undef $result;
$ready = wait_for { defined $result };

cmp_ok( $ready, '>=', 2, '$ready after call to code over flat marshaller' );
is( $result, 15, '$result of code over flat' );

dies_ok( sub { $code->call( 
                  args => [ \'a' ], 
                  on_return => sub {},
                  on_error  => sub {},
               );
            },
         'call with reference arguments using flat marshaller dies' );

$code->shutdown;
undef $code;

dies_ok( sub { IO::Async::DetachedCode->new(
                  set  => $set,
                  code => sub { return $_[0] },
                  marshaller => "grapefruit",
               ); },
         'Unrecognised marshaller type fails' );

$code = IO::Async::DetachedCode->new(
   set  => $set,
   code => sub { return ref( $_[0] ), \$_[1] },
   marshaller => "storable",
);

$code->call(
   args => [ \'a', 'b' ],
   on_return => sub { @result = @_ },
   on_error  => sub { die "Test failed early - @_" },
);

undef @result;
$ready = wait_for { scalar @result };

cmp_ok( $ready, '>=', 2, '$ready after call to code over storable marshaller' );
is_deeply( \@result, [ 'SCALAR', \'b' ], '@result after call to code over storable marshaller' );

$code->shutdown;
undef $code;

my $err;

$code = IO::Async::DetachedCode->new(
   set => $set,
   code => sub { die shift },
);

$code->call(
   args => [ "exception name" ],
   on_return => sub { },
   on_error  => sub { $err = shift },
);

$ready = wait_for { defined $err };

cmp_ok( $ready, '>=', 2, '$ready after exception' );
like( $err, qr/^exception name at $0 line \d+\.$/, '$err after exception' );

$code->shutdown;
undef $code;

$code = IO::Async::DetachedCode->new(
   set => $set,
   code => sub { exit shift },
);

$code->call(
   args => [ 16 ],
   on_return => sub { },
   on_error  => sub { $err = [ @_ ] },
);

undef $err;
$ready = wait_for { defined $err };

cmp_ok( $ready, '>=', 2, '$ready after child death' );
# Not sure what reason we might get - need to check both
ok( $err->[0] eq "closed" || $err->[0] eq "exit", '$err->[0] after child death' );

$code->shutdown;
undef $code;

$code = $set->detach_code(
   code => sub { return join( "+", @_ ) },
);

$code->call(
   args => [ qw( a b c ) ],
   on_return => sub { $result = shift },
   on_error  => sub { die "Test failed early - @_" },
);

undef $result;
$ready = wait_for { defined $result };

cmp_ok( $ready, '>=', 2, '$ready after call to Set-constructed code' );
is( $result, "a+b+c", '$result of Set-constructed code' );
