#!/usr/bin/perl -w

use strict;

use Test::More tests => 83;
use Test::Exception;

use IO::Async::ChildManager;

use File::Temp qw( tmpnam );
use POSIX qw( WIFEXITED WEXITSTATUS ENOENT EBADF );

use IO::Async::Set::IO_Poll;

my $manager = IO::Async::ChildManager->new();

my $set = IO::Async::Set::IO_Poll->new();
$set->enable_childmanager;

$manager = $set->get_childmanager;

dies_ok( sub { $manager->spawn( code => sub { 1 }, setup => "hello" ); },
         'Bad setup type fails' );

dies_ok( sub { $manager->spawn( code => sub { 1 }, setup => [ 'somerandomthing' => 1 ] ); },
         'Setup with bad key fails' );

# These tests are all very similar looking, with slightly different start and
# code values. Easiest to wrap them up in a common testing wrapper.

sub TEST
{
   my ( $name, %attr ) = @_;

   my $exitcode;
   my $dollarbang;
   my $dollarat;

   $manager->spawn(
      code => $attr{code},
      exists $attr{setup} ? ( setup => $attr{setup} ) : (),
      on_exit => sub { ( undef, $exitcode, $dollarbang, $dollarat ) = @_; },
   );

   my $ready = 0;

   while( !defined $exitcode ) {
      $_ = $set->loop_once( 2 ); # Give code a generous 2 seconds to exit
      die "Nothing was ready after 2 second wait" if $_ == 0;
      $ready += $_;
   }

   if( exists $attr{ready} ) {
      cmp_ok( $ready, '>=', $attr{ready}, "\$ready after $name" );
   }

   if( exists $attr{exitstatus} ) {
      ok( WIFEXITED($exitcode), "WIFEXITED(\$exitcode) after $name" );
      is( WEXITSTATUS($exitcode), $attr{exitstatus}, "WEXITSTATUS(\$exitcode) after $name" );
   }

   if( exists $attr{dollarbang} ) {
      is( $dollarbang+0, $attr{dollarbang}, "\$dollarbang numerically after $name" );
   }

   if( exists $attr{dollarat} ) {
      is( $dollarat, $attr{dollarat}, "\$dollarat after $name" );
   }
}

# A useful utility function like blocking read() with a timeout
sub read_timeout
{
   my ( $fh, undef, $len, $timeout ) = @_;

   my $rvec = '';
   vec( $rvec, fileno $fh, 1 ) = 1;

   select( $rvec, undef, undef, $timeout );

   return undef if !vec( $rvec, fileno $fh, 1 );

   return $fh->read( $_[1], $len );
}

my $buffer;
my $ret;

{
   pipe( my( $pipe_r, $pipe_w ) ) or die "Cannot pipe() - $!";

   TEST "pipe dup to fd1",
      setup => [ fd1 => [ 'dup', $pipe_w ] ],
      code => sub { print "test"; },

      ready      => 3,
      exitstatus => 1,
      dollarat   => '';

   undef $buffer;
   $ret = read_timeout( $pipe_r, $buffer, 4, 0.1 );

   is( $ret, 4,         '$pipe_r->read() after pipe dup to fd1' );
   is( $buffer, 'test', '$buffer after pipe dup to fd1' );

   TEST "pipe dup to stdout shortcut",
      setup => [ stdout => $pipe_w ],
      code => sub { print "test"; },

      ready      => 3,
      exitstatus => 1,
      dollarat   => '';

   undef $buffer;
   $ret = read_timeout( $pipe_r, $buffer, 4, 0.1 );

   is( $ret, 4,         '$pipe_r->read() after pipe dup to stdout shortcut' );
   is( $buffer, 'test', '$buffer after pipe dup to stdout shortcut' );

   TEST "pipe dup to stdout",
      setup => [ stdout => [ 'dup', $pipe_w ] ],
      code => sub { print "test"; },

      ready      => 3,
      exitstatus => 1,
      dollarat   => '';

   undef $buffer;
   $ret = read_timeout( $pipe_r, $buffer, 4, 0.1 );

   is( $ret, 4,         '$pipe_r->read() after pipe dup to stdout' );
   is( $buffer, 'test', '$buffer after pipe dup to stdout' );

   TEST "pipe dup to fd2",
      setup => [ fd2 => [ 'dup', $pipe_w ] ],
      code => sub { print STDERR "test"; },

      ready      => 3,
      exitstatus => 1,
      dollarat   => '';

   undef $buffer;
   $ret = read_timeout( $pipe_r, $buffer, 4, 0.1 );

   is( $ret, 4,         '$pipe_r->read() after pipe dup to fd2' );
   is( $buffer, 'test', '$buffer after pipe dup to fd2' );

   TEST "pipe dup to stderr",
      setup => [ stderr => [ 'dup', $pipe_w ] ],
      code => sub { print STDERR "test"; },

      ready      => 3,
      exitstatus => 1,
      dollarat   => '';

   undef $buffer;
   $ret = read_timeout( $pipe_r, $buffer, 4, 0.1 );

   is( $ret, 4,         '$pipe_r->read() after pipe dup to stderr' );
   is( $buffer, 'test', '$buffer after pipe dup to stderr' );

   TEST "pipe dup to other FD",
      setup => [ fd4 => [ 'dup', $pipe_w ] ],
      code => sub { 
         close STDOUT;
         open( STDOUT, ">&=4" ) or die "Cannot open fd4 as stdout - $!";
         print "test";
      },

      ready      => 3,
      exitstatus => 1,
      dollarat   => '';

   undef $buffer;
   $ret = read_timeout( $pipe_r, $buffer, 4, 0.1 );

   is( $ret, 4,         '$pipe_r->read() after pipe dup to stderr' );
   is( $buffer, 'test', '$buffer after pipe dup to stderr' );

   TEST "other FD close",
      code => sub { return $pipe_w->syswrite( "test" ); },

      ready      => 3,
      exitstatus => 255,
      dollarbang => EBADF,
      dollarat   => '';

   # Try to force a writepipe clash by asking to dup the pipe to lots of FDs
   TEST "writepipe clash",
      code => sub { print "test"; },
      setup => [ map { +"fd$_" => $pipe_w } ( 1 .. 19 ) ],

      ready      => 3,
      exitstatus => 1,
      dollarat   => '';

   undef $buffer;
   $ret = read_timeout( $pipe_r, $buffer, 4, 0.1 );

   is( $ret, 4,         '$pipe_r->read() after writepipe clash' );
   is( $buffer, 'test', '$buffer after writepipe clash' );

   pipe( my( $pipe2_r, $pipe2_w ) ) or die "Cannot pipe() - $!";
   $pipe2_r->blocking( 0 );

   TEST "pipe dup to stdout and stderr",
      setup => [ stdout => $pipe_w, stderr => $pipe2_w ],
      code => sub { print "output"; print STDERR "error"; },

      ready      => 3,
      exitstatus => 1,
      dollarat   => '';

   undef $buffer;
   $ret = read_timeout( $pipe_r, $buffer, 6, 0.1 );

   is( $ret, 6,           '$pipe_r->read() after pipe dup to stdout and stderr' );
   is( $buffer, 'output', '$buffer after pipe dup to stdout and stderr' );

   undef $buffer;
   $ret = read_timeout( $pipe2_r, $buffer, 5, 0.1 );

   is( $ret, 5,          '$pipe2_r->read() after pipe dup to stdout and stderr' );
   is( $buffer, 'error', '$buffer after pipe dup to stdout and stderr' );
}

TEST "stdout close",
   setup => [ stdout => [ 'close' ] ],
   code => sub { print "test"; },

   ready      => 3,
   exitstatus => 255,
   dollarbang => EBADF,
   dollarat   => '';

{
   my $name = tmpnam();

   TEST "stdout open",
      setup => [ stdout => [ 'open', '>', $name ] ],
      code => sub { print "test"; },

      ready      => 3,
      exitstatus => 1,
      dollarat   => '';

   ok( -f $name, 'tmpnam file exists after stdout open' );

   open( my $tmpfh, "<", $name ) or die "Cannot open '$name' for reading - $!";

   undef $buffer;
   $ret = read_timeout( $tmpfh, $buffer, 4, 0.1 );

   is( $ret, 4,         '$tmpfh->read() after stdout open' );
   is( $buffer, 'test', '$buffer after stdout open' );

   TEST "stdout open append",
      setup => [ stdout => [ 'open', '>>', $name ] ],
      code => sub { print "value"; },

      ready      => 3,
      exitstatus => 1,
      dollarat   => '';

   seek( $tmpfh, 0, 0 );

   undef $buffer;
   $ret = read_timeout( $tmpfh, $buffer, 9, 0.1 );

   is( $ret, 9,              '$tmpfh->read() after stdout open append' );
   is( $buffer, 'testvalue', '$buffer after stdout open append' );
}

$ENV{TESTKEY} = "parent value";

TEST "environment is preserved",
   setup => [],
   code => sub { return $ENV{TESTKEY} eq "parent value" ? 0 : 1 },

   ready      => 3,
   exitstatus => 0,
   dollarat   => '';

TEST "environment is overwritten",
   setup => [ env => { TESTKEY => "child value" } ],
   code => sub { return $ENV{TESTKEY} eq "child value" ? 0 : 1 },

   ready      => 3,
   exitstatus => 0,
   dollarat   => '';
