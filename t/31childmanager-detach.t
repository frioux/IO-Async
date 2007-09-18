#!/usr/bin/perl -w

use strict;

use Test::More tests => 4;
use Test::Exception;

use POSIX qw( WEXITSTATUS );

use IO::Async::Set::IO_Poll;

my $set = IO::Async::Set::IO_Poll->new();
$set->enable_childmanager;

my $manager = $set->get_childmanager;

my $exitcode;

sub wait_for_exit
{
   my $ready = 0;
   undef $exitcode;

   my ( undef, $callerfile, $callerline ) = caller();

   while( !defined $exitcode ) {
      $_ = $set->loop_once( 10 ); # Give code a generous 10 seconds to exit
      die "Nothing was ready after 10 second wait; called at $callerfile line $callerline\n" if $_ == 0;
      $ready += $_;
   }

   $ready;
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
