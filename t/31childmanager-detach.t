#!/usr/bin/perl -w

use strict;

use lib 't';
use TestAsync;

use Test::More tests => 8;
use Test::Exception;

use POSIX qw( SIGINT WEXITSTATUS WIFSIGNALED WTERMSIG );

use IO::Async::Set::IO_Poll;

my $set = IO::Async::Set::IO_Poll->new();
$set->enable_childmanager;

testing_set( $set );

my $manager = $set->get_childmanager;

my $exitcode;

sub wait_for_exit
{
   undef $exitcode;
   return wait_for { defined $exitcode };
}

$manager->detach_child(
   code    => sub { return 5; },
   on_exit => sub { ( undef, $exitcode ) = @_ },
);

my $ready;
$ready = wait_for_exit;

is( $ready, 1, '$ready after child exit' );
is( WEXITSTATUS($exitcode), 5, 'WEXITSTATUS($exitcode) after child exit' );

$manager->detach_child(
   code    => sub { die "error"; },
   on_exit => sub { ( undef, $exitcode ) = @_ },
);

$ready = wait_for_exit;

is( $ready, 1, '$ready after child die' );
is( WEXITSTATUS($exitcode), 255, 'WEXITSTATUS($exitcode) after child die' );

$SIG{INT} = sub { exit( 22 ) };

$manager->detach_child(
   code    => sub { kill SIGINT, $$ },
   on_exit => sub { ( undef, $exitcode ) = @_ },
);

wait_for_exit;

is( WIFSIGNALED($exitcode), 1, 'WIFSIGNALED($exitcode) after child SIGINT' );
is( WTERMSIG($exitcode), SIGINT, 'WTERMSIG($exitcode) after child SIGINT' );

$manager->detach_child(
   code    => sub { kill SIGINT, $$ },
   on_exit => sub { ( undef, $exitcode ) = @_ },
   keep_signals => 1,
);

wait_for_exit;

is( WIFSIGNALED($exitcode), 0, 'WIFSIGNALED($exitcode) after child SIGINT with keep_signals' );
is( WEXITSTATUS($exitcode), 22, 'WEXITSTATUS($exitcode) after child SIGINT with keep_signals' );
