#!/usr/bin/perl -w

use strict;

use lib 't';
use TestAsync;

use Test::More tests => 26;
use Test::Exception;

use IO::Async::ChildManager;

use POSIX qw( SIGTERM WIFEXITED WEXITSTATUS WIFSIGNALED WTERMSIG );

use IO::Async::Loop::IO_Poll;

my $loop = IO::Async::Loop::IO_Poll->new();

testing_loop( $loop );

my $manager = IO::Async::ChildManager->new( loop => $loop );

ok( defined $manager, '$manager defined' );
is( ref $manager, "IO::Async::ChildManager", 'ref $manager is IO::Async::ChildManager' );

is_deeply( [ $manager->list_watching ], [], 'list_watching while idle' );

my $kid = fork();
defined $kid or die "Cannot fork() - $!";

if( $kid == 0 ) {
   exit( 3 );
}

my $exitcode;

sub wait_for_exit
{
   undef $exitcode;
   return wait_for { defined $exitcode };
}

$manager->watch( $kid => sub { ( undef, $exitcode ) = @_; } );

ok( $manager->is_watching( $kid ), 'is_watching after adding $kid' );
is_deeply( [ $manager->list_watching ], [ $kid ], 'list_watching after adding $kid' );

my $ready;
$ready = wait_for_exit;

is( $ready, 1, '$ready after child exit' );

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after child exit' );
is( WEXITSTATUS($exitcode), 3, 'WEXITSTATUS($exitcode) after child exit' );

ok( !$manager->is_watching( $kid ), 'is_watching after child exit' );
is_deeply( [ $manager->list_watching ], [], 'list_watching after child exit' );

$kid = fork();
defined $kid or die "Cannot fork() - $!";

if( $kid == 0 ) {
   sleep( 10 );
   # Just in case the parent died already and didn't kill us
   exit( 0 );
}

$manager->watch( $kid => sub { ( undef, $exitcode ) = @_; } );

ok( $manager->is_watching( $kid ), 'is_watching after adding $kid' );
is_deeply( [ $manager->list_watching ], [ $kid ], 'list_watching after adding $kid' );

$ready = $loop->loop_once( 0.1 );

ok( $manager->is_watching( $kid ), 'is_watching after loop' );
is_deeply( [ $manager->list_watching ], [ $kid ], 'list_watching after loop' );

is( $ready, 0, '$ready after no death' );

kill SIGTERM, $kid;

$ready = wait_for_exit;

is( $ready, 1, '$ready after child SIGTERM' );

ok( WIFSIGNALED($exitcode),          'WIFSIGNALED($exitcode) after SIGTERM' );
is( WTERMSIG($exitcode),    SIGTERM, 'WTERMSIG($exitcode) after SIGTERM' );

ok( !$manager->is_watching( $kid ), 'is_watching after child SIGTERM' );
is_deeply( [ $manager->list_watching ], [], 'list_watching after child SIGTERM' );

# Now lets test the integration with a ::Loop

$loop->detach_signal( 'CHLD' );
undef $manager;

dies_ok( sub { $loop->watch_child( 1234 => sub { "DUMMY" } ) },
         'watch_child() before enable_childmanager() fails' );

$loop->enable_childmanager;

dies_ok( sub { $loop->enable_childmanager; },
         'enable_childmanager() again fails' );

$kid = fork();
defined $kid or die "Cannot fork() - $!";

if( $kid == 0 ) {
   exit( 5 );
}

$loop->watch_child( $kid => sub { ( undef, $exitcode ) = @_; } );

$ready = wait_for_exit;

is( $ready, 1, '$ready after child exit for loop' );

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after child exit for loop' );
is( WEXITSTATUS($exitcode), 5, 'WEXITSTATUS($exitcode) after child exit for loop' );

$loop->disable_childmanager;

dies_ok( sub { $loop->disable_childmanager; },
         'disable_childmanager() again fails' );
