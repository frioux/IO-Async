#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 32;
use Test::Fatal;
use Test::Refcount;

use File::Temp qw( tempdir );
use Time::HiRes qw( sleep );

use IO::Async::Function;

use IO::Async::Loop::Poll;

use constant AUT => $ENV{TEST_QUICK_TIMERS} ? 0.1 : 1;

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
   is( $function->workers_idle, 1, '$function has 1 workers idle' );

   my $result;

   $function->call(
      args => [ 10, 20 ],
      on_return => sub { $result = shift },
      on_error  => sub { die "Test failed early - @_" },
   );

   is_refcount( $function, 2, '$function has refcount 2 after ->call' );

   is( $function->workers_busy, 1, '$function has 1 worker busy after ->call' );
   is( $function->workers_idle, 0, '$function has 0 worker idle after ->call' );

   wait_for { defined $result };

   is( $result, 30, '$result after call returns' );

   is( $function->workers_busy, 0, '$function has 0 workers busy after call returns' );
   is( $function->workers_idle, 1, '$function has 1 workers idle after call returns' );

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

{
   my $function = IO::Async::Function->new(
      min_workers => 0,
      max_workers => 1,
      code => sub { $_[0] ? exit shift : return 0 },
   );

   $loop->add( $function );

   my $err;

   $function->call(
      args => [ 16 ],
      on_return => sub { $err = "" },
      on_error  => sub { $err = [ @_ ] },
   );

   wait_for { defined $err };

   # Not sure what reason we might get - need to check both
   ok( $err->[0] eq "closed" || $err->[0] eq "exit", '$err->[0] after child death' );

   is( scalar $function->workers, 0, '$function->workers is now 0' );

   $function->call(
      args => [ 0 ],
      on_return => sub { $err = "return" },
      on_error  => sub { $err = [ @_ ] },
   );

   is( scalar $function->workers, 1, '$function->workers is now 1 again' );

   undef $err;
   wait_for { defined $err };

   is( $err, "return", '$err is "return" after child nondeath' );

   $loop->remove( $function );
}

## Now test that parallel runs really are parallel
{
   my $function = IO::Async::Function->new(
      min_workers => 3,
      code => sub {
         my ( $file, $ret ) = @_;

         open( my $fh, ">", $file ) or die "Cannot write $file - $!";
         close( $file );

         # Wait for synchronisation
         sleep 0.1 while -e $file;

         return $ret;
      },
   );

   $loop->add( $function );

   is( scalar $function->workers, 3, '$function->workers is 3' );

   my $dir = tempdir( CLEANUP => 1 );

   my %ret;

   foreach my $id ( 1, 2, 3 ) {
      $function->call(
         args => [ "$dir/$id", $id ],
         on_return => sub { $ret{$id} = shift },
         on_error  => sub { die "Test failed early - @_" },
      );
   }

   wait_for { -e "$dir/1" and -e "$dir/2" and -e "$dir/3" };

   ok( 1, 'synchronise files created' );

   # Synchronize deleting them;
   for my $f ( "$dir/1", "$dir/2", "$dir/3" ) {
      unlink $f or die "Cannot unlink $f - $!";
   }

   undef %ret;
   wait_for { keys %ret == 3 };

   is_deeply( \%ret, { 1 => 1, 2 => 2, 3 => 3 }, 'ret keys after parallel run' );

   is( scalar $function->workers, 3, '$function->workers is still 3' );

   $loop->remove( $function );
}

# Test that 'setup' works
{
   my $function = IO::Async::Function->new(
      code => sub {
         return $ENV{$_[0]};
      },

      setup => [
         env => { FOO => "Here is a random string" },
      ],
   );

   $loop->add( $function );

   my $result;

   $function->call(
      args => [ "FOO" ],
      on_return => sub { $result = shift },
      on_error  => sub { die "Test failed early - @_" },
   );

   wait_for { defined $result };

   is( $result, "Here is a random string", '$result after call with modified ENV' );

   $loop->remove( $function );
}

# Test for idle timeout
{
   my $function = IO::Async::Function->new(
      min_workers => 0,
      max_workers => 1,
      idle_timeout => 2 * AUT,
      code => sub { return $_[0] },
   );

   $loop->add( $function );

   my $result;

   $function->call(
      args => [ 1 ],
      on_result => sub { $result = $_[0] },
   );

   wait_for { defined $result };

   is( $function->workers, 1, '$function has 1 worker after call' );

   my $waited;
   $loop->enqueue_timer( delay => 1 * AUT, code => sub { $waited++ } );

   wait_for { $waited };

   is( $function->workers, 1, '$function still has 1 worker after short delay' );

   undef $result;
   $function->call(
      args => [ 1 ],
      on_result => sub { $result = $_[0] },
   );

   wait_for { defined $result };

   undef $waited;
   $loop->enqueue_timer( delay => 3 * AUT, code => sub { $waited++ } );

   wait_for { $waited };

   is( $function->workers, 0, '$function has 0 workers after longer delay' );

   $loop->remove( $function );
}
