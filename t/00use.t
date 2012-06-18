#!/usr/bin/perl -w

use strict;
use Test::More tests => 23;

use_ok( "IO::Async::MergePoint" );

use_ok( "IO::Async::Notifier" );
use_ok( "IO::Async::Handle" );
use_ok( "IO::Async::Stream" );
use_ok( "IO::Async::Timer" );
use_ok( "IO::Async::Timer::Absolute" );
use_ok( "IO::Async::Timer::Countdown" );
use_ok( "IO::Async::Timer::Periodic" );
use_ok( "IO::Async::Signal" );
use_ok( "IO::Async::Listener" );
use_ok( "IO::Async::Socket" );
use_ok( "IO::Async::File" );
use_ok( "IO::Async::FileStream" );

use_ok( "IO::Async::Loop::Select" );
use_ok( "IO::Async::Loop::Poll" );

use_ok( "IO::Async::Test" );

use_ok( "IO::Async::Function" );
use_ok( "IO::Async::DetachedCode" );

use_ok( "IO::Async::Resolver" );
use_ok( "IO::Async::Connector" );

use_ok( "IO::Async::Protocol" );
use_ok( "IO::Async::Protocol::Stream" );
use_ok( "IO::Async::Protocol::LineStream" );
