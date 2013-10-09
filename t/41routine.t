#!/usr/bin/perl

use strict;
use warnings;

use IO::Async::Test;

use Test::More;
use Test::Identity;
use Test::Refcount;

use IO::Async::Routine;

use IO::Async::Channel;
use IO::Async::Loop;

my $loop = IO::Async::Loop->new_builtin;

testing_loop( $loop );

foreach my $model (qw( spawn thread )) {
   SKIP: {
      skip "This Perl does not support threads", 6
         if $model eq "thread" and not eval { require threads };

      my $calls   = IO::Async::Channel->new;
      my $returns = IO::Async::Channel->new;

      my @finishargs;
      my $routine = IO::Async::Routine->new(
         model => $model,
         channels_in  => [ $calls ],
         channels_out => [ $returns ],
         code => sub {
            while( my $args = $calls->recv ) {
               last if ref $args eq "SCALAR";

               my $ret = 0;
               $ret += $_ for @$args;
               $returns->send( \$ret );
            }

            return 23;
         },
         on_finish => sub {
            @finishargs = @_;
         },
      );

      isa_ok( $routine, "IO::Async::Routine", "\$routine for $model model" );
      is_oneref( $routine, "\$routine has refcount 1 initially for $model model" );

      $loop->add( $routine );

      is_refcount( $routine, 2, "\$routine has refcount 2 after \$loop->add for $model model" );

      $calls->send( [ 1, 2, 3 ] );

      my $result;
      $returns->recv(
         on_recv => sub { $result = $_[1]; }
      );

      wait_for { defined $result };

      is( ${$result}, 6, "Result for $model model" );

      $calls->send( \"QUIT" );

      wait_for { @finishargs };

      identical( $finishargs[0], $routine, "on_finish passed self for $model model" );

      if( $model eq "spawn" ) {
         is( ($finishargs[1] >> 8), 23, "on_finish passed exit code for $model model" );
      }
      elsif( $model eq "thread" ) {
         is_deeply( [ @finishargs[1..$#finishargs] ],
                    [ return => 23 ],
                    "on_finish passed return value for $model model" );
      }

      undef @finishargs;

      is_refcount( $routine, 2, '$routine has refcount 2 before $loop->remove' );

      $loop->remove( $routine );

      is_oneref( $routine, '$routine has refcount 1 before EOF' );
   }
}

# multiple channels in and out
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

# sharing a Channel between Routines
{
   my $channel = IO::Async::Channel->new;

   my $src_finished;
   my $src_routine = IO::Async::Routine->new(
      channels_out => [ $channel ],
      code => sub {
         $channel->send( [ some => "data" ] );
         return 0;
      },
      on_finish => sub { $src_finished++ },
   );

   $loop->add( $src_routine );

   my $sink_result;
   my $sink_routine = IO::Async::Routine->new(
      channels_in => [ $channel ],
      code => sub {
         my @data = @{ $channel->recv };
         return ( $data[0] eq "some" and $data[1] eq "data" ) ? 0 : 1;
      },
      on_finish => sub { $sink_result = $_[1] },
   );

   $loop->add( $sink_routine );

   wait_for { $src_finished and defined $sink_result };

   is( $sink_result, 0, 'synchronous src->sink can share a channel' );
}

# Test that 'setup' works
{
   my $channel = IO::Async::Channel->new;

   my $routine = IO::Async::Routine->new(
      model => "spawn",
      setup => [
         env => { FOO => "Here is a random string" },
      ],

      channels_out => [ $channel ],
      code => sub {
         $channel->send( [ $ENV{FOO} ] );
         $channel->close;
         return 0;
      },
      on_finish => sub {
         print STDERR "Routine finished\n";
      },
   );

   $loop->add( $routine );

   my $result;
   $channel->recv( on_recv => sub { $result = $_[1] } );

   wait_for { defined $result };

   is( $result->[0], "Here is a random string", '$result from Routine with modified ENV' );

   $loop->remove( $routine );
}

done_testing;
