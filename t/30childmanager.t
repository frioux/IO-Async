#!/usr/bin/perl -w

use strict;

use Test::More tests => 10;
use Test::Exception;

use IO::Async::ChildManager;

use POSIX qw( SIGTERM WIFEXITED WEXITSTATUS WIFSIGNALED WTERMSIG );

use IO::Async::Set::IO_Poll;

my $manager = IO::Async::ChildManager->new();

my $handled;
$handled = $manager->SIGCHLD;

is( $handled, 0, '$handled while idle' );

my $set = IO::Async::Set::IO_Poll->new();

$set->attach_signal( CHLD => sub { $handled = $manager->SIGCHLD } );

my $kid = fork();
defined $kid or die "Cannot fork() - $!";

if( $kid == 0 ) {
   exit( 3 );
}

my $exitcode;

$manager->watch( $kid => sub { ( undef, $exitcode ) = @_; } );

my $ready;
$ready = $set->loop_once( 0.1 );

is( $ready, 1, '$ready after child exit' );
is( $handled, 1, '$handled after child exit' );

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after child exit' );
is( WEXITSTATUS($exitcode), 3, 'WEXITSTATUS($exitcode) after child exit' );

$kid = fork();
defined $kid or die "Cannot fork() - $!";

if( $kid == 0 ) {
   sleep( 10 );
   # Just in case the parent died already and didn't kill us
   exit( 0 );
}

$manager->watch( $kid => sub { ( undef, $exitcode ) = @_; } );

$ready = $set->loop_once( 0.1 );

is( $ready, 0, '$ready after no death' );

kill SIGTERM, $kid;

$ready = $set->loop_once( 0.1 );

is( $ready, 1, '$ready after child SIGTERM' );
is( $handled, 1, '$handled after child SIGTERM' );

ok( WIFSIGNALED($exitcode),          'WIFSIGNALED($exitcode) after SIGTERM' );
is( WTERMSIG($exitcode),    SIGTERM, 'WTERMSIG($exitcode) after SIGTERM' );
