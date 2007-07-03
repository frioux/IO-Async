#!/usr/bin/perl -w

use strict;

use Test::More tests => 29;
use Test::Exception;

use IO::Async::ChildManager;

use POSIX qw( SIGTERM WIFEXITED WEXITSTATUS WIFSIGNALED WTERMSIG );

use IO::Async::Set::IO_Poll;

my $manager = IO::Async::ChildManager->new();

ok( defined $manager, '$manager defined' );
is( ref $manager, "IO::Async::ChildManager", 'ref $manager is IO::Async::ChildManager' );

my $handled;
$handled = $manager->SIGCHLD;

is( $handled, 0, '$handled while idle' );

is_deeply( [ $manager->list_watching ], [], 'list_watching while idle' );

my $set = IO::Async::Set::IO_Poll->new();

$set->attach_signal( CHLD => sub { $handled = $manager->SIGCHLD } );

my $kid = fork();
defined $kid or die "Cannot fork() - $!";

if( $kid == 0 ) {
   exit( 3 );
}

my $exitcode;

sub wait_for_exit
{
   my $ready = 0;
   undef $exitcode;

   while( !defined $exitcode ) {
      $_ = $set->loop_once( 2 ); # Give code a generous 2 seconds to exit
      die "Nothing was ready after 2 second wait" if $_ == 0;
      $ready += $_;
   }

   $ready;
}

$manager->watch( $kid => sub { ( undef, $exitcode ) = @_; } );

ok( $manager->is_watching( $kid ), 'is_watching after adding $kid' );
is_deeply( [ $manager->list_watching ], [ $kid ], 'list_watching after adding $kid' );

my $ready;
$ready = wait_for_exit;

is( $ready, 1, '$ready after child exit' );
is( $handled, 1, '$handled after child exit' );

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

$ready = $set->loop_once( 0.1 );

ok( $manager->is_watching( $kid ), 'is_watching after loop' );
is_deeply( [ $manager->list_watching ], [ $kid ], 'list_watching after loop' );

is( $ready, 0, '$ready after no death' );

kill SIGTERM, $kid;

$ready = wait_for_exit;

is( $ready, 1, '$ready after child SIGTERM' );
is( $handled, 1, '$handled after child SIGTERM' );

ok( WIFSIGNALED($exitcode),          'WIFSIGNALED($exitcode) after SIGTERM' );
is( WTERMSIG($exitcode),    SIGTERM, 'WTERMSIG($exitcode) after SIGTERM' );

ok( !$manager->is_watching( $kid ), 'is_watching after child SIGTERM' );
is_deeply( [ $manager->list_watching ], [], 'list_watching after child SIGTERM' );

# Now lets test the integration with a ::Set

$set->detach_signal( 'CHLD' );
undef $manager;

dies_ok( sub { $set->watch_child( 1234 => sub { "DUMMY" } ) },
         'watch_child() before enable_childmanager() fails' );

$set->enable_childmanager;

dies_ok( sub { $set->enable_childmanager; },
         'enable_childmanager() again fails' );

$kid = fork();
defined $kid or die "Cannot fork() - $!";

if( $kid == 0 ) {
   exit( 5 );
}

$set->watch_child( $kid => sub { ( undef, $exitcode ) = @_; } );

$ready = wait_for_exit;

is( $ready, 1, '$ready after child exit for set' );

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after child exit for set' );
is( WEXITSTATUS($exitcode), 5, 'WEXITSTATUS($exitcode) after child exit for set' );

$set->disable_childmanager;

dies_ok( sub { $set->disable_childmanager; },
         'disable_childmanager() again fails' );
