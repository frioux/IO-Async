#!/usr/bin/perl

use strict;
use warnings;

use IO::Async::Test;

use Test::More;

use POSIX qw( SIGINT WEXITSTATUS WIFSIGNALED WTERMSIG );

use IO::Async::Loop;

my $loop = IO::Async::Loop->new_builtin;

testing_loop( $loop );

{
   my $exitcode;
   $loop->fork(
      code    => sub { return 5; },
      on_exit => sub { ( undef, $exitcode ) = @_ },
   );

   wait_for { defined $exitcode };

   is( WEXITSTATUS($exitcode), 5, 'WEXITSTATUS($exitcode) after child exit' );
}

{
   my $exitcode;
   $loop->fork(
      code    => sub { die "error"; },
      on_exit => sub { ( undef, $exitcode ) = @_ },
   );

   wait_for { defined $exitcode };

   is( WEXITSTATUS($exitcode), 255, 'WEXITSTATUS($exitcode) after child die' );
}

{
   local $SIG{INT} = sub { exit( 22 ) };

   my $exitcode;
   $loop->fork(
      code    => sub { kill SIGINT, $$ },
      on_exit => sub { ( undef, $exitcode ) = @_ },
   );

   wait_for { defined $exitcode };

   is( WIFSIGNALED($exitcode), 1, 'WIFSIGNALED($exitcode) after child SIGINT' );
   is( WTERMSIG($exitcode), SIGINT, 'WTERMSIG($exitcode) after child SIGINT' );
}

{
   local $SIG{INT} = sub { exit( 22 ) };

   my $exitcode;
   $loop->fork(
      code    => sub { kill SIGINT, $$ },
      on_exit => sub { ( undef, $exitcode ) = @_ },
      keep_signals => 1,
   );

   wait_for { defined $exitcode };

   is( WIFSIGNALED($exitcode), 0, 'WIFSIGNALED($exitcode) after child SIGINT with keep_signals' );
   is( WEXITSTATUS($exitcode), 22, 'WEXITSTATUS($exitcode) after child SIGINT with keep_signals' );
}

done_testing;
