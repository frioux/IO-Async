#!/usr/bin/perl -w

use strict;

use Test::More tests => 41;
use Test::Exception;

use File::Temp qw( tempdir );
use Time::HiRes qw( sleep );

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

is( scalar $code->workers, 1, '$code->workers is 1' );
my @workers = $code->workers;
is( scalar @workers, 1, '@workers has 1 value' );
ok( kill( 0, $workers[0] ), '$workers[0] is a PID' );

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

is( scalar $code->workers, 1, '$code->workers is still 1 after call' );

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

is( scalar $code->workers, 1, '$code->workers is still 1 after 2 calls' );

$ready = wait_for { @result == 2 };

cmp_ok( $ready, '>=', 2, '$ready after both calls return' );
is_deeply( \@result, [ 3, 7 ], '@result after both calls return' );

is( scalar $code->workers, 1, '$code->workers is still 1 after 2 calls return' );

$code = IO::Async::DetachedCode->new(
   set  => $set,
   code => sub { return $_[0] + $_[1] },
   stream => "socket",
);

is( scalar $code->workers, 1, '$code->workers is 1 for socket stream' );

$code->call(
   args => [ 5, 6 ],
   on_return => sub { $result = shift },
   on_error  => sub { die "Test failed early - @_" },
);

undef $result;
$ready = wait_for { defined $result };

cmp_ok( $ready, '>=', 2, '$ready after call to code over socket' );
is( $result, 11, '$result of code over socket' );

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

is( scalar $code->workers, 1, '$code->workers is 1 for pipe stream' );

undef $result;
$ready = wait_for { defined $result };

cmp_ok( $ready, '>=', 2, '$ready after call to code over pipe' );
is( $result, 11, '$result of code over pipe' );

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

## Now test that parallel runs really are parallel

$code = $set->detach_code(
   code => sub {
      my ( $file, $ret ) = @_;

      open( my $fh, ">", $file ) or die "Cannot write $file - $!";
      close( $file );

      # Wait for synchronisation
      sleep 0.1 while -e $file;

      return $ret;
   },
   workers => 3,
);

is( scalar $code->workers, 3, '$code->workers is 3' );

my $dir = tempdir( CLEANUP => 1 );

my %ret;

foreach my $id ( 1, 2, 3 ) {
   $code->call(
      args => [ "$dir/$id", $id ],
      on_return => sub { $ret{$id} = shift },
      on_error  => sub { die "Test failed early - @_" },
   );
}

my $start = time();

while( not( -e "$dir/1" and -e "$dir/2" and -e "$dir/3" ) ) {
   if( time() - $start > 10 ) {
      die "Not all child processes ready after 10second wait";
   }

   $set->loop_once( 0.1 );
}

ok( 1, 'synchronise files created' );

# Synchronize deleting them;

for my $f ( "$dir/1", "$dir/2", "$dir/3" ) {
   unlink $f or die "Cannot unlink $f - $!";
}

wait_for { keys %ret == 3 };

is_deeply( \%ret, { 1 => 1, 2 => 2, 3 => 3 }, 'ret keys after parallel run' );

is( scalar $code->workers, 3, '$code->workers is still 3' );
