#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 11;
use Test::Identity;
use Test::Refcount;

use IO::Async::Routine;

use IO::Async::Channel;
use IO::Async::Loop::Poll;

my $loop = IO::Async::Loop::Poll->new;

testing_loop( $loop );

{
   my $calls   = IO::Async::Channel->new;
   my $returns = IO::Async::Channel->new;

   my $routine = IO::Async::Routine->new(
      channels_in  => [ $calls ],
      channels_out => [ $returns ],
      code => sub {
         while( my $args = $calls->recv ) {
            my $ret = 0;
            $ret += $_ for @$args;
            $returns->send( \$ret );
         }
      },
      on_finish => sub { },
   );

   isa_ok( $routine, "IO::Async::Routine", '$routine' );
   is_oneref( $routine, '$routine has refcount 1 initially' );

   $loop->add( $routine );

   is_refcount( $routine, 2, '$routine has refcount 2 after $loop->add' );

   $calls->send( [ 1, 2, 3 ] );

   my $result;
   $returns->recv(
      on_recv => sub { $result = $_[1]; }
   );

   wait_for { defined $result };

   is( ${$result}, 6, 'Result' );

   is_refcount( $routine, 2, '$routine has refcount 2 before $loop->remove' );

   $loop->remove( $routine );

   is_oneref( $routine, '$routine has refcount 1 before EOF' );
}

{
   my $in1 = IO::Async::Channel->new;
   my $in2 = IO::Async::Channel->new;
   my $out1 = IO::Async::Channel->new;
   my $out2 = IO::Async::Channel->new;

   my $routine = IO::Async::Routine->new(
      channels_in  => [ $in1, $in2 ],
      channels_out => [ $out1, $out2 ],
      code => sub {
         while( my $op = $in1->recv ) {
            $op = $$op; # deref
            $out1->send( \"Ready $op" );
            my @args = @{ $in2->recv };
            my $result = $op eq "+" ? $args[0] + $args[1]
                                    : "ERROR";
            $out2->send( \$result );
         }
      },
      on_finish => sub { },
   );

   isa_ok( $routine, "IO::Async::Routine", '$routine' );

   $loop->add( $routine );

   $in1->send( \"+" );

   my $status;
   $out1->recv( on_recv => sub { $status = ${$_[1]} } );

   wait_for { defined $status };
   is( $status, "Ready +", '$status midway through Routine' );

   $in2->send( [ 10, 20 ] );

   my $result;
   $out2->recv( on_recv => sub { $result = ${$_[1]} } );

   wait_for { defined $result };

   is( $result, 30, '$result at end of Routine' );

   $loop->remove( $routine );
}

{
   my $in = IO::Async::Channel->new;

   my @finishargs;
   my $routine = IO::Async::Routine->new(
      channels_in => [ $in ],
      code => sub {
         $in->recv;
         return 0;
      },
      on_finish => sub { @finishargs = @_; },
   );

   $loop->add( $routine );

   $in->send( \"QUIT" );

   wait_for { @finishargs };

   identical( $finishargs[0], $routine, 'on_finish passed self' );
   is( $finishargs[1], 0, 'on_finish passed exit code' );
}
