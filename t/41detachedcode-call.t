#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 38;
use Test::Exception;

use File::Temp qw( tempdir );
use Time::HiRes qw( sleep );

use IO::Async::DetachedCode;

use IO::Async::Loop::IO_Poll;

my $loop = IO::Async::Loop::IO_Poll->new();
$loop->enable_childmanager;

testing_loop( $loop );

my $code = IO::Async::DetachedCode->new(
   loop => $loop,
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

$code->call(
   args => [ 10, 20 ],
   on_return => sub { $result = shift },
   on_error  => sub { die "Test failed early - @_" },
);

is( $result, undef, '$result before call returns' );

is( scalar $code->workers, 1, '$code->workers is still 1 after call' );

undef $result;
wait_for { defined $result };

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

undef @result;
wait_for { @result == 2 };

is_deeply( \@result, [ 3, 7 ], '@result after both calls return' );

is( scalar $code->workers, 1, '$code->workers is still 1 after 2 calls return' );

$code = IO::Async::DetachedCode->new(
   loop => $loop,
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
wait_for { defined $result };

is( $result, 11, '$result of code over socket' );

$code = IO::Async::DetachedCode->new(
   loop => $loop,
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
wait_for { defined $result };

is( $result, 11, '$result of code over pipe' );

dies_ok( sub { IO::Async::DetachedCode->new(
                  loop => $loop,
                  code => sub { return $_[0] },
                  stream => "oranges",
               ); },
         'Unrecognised stream type fails' );

$code = IO::Async::DetachedCode->new(
   loop => $loop,
   code => sub { return $_[0] + $_[1] },
   marshaller => "flat",
);

$code->call(
   args => [ 7, 8 ],
   on_return => sub { $result = shift },
   on_error  => sub { die "Test failed early - @_" },
);

undef $result;
wait_for { defined $result };

is( $result, 15, '$result of code over flat' );

dies_ok( sub { $code->call( 
                  args => [ \'a' ], 
                  on_return => sub {},
                  on_error  => sub {},
               );
            },
         'call with reference arguments using flat marshaller dies' );

dies_ok( sub { IO::Async::DetachedCode->new(
                  loop => $loop,
                  code => sub { return $_[0] },
                  marshaller => "grapefruit",
               ); },
         'Unrecognised marshaller type fails' );

$code = IO::Async::DetachedCode->new(
   loop => $loop,
   code => sub { return ref( $_[0] ), \$_[1] },
   marshaller => "storable",
);

$code->call(
   args => [ \'a', 'b' ],
   on_return => sub { @result = @_ },
   on_error  => sub { die "Test failed early - @_" },
);

undef @result;
wait_for { scalar @result };

is_deeply( \@result, [ 'SCALAR', \'b' ], '@result after call to code over storable marshaller' );

my $err;

$code = IO::Async::DetachedCode->new(
   loop=> $loop,
   code => sub { die shift },
);

$code->call(
   args => [ "exception name" ],
   on_return => sub { },
   on_error  => sub { $err = shift },
);

undef $err;
wait_for { defined $err };

like( $err, qr/^exception name at $0 line \d+\.$/, '$err after exception' );

my $count = 0;
$code = IO::Async::DetachedCode->new(
   loop=> $loop,
   code => sub { $count++; die "$count\n" },
   exit_on_die => 0,
);

my @errs;
$code->call(
   args => [],
   on_return => sub { },
   on_error  => sub { push @errs, shift },
);
$code->call(
   args => [],
   on_return => sub { },
   on_error  => sub { push @errs, shift },
);

undef @errs;
wait_for { scalar @errs == 2 };

is_deeply( \@errs, [ "1\n", "2\n" ], 'Closed variables preserved when exit_on_die => 0' );

$code = IO::Async::DetachedCode->new(
   loop=> $loop,
   code => sub { $count++; die "$count\n" },
   exit_on_die => 1,
);

undef @errs;

$code->call(
   args => [],
   on_return => sub { },
   on_error  => sub { push @errs, shift },
);
wait_for { scalar @errs == 1 };

$code->call(
   args => [],
   on_return => sub { },
   on_error  => sub { push @errs, shift },
);
wait_for { scalar @errs == 2 };

is_deeply( \@errs, [ "1\n", "1\n" ], 'Closed variables no preserved when exit_on_die => 1' );

$code = IO::Async::DetachedCode->new(
   loop=> $loop,
   code => sub { $_[0] ? exit shift : return 0 },
);

$code->call(
   args => [ 16 ],
   on_return => sub { $err = "" },
   on_error  => sub { $err = [ @_ ] },
);

undef $err;
wait_for { defined $err };

# Not sure what reason we might get - need to check both
ok( $err->[0] eq "closed" || $err->[0] eq "exit", '$err->[0] after child death' );

is( scalar $code->workers, 0, '$code->workers is now 0' );

$code->call(
   args => [ 0 ],
   on_return => sub { $err = "return" },
   on_error  => sub { $err = [ @_ ] },
);

is( scalar $code->workers, 1, '$code->workers is now 1 again' );

undef $err;
wait_for { defined $err };

is( $err, "return", '$err is "return" after child nondeath' );

$code = $loop->detach_code(
   code => sub { return join( "+", @_ ) },
);

$code->call(
   args => [ qw( a b c ) ],
   on_return => sub { $result = shift },
   on_error  => sub { die "Test failed early - @_" },
);

undef $result;
wait_for { defined $result };

is( $result, "a+b+c", '$result of Set-constructed code' );

## Now test that parallel runs really are parallel

$code = $loop->detach_code(
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

   $loop->loop_once( 0.1 );
}

ok( 1, 'synchronise files created' );

# Synchronize deleting them;

for my $f ( "$dir/1", "$dir/2", "$dir/3" ) {
   unlink $f or die "Cannot unlink $f - $!";
}

undef %ret;
wait_for { keys %ret == 3 };

is_deeply( \%ret, { 1 => 1, 2 => 2, 3 => 3 }, 'ret keys after parallel run' );

is( scalar $code->workers, 3, '$code->workers is still 3' );

$code = $loop->detach_code(
   code => sub {
      return $ENV{$_[0]};
   },

   setup => [
      env => { FOO => "Here is a random string" },
   ],
);

$code->call(
   args => [ "FOO" ],
   on_return => sub { $result = shift },
   on_error  => sub { die "Test failed early - @_" },
);

undef $result;
wait_for { defined $result };

is( $result, "Here is a random string", '$result after call with modified ENV' );
