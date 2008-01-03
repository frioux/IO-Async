#!/usr/bin/perl -w

use strict;
use Test::More tests => 10;

use_ok( "IO::Async::Notifier" );
use_ok( "IO::Async::TimeQueue" );
use_ok( "IO::Async::MergePoint" );
use_ok( "IO::Async::Stream" );
use_ok( "IO::Async::SignalProxy" );

use_ok( "IO::Async::Loop::Select" );
use_ok( "IO::Async::Loop::IO_Poll" );
use_ok( "IO::Async::Loop::Glib" );

use_ok( "IO::Async::ChildManager" );
use_ok( "IO::Async::DetachedCode" );
