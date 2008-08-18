#!/usr/bin/perl -w

use strict;

use Test::More tests => 4;

use IO::Async::Loop;

$IO::Async::Loop::LOOP_NO_OS = 1;
delete $ENV{IO_ASYNC_LOOP}; # Just in case it was already set

my $loop;

$loop = IO::Async::Loop->new();

isa_ok( $loop, "IO::Async::Loop::IO_Poll", 'Magic constructor in default mode' );

{
   local $ENV{IO_ASYNC_LOOP} = "t::StupidLoop";

   $loop = IO::Async::Loop->new();

   isa_ok( $loop, "t::StupidLoop", 'Magic constructor obeys $ENV{IO_ASYNC_LOOP}' );
}

{
   local $IO::Async::Loop::LOOP = "t::StupidLoop";

   $loop = IO::Async::Loop->new();

   isa_ok( $loop, "t::StupidLoop", 'Magic constructor obeys $IO::Async::Loop::LOOP' );
}

{
   local $IO::Async::Loop::LOOP = "Select";

   $loop = IO::Async::Loop->new();

   isa_ok( $loop, "IO::Async::Loop::Select", 'Magic constructor expands unqualified package names' );
}
