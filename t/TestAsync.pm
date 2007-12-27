package TestAsync;

use strict;

use Exporter;
our @ISA = qw( Exporter );
our @EXPORT = qw(
   testing_loop
   wait_for
);

my $loop;
sub testing_loop
{
   $loop = shift;
}

sub wait_for(&)
{
   my ( $cond ) = @_;

   my $ready = 0;

   my ( undef, $callerfile, $callerline ) = caller();

   while( !$cond->() ) {
      my $retries = 10; # Give code a generous 10 seconds to do something
      while( $retries-- ) {
         my $subcount = $loop->loop_once( 1 );
         $ready += $subcount, last if $subcount;

         die "Nothing was ready after 10 second wait; called at $callerfile line $callerline\n" if $retries == 0;
      }
   }

   $ready;
}

1;
