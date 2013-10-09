#!/usr/bin/perl

use strict;
use warnings;

use IO::Async::Test;

use Test::More;
eval { require threads } or plan skip_all => "This Perl does not support threads";

use IO::Async::Loop;

my $loop = IO::Async::Loop->new_builtin;

testing_loop( $loop );

# thread in scalar context
{
   my @result;
   $loop->create_thread(
      code      => sub { return "A result" },
      on_joined => sub { @result = @_ },
   );

   wait_for { @result };

   is_deeply( \@result, [ return => "A result" ], 'result to on_joined for returning thread' );
}

# thread in list context
{
   my @result;
   $loop->create_thread(
      code      => sub { return "A result", "of many", "values" },
      context   => "list",
      on_joined => sub { @result = @_ },
   );

   wait_for { @result };

   is_deeply( \@result, [ return => "A result", "of many", "values" ], 'result to on_joined for returning thread in list context' );
}

# thread that dies
{
   my @result;
   $loop->create_thread(
      code      => sub { die "Ooops I fail\n" },
      on_joined => sub { @result = @_ },
   );

   wait_for { @result };

   is_deeply( \@result, [ died => "Ooops I fail\n" ], 'result to on_joined for a died thread' );
}

done_testing;
