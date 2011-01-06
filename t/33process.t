#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 18;

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

{
   my $exitcode;

   my $process = IO::Async::Process->new(
      code => sub { return 3 },
      on_finish => sub { ( undef, $exitcode ) = @_; },
   );

   $loop->add( $process );

   wait_for { defined $exitcode };

   ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after sub { 3 }' );
   is( WEXITSTATUS($exitcode), 3, 'WEXITSTATUS($exitcode) after sub { 3 }' );

   ok( $process->is_exited,     '$process->is_exited after sub { 3 }' );
   is( $process->exitstatus, 3, '$process->exitstatus after sub { 3 }' );
}

{
   my ( $exitcode, $error );

   my $process = IO::Async::Process->new(
      code => sub { die "An error\n" },
      on_finish => sub { die "Test failed early\n" },
      on_error => sub { ( undef, $exitcode, undef, $error ) = @_ },
   );

   $loop->add( $process );

   wait_for { defined $exitcode };

   ok( WIFEXITED($exitcode),        'WIFEXITED($exitcode) after sub { die }' );
   is( WEXITSTATUS($exitcode), 255, 'WEXITSTATUS($exitcode) after sub { die }' );
   is( $error, "An error\n",        '$error after sub { die }' );

   ok( $process->is_exited,           '$process->is_exited after sub { die }' );
   is( $process->exitstatus, 255,     '$process->exitstatus after sub { die }' );
   is( $process->error, "An error\n", '$process->error after sub { die }' );
}
