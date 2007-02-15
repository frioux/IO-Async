#!/usr/bin/perl -w

use strict;
use Test::More tests => 4;

use_ok( "IO::Async::Notifier" );
use_ok( "IO::Async::Buffer" );

use_ok( "IO::Async::Set::Select" );
use_ok( "IO::Async::Set::IO_Poll" );
