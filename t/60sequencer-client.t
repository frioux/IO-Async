#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 9;

use IO::Socket::UNIX;

use IO::Async::Loop::IO_Poll;

use IO::Async::Sequencer;

( my $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my $loop = IO::Async::Loop::IO_Poll->new();

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
ok( $sequencer->isa( "IO::Async::Sequencer" ), '$sequencer isa IO::Async::Sequencer' );

$loop->add( $sequencer );

my $response;

$sequencer->request(
   request => "hello",
   on_response => sub { ( $response ) = @_ },
);

my $serverbuffer = "";

wait_for_stream { $serverbuffer =~ m/\n/ } $S2 => $serverbuffer;

is( $serverbuffer, "REQ:hello\n", 'Server buffer after first request' );

$S2->write( "RESP:hello\n" );

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

$S2->write( "RESP:0\nRESP:1\n" );

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

$S2->write( "Your thing here\n" );

wait_for { defined $line };

is( $line, "Your thing here", 'Client response after reply to on_read' );
