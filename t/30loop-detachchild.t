#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 6;
use Test::Exception;

use POSIX qw( SIGINT WEXITSTATUS WIFSIGNALED WTERMSIG );

use IO::Async::Loop::Poll;

my $loop = IO::Async::Loop::Poll->new();

testing_loop( $loop );

my $exitcode;

sub wait_for_exit
{
   undef $exitcode;
   return wait_for { defined $exitcode };
}

$loop->detach_child(
   code    => sub { return 5; },
   on_exit => sub { ( undef, $exitcode ) = @_ },
);

wait_for_exit;

is( WEXITSTATUS($exitcode), 5, 'WEXITSTATUS($exitcode) after child exit' );

$loop->detach_child(
   code    => sub { die "error"; },
   on_exit => sub { ( undef, $exitcode ) = @_ },
);

wait_for_exit;

is( WEXITSTATUS($exitcode), 255, 'WEXITSTATUS($exitcode) after child die' );

$SIG{INT} = sub { exit( 22 ) };

$loop->detach_child(
   code    => sub { kill SIGINT, $$ },
   on_exit => sub { ( undef, $exitcode ) = @_ },
);

wait_for_exit;

is( WIFSIGNALED($exitcode), 1, 'WIFSIGNALED($exitcode) after child SIGINT' );
is( WTERMSIG($exitcode), SIGINT, 'WTERMSIG($exitcode) after child SIGINT' );

$loop->detach_child(
   code    => sub { kill SIGINT, $$ },
   on_exit => sub { ( undef, $exitcode ) = @_ },
   keep_signals => 1,
);

wait_for_exit;

is( WIFSIGNALED($exitcode), 0, 'WIFSIGNALED($exitcode) after child SIGINT with keep_signals' );
is( WEXITSTATUS($exitcode), 22, 'WEXITSTATUS($exitcode) after child SIGINT with keep_signals' );
