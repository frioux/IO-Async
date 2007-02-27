#!/usr/bin/perl -w

use strict;
use Test::More tests => 6;

use_ok( "IO::Async::Notifier" );
use_ok( "IO::Async::Buffer" );
use_ok( "IO::Async::SignalProxy" );

use_ok( "IO::Async::Set::Select" );
use_ok( "IO::Async::Set::IO_Poll" );
use_ok( "IO::Async::Set::GMainLoop" );
