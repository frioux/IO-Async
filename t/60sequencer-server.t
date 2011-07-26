#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 14;

use IO::Async::Loop;

use IO::Async::Sequencer;

my $loop = IO::Async::Loop->new;

my ( $S1, $S2 ) = $loop->socketpair or die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

testing_loop( $loop );

my @requests;

my $sequencer = IO::Async::Sequencer->new(
   handle => $S1,

   marshall_response => sub {
      my ( $self, $resp ) = @_;
      return "RESP:$resp\n";
   },

   on_read => sub {
      my ( $self, $buffref, $eof ) = @_;
      return 0 unless $$buffref =~ s/^(.*)\n//;
      $self->incoming_request( $1 ), return 1 if $1 =~ m/^REQ:(.*)$/;
   },

   on_request => sub { 
      my ( $self, $token, $request ) = @_;
      push @requests, [ $token, $request ];
   },
);

ok( defined $sequencer, 'defined $sequencer' );
isa_ok( $sequencer, "IO::Async::Sequencer", '$sequencer isa IO::Async::Sequencer' );

$loop->add( $sequencer );

$S2->syswrite( "REQ:hello\n" );

wait_for { @requests == 1 };

is( $requests[0]->[1], "hello", 'First request' );

$sequencer->respond( $requests[0]->[0], "hello" );

my $clientbuffer = "";

wait_for_stream { $clientbuffer =~ m/\n/ } $S2 => $clientbuffer;

is( $clientbuffer, "RESP:hello\n", 'Client buffer after first response' );

$S2->syswrite( "REQ:zero\nREQ:one\n" );

undef @requests;

wait_for { @requests == 2 };

# Check they're in the right order
is( $requests[0]->[1], "zero", 'Request[0] of ordered pair' );
is( $requests[1]->[1], "one",  'Request[1] of ordered pair' );

# Respond in order for now
$sequencer->respond( $requests[0]->[0], "0" );
$sequencer->respond( $requests[1]->[0], "1" );

$clientbuffer = "";

wait_for_stream { $clientbuffer =~ m/\n.*\n/ } $S2 => $clientbuffer;

is( $clientbuffer, "RESP:0\nRESP:1\n", 'Client buffer after ordered pair' );

# Now we'll see how it copes with out-of-order responses
$S2->syswrite( "REQ:two\nREQ:three\n" );

wait_for { @requests == 4 };

# Check they're in the right order
is( $requests[2]->[1], "two",   'Request[2] of unordered pair' );
is( $requests[3]->[1], "three", 'Request[3] of unordered pair' );

# Respond out of order
$sequencer->respond( $requests[3]->[0], "3" );
$sequencer->respond( $requests[2]->[0], "2" );

$clientbuffer = "";

wait_for_stream { $clientbuffer =~ m/\n.*\n/ } $S2 => $clientbuffer;

# Check these come back right
is( $clientbuffer, "RESP:2\nRESP:3\n", 'Client buffer after unordered pair' );

$loop->remove( $sequencer );

# And now try out the subclassing behaviour

$sequencer = Test::Sequencer->new(
   handle => $S1,
);

ok( defined $sequencer, 'defined $sequencer' );
isa_ok( $sequencer, "IO::Async::Sequencer", '$sequencer isa IO::Async::Sequencer' );

$loop->add( $sequencer );

$S2->syswrite( "REQUEST:hello\n" );

undef @requests;
wait_for { @requests == 1 };

is( $requests[0]->[1], "hello", 'Request in subclass' );

$sequencer->respond( $requests[0]->[0], "hello" );

$clientbuffer = "";
wait_for_stream { $clientbuffer =~ m/\n/ } $S2 => $clientbuffer;

is( $clientbuffer, "RESPONSE:hello\n", 'Client buffer after response in subclass' );

exit 0;

package Test::Sequencer;

use strict;
use base qw( IO::Async::Sequencer );

sub on_read
{
   my $self = shift;
   my ( $buffref, $eof ) = @_;

   return 0 unless $$buffref =~ s/^(.*)\n//;
   $self->incoming_request( $1 ), return 1 if $1 =~ m/^REQUEST:(.*)$/;
   die;
}

sub on_request
{
   my $self = shift;
   my ( $token, $request ) = @_;

   push @requests, [ $token, $request ];
}

sub marshall_response
{
   my $self = shift;
   my ( $resp ) = @_;
   return "RESPONSE:$resp\n";
}

1;
