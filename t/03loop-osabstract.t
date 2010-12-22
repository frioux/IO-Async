#!/usr/bin/perl -w

use strict;

use Test::More tests => 29;

use IO::Async::Loop::Poll;

use Socket qw( AF_INET SOCK_STREAM SOCK_DGRAM );

use POSIX qw( SIGTERM );

use Time::HiRes qw( time );

my $loop = IO::Async::Loop::Poll->new();

foreach my $family ( undef, AF_INET ) {
   my ( $S1, $S2 ) = $loop->socketpair( $family, SOCK_STREAM )
      or die "Could not socketpair - $!";

   isa_ok( $S1, "IO::Socket", '$S1 isa IO::Socket' );
   isa_ok( $S2, "IO::Socket", '$S2 isa IO::Socket' );

   # Due to a bug in IO::Socket, this may not be set
   SKIP: {
      skip "IO::Socket doesn't set ->socktype of ->accept'ed sockets", 2 if defined $family;

      is( $S1->socktype, SOCK_STREAM, '$S1->socktype is SOCK_STREAM' );
      is( $S2->socktype, SOCK_STREAM, '$S2->socktype is SOCK_STREAM' );
   }

   $S1->syswrite( "Hello" );
   is( do { my $b; $S2->sysread( $b, 8192 ); $b }, "Hello", '$S1 --writes-> $S2' );

   $S2->syswrite( "Goodbye" );
   is( do { my $b; $S1->sysread( $b, 8192 ); $b }, "Goodbye", '$S2 --writes-> $S1' );

   ( $S1, $S2 ) = $loop->socketpair( $family, SOCK_DGRAM )
      or die "Could not socketpair - $!";

   isa_ok( $S1, "IO::Socket", '$S1 isa IO::Socket' );
   isa_ok( $S2, "IO::Socket", '$S2 isa IO::Socket' );

   is( $S1->socktype, SOCK_DGRAM, '$S1->socktype is SOCK_DGRAM' );
   is( $S2->socktype, SOCK_DGRAM, '$S2->socktype is SOCK_DGRAM' );

   $S1->syswrite( "Hello" );
   is( do { my $b; $S2->sysread( $b, 8192 ); $b }, "Hello", '$S1 --writes-> $S2' );

   $S2->syswrite( "Goodbye" );
   is( do { my $b; $S1->sysread( $b, 8192 ); $b }, "Goodbye", '$S2 --writes-> $S1' );
}

{
   my ( $Prd, $Pwr ) = $loop->pipepair() or die "Could not pipepair - $!";

   $Pwr->syswrite( "Hello" );
   is( do { my $b; $Prd->sysread( $b, 8192 ); $b }, "Hello", '$Pwr --writes-> $Prd' );

   # Writing to $Prd _may_ fail, but some systems might implement this as a
   # socketpair instead. We won't test it just in case
}

{
   my ( $rdA, $wrA, $rdB, $wrB ) = $loop->pipequad() or die "Could not pipequad - $!";

   $wrA->syswrite( "Hello" );
   is( do { my $b; $rdA->sysread( $b, 8192 ); $b }, "Hello", '$wrA --writes-> $rdA' );

   $wrB->syswrite( "Goodbye" );
   is( do { my $b; $rdB->sysread( $b, 8192 ); $b }, "Goodbye", '$wrB --writes-> $rdB' );
}

is( $loop->signame2num( 'TERM' ), SIGTERM, '$loop->signame2num' );

cmp_ok( $loop->time - time, "<", 0.1, '$loop->time gives the current time' );
