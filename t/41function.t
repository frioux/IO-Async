#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 17;
use Test::Fatal;
use Test::Refcount;

use IO::Async::Function;

use IO::Async::Loop::Poll;

my $loop = IO::Async::Loop::Poll->new();

testing_loop( $loop );

{
   my $function = IO::Async::Function->new(
      min_workers => 1,
      max_workers => 1,
      code => sub { return $_[0] + $_[1] },
   );

   ok( defined $function, '$function defined' );
   isa_ok( $function, "IO::Async::Function", '$function isa IO::Async::Function' );

   is_oneref( $function, '$function has refcount 1' );

   $loop->add( $function );

   is_refcount( $function, 2, '$function has refcount 2 after $loop->add' );

   is( $function->workers, 1, '$function has 1 worker' );
   is( $function->workers_busy, 0, '$function has 0 workers busy' );

   my $result;

   $function->call(
      args => [ 10, 20 ],
      on_return => sub { $result = shift },
      on_error  => sub { die "Test failed early - @_" },
   );

   is_refcount( $function, 2, '$function has refcount 2 after ->call' );

   is( $function->workers_busy, 1, '$function has 1 worker busy after ->call' );

   wait_for { defined $result };

   is( $result, 30, '$result after call returns' );

   is( $function->workers_busy, 0, '$function has 0 workers busy after call returns' );

   $loop->remove( $function );
}

# Test queueing
{
   my $function = IO::Async::Function->new(
      min_workers => 1,
      max_workers => 1,
      code => sub { return $_[0] + $_[1] },
   );

   $loop->add( $function );

   my @result;

   $function->call(
      args => [ 1, 2 ],
      on_return => sub { push @result, shift },
      on_error  => sub { die "Test failed early - @_" },
   );
   $function->call(
      args => [ 3, 4 ],
      on_return => sub { push @result, shift },
      on_error  => sub { die "Test failed early - @_" },
   );

   is( $function->workers, 1, '$function->workers is still 1 after 2 calls' );

   wait_for { @result == 2 };

   is_deeply( \@result, [ 3, 7 ], '@result after both calls return' );

   is( $function->workers, 1, '$function->workers is still 1 after 2 calls return' );

   $loop->remove( $function );
}

# References
{
   my $function = IO::Async::Function->new(
      code => sub { return ref( $_[0] ), \$_[1] },
   );

   $loop->add( $function );

   my @result;

   $function->call(
      args => [ \'a', 'b' ],
      on_return => sub { @result = @_ },
      on_error  => sub { die "Test failed early - @_" },
   );

   wait_for { scalar @result };

   is_deeply( \@result, [ 'SCALAR', \'b' ], 'Call and result preserves references' );

   $loop->remove( $function );
}

# Exception throwing
{
   my $function = IO::Async::Function->new(
      code => sub { die shift },
   );

   $loop->add( $function );

   my $err;

   $function->call(
      args => [ "exception name" ],
      on_return => sub { },
      on_error  => sub { $err = shift },
   );

   wait_for { defined $err };

   like( $err, qr/^exception name at $0 line \d+\.$/, '$err after exception' );

   $loop->remove( $function );
}

{
   my $count = 0;

   my $function = IO::Async::Function->new(
      max_workers => 1,
      code => sub { $count++; die "$count\n" },
      exit_on_die => 0,
   );

   $loop->add( $function );

   my @errs;
   $function->call(
      args => [],
      on_return => sub { },
      on_error  => sub { push @errs, shift },
   );
   $function->call(
      args => [],
      on_return => sub { },
      on_error  => sub { push @errs, shift },
   );

   undef @errs;
   wait_for { scalar @errs == 2 };

   is_deeply( \@errs, [ "1\n", "2\n" ], 'Closed variables preserved when exit_on_die => 0' );

   $loop->remove( $function );
}

{
   my $count = 0;

   my $function = IO::Async::Function->new(
      max_workers => 1,
      code => sub { $count++; die "$count\n" },
      exit_on_die => 1,
   );

   $loop->add( $function );

   my @errs;
   $function->call(
      args => [],
      on_return => sub { },
      on_error  => sub { push @errs, shift },
   );
   $function->call(
      args => [],
      on_return => sub { },
      on_error  => sub { push @errs, shift },
   );

   undef @errs;
   wait_for { scalar @errs == 2 };

   is_deeply( \@errs, [ "1\n", "1\n" ], 'Closed variables preserved when exit_on_die => 1' );

   $loop->remove( $function );
}
