#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 9;
use Test::Refcount;

use POSIX qw( SIGTERM WIFEXITED WEXITSTATUS WIFSIGNALED WTERMSIG );

use IO::Async::Loop::Poll;

my $loop = IO::Async::Loop::Poll->new();
is_oneref( $loop, '$loop has refcount 1' );

testing_loop( $loop );
is_refcount( $loop, 2, '$loop has refcount 2 after adding to IO::Async::Test' );

my $kid = fork();
defined $kid or die "Cannot fork() - $!";

if( $kid == 0 ) {
   exit( 3 );
}

my $exitcode;

$loop->watch_child( $kid => sub { ( undef, $exitcode ) = @_; } );

is_refcount( $loop, 2, '$loop has refcount 2 after watch_child' );
ok( !defined $exitcode, '$exitcode not defined before ->loop_once' );

undef $exitcode;
wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after child exit' );
is( WEXITSTATUS($exitcode), 3, 'WEXITSTATUS($exitcode) after child exit' );

$kid = fork();
defined $kid or die "Cannot fork() - $!";

if( $kid == 0 ) {
   sleep( 10 );
   # Just in case the parent died already and didn't kill us
   exit( 0 );
}

$loop->watch_child( $kid => sub { ( undef, $exitcode ) = @_; } );

kill SIGTERM, $kid;

undef $exitcode;
wait_for { defined $exitcode };

ok( WIFSIGNALED($exitcode),          'WIFSIGNALED($exitcode) after SIGTERM' );
is( WTERMSIG($exitcode),    SIGTERM, 'WTERMSIG($exitcode) after SIGTERM' );

is_refcount( $loop, 2, '$loop has refcount 2 at EOF' );
