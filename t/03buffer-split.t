#!/usr/bin/perl -w

use strict;

use Test::More tests => 3;

use POSIX qw( EAGAIN );
use IO::Socket::UNIX;

use IO::Async::Buffer;

# 4 ends of sockets:
#  test => notifier ; notifier => test
#  S[0]    S[1]       S[2]        S[3]

my @S;
@S[0,1] = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";
@S[2,3] = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
   die "Cannot create socket pair - $!";

# Want all pipes to be nonblocking, autoflushing
for ( @S ) {
   $_->blocking( 0 );
   $_->autoflush( 1 );
}

sub read_data($)
{
   my ( $s ) = @_;

   my $buffer;
   my $ret = sysread( $s, $buffer, 8192 );

   return $buffer if( defined $ret && $ret > 0 );
   die "Socket closed" if( defined $ret && $ret == 0 );
   return "" if( $! == EAGAIN );
   die "Cannot sysread() - $!";
}

my $incoming_buffer = "";
sub on_read
{
   my $self = shift;
   my ( $buffref, $buffclosed ) = @_;

   $incoming_buffer .= $$buffref;
   $$buffref = "";

   return 0;
}

my $buff = IO::Async::Buffer->new(
   read_handle  => $S[1],
   write_handle => $S[2],
   on_read => \&on_read,
);

# Writing
$buff->write( "message\n" );
$buff->on_write_ready;

is( read_data( $S[3] ), "message\n", '$S[3] receives data' );
is( read_data( $S[0] ), "",          '$S[0] empty' );

# Receiving
$S[0]->syswrite( "another message\n" );
# Reverse push - should be ignored
$S[3]->syswrite( "reverse\n" );

$buff->on_read_ready;

is( $incoming_buffer, "another message\n", 'incoming buffer contains message' );
