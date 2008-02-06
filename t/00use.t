#!/usr/bin/perl -w

use strict;
use Test::More tests => 12;

use_ok( "IO::Async::Notifier" );
use_ok( "IO::Async::TimeQueue" );
use_ok( "IO::Async::MergePoint" );
use_ok( "IO::Async::Stream" );
use_ok( "IO::Async::SignalProxy" );

use_ok( "IO::Async::Loop::Select" );
use_ok( "IO::Async::Loop::IO_Poll" );

use_ok( "IO::Async::Test" );

use_ok( "IO::Async::ChildManager" );
use_ok( "IO::Async::DetachedCode" );
use_ok( "IO::Async::Resolver" );
use_ok( "IO::Async::Connector" );
