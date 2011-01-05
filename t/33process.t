#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 8;

use POSIX qw( WIFEXITED WEXITSTATUS );

use IO::Async::Process;

use IO::Async::Loop;

my $loop = IO::Async::Loop->new();

testing_loop( $loop );

{
   my $exitcode;

   my $process = IO::Async::Process->new(
      code => sub { return 0 },
      on_finish => sub { ( undef, $exitcode ) = @_; },
   );

   ok( !$process->is_running, '$process is not yet running' );

   $loop->add( $process );

   ok( $process->is_running, '$process is running' );

   wait_for { defined $exitcode };

   ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after sub { 0 }' );
   is( WEXITSTATUS($exitcode), 0, 'WEXITSTATUS($exitcode) after sub { 0 }' );

   ok( !$process->is_running, '$process no longer running' );

   ok( $process->is_exited,     '$process->is_exited after sub { 0 }' );
   is( $process->exitstatus, 0, '$process->exitstatus after sub { 0 }' );

   ok( !defined $process->get_loop, '$process no longer in Loop' );
}
