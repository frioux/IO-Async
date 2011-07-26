#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 50;

use IO::Async::Process;

use IO::Async::Loop::Poll;

my $loop = IO::Async::Loop::Poll->new;

testing_loop( $loop );

{
   my $process = IO::Async::Process->new(
      code => sub { print "hello\n"; return 0 },
      stdout => { via => "pipe_read" },
      on_finish => sub { },
   );

   isa_ok( $process->stdout, "IO::Async::Stream", '$process->stdout' );

   is( $process->stdout->notifier_name, "stdout", '$process->stdout->notifier_name' );
   
   my @stdout_lines;

   $process->stdout->configure(
      on_read => sub {
         my ( undef, $buffref ) = @_;
         push @stdout_lines, $1 while $$buffref =~ s/^(.*\n)//;
         return 0;
      },
   );

   $loop->add( $process );

   ok( defined $process->stdout->read_handle, '$process->stdout has read_handle for sub { print }' );

   wait_for { !$process->is_running };

   ok( $process->is_exited,     '$process->is_exited after sub { print }' );
   is( $process->exitstatus, 0, '$process->exitstatus after sub { print }' );

   is_deeply( \@stdout_lines, [ "hello\n" ], '@stdout_lines after sub { print }' );
}

{
   my @stdout_lines;

   my $process = IO::Async::Process->new(
      code => sub { print "hello\n"; return 0 },
      stdout => {
         on_read => sub {
            my ( undef, $buffref ) = @_;
            push @stdout_lines, $1 while $$buffref =~ s/^(.*\n)//;
            return 0;
         },
      },
      on_finish => sub { },
   );

   isa_ok( $process->stdout, "IO::Async::Stream", '$process->stdout' );

   $loop->add( $process );

   ok( defined $process->stdout->read_handle, '$process->stdout has read_handle for sub { print } inline' );

   wait_for { !$process->is_running };

   ok( $process->is_exited,     '$process->is_exited after sub { print } inline' );
   is( $process->exitstatus, 0, '$process->exitstatus after sub { print } inline' );

   is_deeply( \@stdout_lines, [ "hello\n" ], '@stdout_lines after sub { print } inline' );
}

{
   my $stdout;

   my $process = IO::Async::Process->new(
      code => sub { print "hello\n"; return 0 },
      stdout => { into => \$stdout },
      on_finish => sub { },
   );

   isa_ok( $process->stdout, "IO::Async::Stream", '$process->stdout' );

   $loop->add( $process );

   ok( defined $process->stdout->read_handle, '$process->stdout has read_handle for sub { print } into' );

   wait_for { !$process->is_running };

   ok( $process->is_exited,     '$process->is_exited after sub { print } into' );
   is( $process->exitstatus, 0, '$process->exitstatus after sub { print } into' );

   is( $stdout, "hello\n", '$stdout after sub { print } into' )
}

{
   my $stdout;

   my $process = IO::Async::Process->new(
      command => [ $^X, "-e", 'print "hello\n"' ],
      stdout => { into => \$stdout },
      on_finish => sub { },
   );

   $loop->add( $process );

   wait_for { !$process->is_running };

   ok( $process->is_exited,     '$process->is_exited after perl STDOUT' );
   is( $process->exitstatus, 0, '$process->exitstatus after perl STDOUT' );

   is( $stdout, "hello\n", '$stdout after perl STDOUT' );
}

{
   my $stdout;
   my $stderr;

   my $process = IO::Async::Process->new(
      command => [ $^X, "-e", 'print STDOUT "output\n"; print STDERR "error\n";' ],
      stdout => { into => \$stdout },
      stderr => { into => \$stderr },
      on_finish => sub { },
   );

   isa_ok( $process->stderr, "IO::Async::Stream", '$process->stderr' );

   is( $process->stderr->notifier_name, "stderr", '$process->stderr->notifier_name' );

   $loop->add( $process );

   ok( defined $process->stderr->read_handle, '$process->stderr has read_handle' );

   wait_for { !$process->is_running };

   ok( $process->is_exited,     '$process->is_exited after perl STDOUT/STDERR' );
   is( $process->exitstatus, 0, '$process->exitstatus after perl STDOUT/STDERR' );

   is( $stdout, "output\n", '$stdout after perl STDOUT/STDERR' );
   is( $stderr, "error\n",  '$stderr after perl STDOUT/STDERR' );
}

{
   my $stdout;

   my $process = IO::Async::Process->new(
      command => [ $^X, "-pe", '$_ = uc' ],
      stdin   => { via => "pipe_write" },
      stdout  => { into => \$stdout },
      on_finish => sub { },
   );

   isa_ok( $process->stdin, "IO::Async::Stream", '$process->stdin' );

   is( $process->stdin->notifier_name, "stdin", '$process->stdin->notifier_name' );

   $process->stdin->write( "some data\n", on_flush => sub { $_[0]->close } );

   $loop->add( $process );

   ok( defined $process->stdin->write_handle, '$process->stdin has write_handle for perl STDIN->STDOUT' );

   wait_for { !$process->is_running };

   ok( $process->is_exited,     '$process->is_exited after perl STDIN->STDOUT' );
   is( $process->exitstatus, 0, '$process->exitstatus after perl STDIN->STDOUT' );

   is( $stdout, "SOME DATA\n", '$stdout after perl STDIN->STDOUT' );
}

{
   my $stdout;

   my $process = IO::Async::Process->new(
      command => [ $^X, "-pe", '$_ = uc' ],
      stdin   => { from => "some data\n" },
      stdout  => { into => \$stdout },
      on_finish => sub { },
   );

   isa_ok( $process->stdin, "IO::Async::Stream", '$process->stdin' );

   $loop->add( $process );

   ok( defined $process->stdin->write_handle, '$process->stdin has write_handle for perl STDIN->STDOUT from' );

   wait_for { !$process->is_running };

   ok( $process->is_exited,     '$process->is_exited after perl STDIN->STDOUT from' );
   is( $process->exitstatus, 0, '$process->exitstatus after perl STDIN->STDOUT from' );

   is( $stdout, "SOME DATA\n", '$stdout after perl STDIN->STDOUT from' );
}

{
   my $stdout;

   my $process = IO::Async::Process->new(
      command => [ $^X, "-pe", '$_ = uc' ],
      fd0 => { from => "some data\n" },
      fd1 => { into => \$stdout },
      on_finish => sub { },
   );

   $loop->add( $process );

   wait_for { !$process->is_running };

   ok( $process->is_exited,     '$process->is_exited after perl STDIN->STDOUT using fd[n]' );
   is( $process->exitstatus, 0, '$process->exitstatus after perl STDIN->STDOUT using fd[n]' );

   is( $stdout, "SOME DATA\n", '$stdout after perl STDIN->STDOUT using fd[n]' );
}

{
   my $output;

   my $process = IO::Async::Process->new(
      command => [ $^X, "-pe", '$_ = uc' ],
      stdio => { via => "pipe_rdwr" },
      on_finish => sub { },
   );

   isa_ok( $process->stdio, "IO::Async::Stream", '$process->stdio' );

   is( $process->stdio->notifier_name, "stdio", '$process->stdio->notifier_name' );

   my @output_lines;

   $process->stdio->write( "some data\n", on_flush => sub { $_[0]->close_write } );
   $process->stdio->configure(
      on_read => sub {
         my ( undef, $buffref ) = @_;
         push @output_lines, $1 while $$buffref =~ s/^(.*\n)//;
         return 0;
      },
   );

   $loop->add( $process );

   ok( defined $process->stdio->read_handle,  '$process->stdio has read_handle for perl STDIO' );
   ok( defined $process->stdio->write_handle, '$process->stdio has write_handle for perl STDIO' );

   wait_for { !$process->is_running };

   ok( $process->is_exited,     '$process->is_exited after perl STDIO' );
   is( $process->exitstatus, 0, '$process->exitstatus after perl STDIO' );

   is_deeply( \@output_lines, [ "SOME DATA\n" ], '@output_lines after perl STDIO' );
}

{
   my $output;

   my $process = IO::Async::Process->new(
      command => [ $^X, "-pe", '$_ = uc' ],
      stdio => {
         from => "some data\n",
         into => \$output,
      },
      on_finish => sub { },
   );

   $loop->add( $process );

   wait_for { !$process->is_running };

   ok( $process->is_exited,     '$process->is_exited after perl STDIN->STDOUT using stdio' );
   is( $process->exitstatus, 0, '$process->exitstatus after perl STDIN->STDOUT using stdio' );

   is( $output, "SOME DATA\n", '$stdout after perl STDIN->STDOUT using stdio' );
}
