#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use IO::Async::Loop;

$IO::Async::Loop::LOOP_NO_OS = 1;
delete $ENV{IO_ASYNC_LOOP}; # Just in case it was already set

my $loop;

$loop = IO::Async::Loop->new;

isa_ok( $loop, "IO::Async::Loop::Poll", 'Magic constructor in default mode' );

is( IO::Async::Loop->new, $loop, 'IO::Async::Loop->new again yields same loop' );

{
   local $ENV{IO_ASYNC_LOOP} = "t::StupidLoop";
   undef $IO::Async::Loop::ONE_TRUE_LOOP;

   $loop = IO::Async::Loop->new;

   isa_ok( $loop, "t::StupidLoop", 'Magic constructor obeys $ENV{IO_ASYNC_LOOP}' );
}

{
   local $IO::Async::Loop::LOOP = "t::StupidLoop";
   undef $IO::Async::Loop::ONE_TRUE_LOOP;

   $loop = IO::Async::Loop->new;

   isa_ok( $loop, "t::StupidLoop", 'Magic constructor obeys $IO::Async::Loop::LOOP' );
}

{
   local $IO::Async::Loop::LOOP = "Select";
   undef $IO::Async::Loop::ONE_TRUE_LOOP;

   $loop = IO::Async::Loop->new;

   isa_ok( $loop, "IO::Async::Loop::Select", 'Magic constructor expands unqualified package names' );
}

done_testing;
