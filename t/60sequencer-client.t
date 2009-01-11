#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 21;

use IO::Async::Loop;

use IO::Async::Sequencer;

my $loop = IO::Async::Loop->new;

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

testing_loop( $loop );

my $sequencer = IO::Async::Sequencer->new(
   handle => $S1,

   marshall_request => sub {
      my ( $self, $req ) = @_;
      return "REQ:$req\n";
   },

   on_read => sub {
      my ( $self, $buffref, $closed ) = @_;
      return 0 unless $$buffref =~ s/^(.*)\n//;
      $self->incoming_response( $1 ), return 1 if $1 =~ m/^RESP:(.*)$/;
      # TODO: $self->incoming_response_error( "Response line did not begin 'RESP:'" ), return undef;
   },
);

ok( defined $sequencer, 'defined $sequencer' );
isa_ok( $sequencer, "IO::Async::Sequencer", '$sequencer isa IO::Async::Sequencer' );

$loop->add( $sequencer );

my $response;

$sequencer->request(
   request => "hello",
   on_response => sub { ( $response ) = @_ },
);

my $serverbuffer = "";

wait_for_stream { $serverbuffer =~ m/\n/ } $S2 => $serverbuffer;

is( $serverbuffer, "REQ:hello\n", 'Server buffer after first request' );

$S2->syswrite( "RESP:hello\n" );

wait_for { defined $response };

is( $response, "hello", 'Response to first request' );

# Can it do two at once?

my @response;

$sequencer->request(
   request => "zero",
   on_response => sub { ( $response[0] ) = @_ },
);

$sequencer->request(
   request => "one",
   on_response => sub { ( $response[1] ) = @_ },
);

$serverbuffer = "";

wait_for_stream { $serverbuffer =~ m/\n.*\n/ } $S2 => $serverbuffer; # Wait for both requests

# Check they're in order
is( $serverbuffer, "REQ:zero\nREQ:one\n", 'Server buffer after ordered pair' );

$S2->syswrite( "RESP:0\nRESP:1\n" );

wait_for { defined $response[0] and defined $response[1] };

is( $response[0], "0", 'Response to [0] of ordered pair' );
is( $response[1], "1", 'Response to [1] of ordered pair' );

$loop->remove( $sequencer );

# Now lets try passing on_read to each call instead

$sequencer = IO::Async::Sequencer->new(
   handle => $S1,

   on_read => sub {
      # Since we expect the requests always to provide one, this ought not be
      # invoked
      die "Test died early";
   },

   marshall_request => sub {
      my ( $self, $req ) = @_;
      return "GET $req\n";
   },
);

$loop->add( $sequencer );

my $line;

$sequencer->request(
   request => "hello",
   on_read => sub {
      my ( $self, $buffref, $closed ) = @_;
      return 0 unless $$buffref =~ s/^(.*)\n//;
      $line = $1;
      return undef;
   },
);

$serverbuffer = "";

wait_for_stream { $serverbuffer =~ m/\n/ } $S2 => $serverbuffer;

is( $serverbuffer, "GET hello\n", 'Server buffer after on_read-provided request' );

$S2->syswrite( "Your thing here\n" );

wait_for { defined $line };

is( $line, "Your thing here", 'Client response after reply to on_read' );

$loop->remove( $sequencer );

# Disable pipelining

$sequencer = IO::Async::Sequencer->new(
   handle => $S1,

   pipeline => 0,

   marshall_request => sub {
      my ( $self, $req ) = @_;
      return "REQ:$req\n";
   },

   on_read => sub {
      my ( $self, $buffref, $closed ) = @_;
      return 0 unless $$buffref =~ s/^(.*)\n//;
      $self->incoming_response( $1 ), return 1 if $1 =~ m/^RESP:(.*)$/;
   },
);

$loop->add( $sequencer );

$sequencer->request(
   request => "two",
   on_response => sub { ( $response[2] ) = @_ },
);

$sequencer->request(
   request => "three",
   on_response => sub { ( $response[3] ) = @_ },
);

$serverbuffer = "";
wait_for_stream { $serverbuffer =~ m/\n/ } $S2 => $serverbuffer;

# By now we hope that only one request has been written... But we can't really
# know for sure yet if second one is just hanging about in kernelland
# somewhere. For this we'll force a new byte down the socket, and wait for it
# to pop out again, as an "end guard"

$S1->syswrite( "\0" );

wait_for_stream { $serverbuffer =~ m/\0/ } $S2 => $serverbuffer;

is( $serverbuffer, "REQ:two\n\0", 'Server buffer after two non-pipelined requests' );

$S2->syswrite( "RESP:2\n" );

wait_for { defined $response[2] };

is( $response[2], "2", 'Response to [2] of non-pipeline' );

$serverbuffer = "";
wait_for_stream { $serverbuffer =~ m/\n/ } $S2 => $serverbuffer;

is( $serverbuffer, "REQ:three\n", 'Server buffer after second of two non-pipelined requests' );

$S2->syswrite( "RESP:3\n" );

wait_for { defined $response[3] };

is( $response[3], "3", 'Response to [3] of non-pipeline' );

$sequencer->request(
   request => "four",
   on_read => sub {
      my ( $self, $buffref, $closed ) = @_;
      return 0 unless $$buffref =~ s/^(.*)\n//;
      $response[4] = $1, return undef if $1 =~ m/^RESP:(.*)$/;
      die;
   },
);

$sequencer->request(
   request => "five",
   on_read => sub {
      my ( $self, $buffref, $closed ) = @_;
      return 0 unless $$buffref =~ s/^(.*)\n//;
      $response[5] = $1, return undef if $1 =~ m/^RESP:(.*)$/;
      die;
   },
);

$serverbuffer = "";
wait_for_stream { $serverbuffer =~ m/\n/ } $S2 => $serverbuffer;

is( $serverbuffer, "REQ:four\n", 'Server buffer first of two non-pipelined requests with on_read delegation' );

$S2->syswrite( "RESP:4\n" );

wait_for { defined $response[4] };

is( $response[4], "4", 'Response to [4] of non-pipeline with on_read delegation' );

$serverbuffer = "";
wait_for_stream { $serverbuffer =~ m/\n/ } $S2 => $serverbuffer;

is( $serverbuffer, "REQ:five\n", 'Server buffer second of two non-pipelined requests with on_read delegation' );

$S2->syswrite( "RESP:5\n" );

wait_for { defined $response[5] };

is( $response[5], "5", 'Response to [5] of non-pipeline with on_read delegation' );

$loop->remove( $sequencer );

# And now try out the subclassing behaviour

$sequencer = Test::Sequencer->new(
   handle => $S1,
);

ok( defined $sequencer, 'defined $sequencer' );
isa_ok( $sequencer, "IO::Async::Sequencer", '$sequencer isa IO::Async::Sequencer' );

$loop->add( $sequencer );

$sequencer->request(
   request => "hello",
   on_response => sub { ( $response ) = @_ },
);

$serverbuffer = "";
wait_for_stream { $serverbuffer =~ m/\n/ } $S2 => $serverbuffer;

is( $serverbuffer, "REQUEST:hello\n", 'Server buffer after request in subclass' );

$S2->syswrite( "RESPONSE:hello\n" );

undef $response;
wait_for { defined $response };

is( $response, "hello", 'Response to request in subclass' );

exit 0;

package Test::Sequencer;

use strict;
use base qw( IO::Async::Sequencer );

sub on_read
{
   my $self = shift;
   my ( $buffref, $closed ) = @_;

   return 0 unless $$buffref =~ s/^(.*)\n//;
   $self->incoming_response( $1 ), return 1 if $1 =~ m/^RESPONSE:(.*)$/;
   die;
}

sub marshall_request
{
   my $self = shift;
   my ( $req ) = @_;
   return "REQUEST:$req\n";
}

1;
