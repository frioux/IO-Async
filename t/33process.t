#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 28;

use POSIX qw( WIFEXITED WEXITSTATUS ENOENT );
use constant ENOENT_MESSAGE => do { local $! = ENOENT; "$!" };

use IO::Async::Process;

use IO::Async::Loop;

my $loop = IO::Async::Loop->new();

testing_loop( $loop );

{
   my $exitcode;

   my $process;
   
   $process = IO::Async::Process->new(
      code => sub { return 0 },
      on_finish => sub {
         is( $_[0], $process, '$_[0] in on_finish is $process' );
         ( undef, $exitcode ) = @_;
      },
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
   my $process = IO::Async::Process->new(
      code => sub { return 3 },
      on_finish => sub { },
   );

   $loop->add( $process );

   wait_for { !$process->is_running };

   ok( $process->is_exited,     '$process->is_exited after sub { 3 }' );
   is( $process->exitstatus, 3, '$process->exitstatus after sub { 3 }' );
}

{
   my ( $exitcode, $exception );

   my $process = IO::Async::Process->new(
      code => sub { die "An exception\n" },
      on_finish => sub { die "Test failed early\n" },
      on_error => sub { ( undef, $exitcode, undef, $exception ) = @_ },
   );

   $loop->add( $process );

   wait_for { defined $exitcode };

   ok( WIFEXITED($exitcode),        'WIFEXITED($exitcode) after sub { die }' );
   is( WEXITSTATUS($exitcode), 255, 'WEXITSTATUS($exitcode) after sub { die }' );
   is( $exception, "An exception\n",        '$exception after sub { die }' );

   ok( $process->is_exited,           '$process->is_exited after sub { die }' );
   is( $process->exitstatus, 255,     '$process->exitstatus after sub { die }' );
   is( $process->exception, "An exception\n", '$process->exception after sub { die }' );
}

{
   my $process = IO::Async::Process->new(
      command => [ $^X, "-e", '1' ],
      on_finish => sub { },
   );

   $loop->add( $process );

   wait_for { !$process->is_running };

   ok( $process->is_exited,     '$process->is_exited after perl -e 1' );
   is( $process->exitstatus, 0, '$process->exitstatus after perl -e 1' );
}

{
   my $process = IO::Async::Process->new(
      command => [ $^X, "-e", 'exit 5' ],
      on_finish => sub { },
   );

   $loop->add( $process );

   wait_for { !$process->is_running };

   ok( $process->is_exited,     '$process->is_exited after perl -e exit 5' );
   is( $process->exitstatus, 5, '$process->exitstatus after perl -e exit 5' );
}

{
   # Just be paranoid in case anyone actually has this
   my $donotexist = "/bin/donotexist";
   $donotexist .= "X" while -e $donotexist;

   my ( $exitcode, $errno, $exception );

   my $process = IO::Async::Process->new(
      command => $donotexist,
      on_finish => sub { die "Test failed early\n" },
      on_error => sub { ( undef, $exitcode, $errno, $exception ) = @_ },
   );

   $loop->add( $process );

   wait_for { !$process->is_running };

   is( $errno+0, ENOENT,         '$errno number after donotexist' ); 
   is( "$errno", ENOENT_MESSAGE, '$errno string after donotexist' );

   ok( $process->is_exited,           '$process->is_exited after donotexist' );
   is( $process->exitstatus, 255,     '$process->exitstatus after donotexist' );
   is( $process->errno,  ENOENT,         '$process->errno number after donotexist' );
   is( $process->errstr, ENOENT_MESSAGE, '$process->errno string after donotexist' );
   is( $process->exception, "", '$process->exception after donotexist' );
}
