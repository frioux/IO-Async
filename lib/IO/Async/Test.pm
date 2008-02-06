#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007,2008 -- leonerd@leonerd.org.uk

package IO::Async::Test;

use strict;

our $VERSION = '0.12';

use Exporter;
our @ISA = qw( Exporter );
our @EXPORT = qw(
   testing_loop
   wait_for
);

=head1 NAME

C<IO::Async::Test> - Utility functions for use in test scripts

=head1 SYNOPSIS

 use Test::More tests => 1;
 use IO::Async::Test;

 use IO::Async::Loop::...

 my $loop = IO::Async::Loop::...->new( ... );
 testing_loop( $loop );

 my $result;

 $loop->do_something( 
    some => args,

    on_done => sub {
       $result = the_outcome;
    }
 );

 wait_for { defined $result };

 is( $result, what_we_expected, 'The event happened' );

=head1 DESCRIPTION

This module provides utility functions that may be useful when writing test
scripts for code which uses C<IO::Async> (as well as being used in the
C<IO::Async> test scripts themselves).

Test scripts are often synchronous by nature; they are a linear sequence of
actions to perform, interspersed with assertions which check for given
conditions. This goes against the very nature of C<IO::Async> which, being an
asynchronisation framework, does not provide a linear stepped way of working.

In order to write a test, the C<wait_for()> function provides a way of
synchronising the code, so that a given condition is known to hold, which
would typically signify that some event has occured, the outcome of which can
now be tested using the usual testing primitives.

=cut

my $loop;

=head1 FUNCTIONS

=cut

=head2 testing_loop( $loop )

Set the C<IO::Async::Loop> object which the C<wait_for()> function will loop
on.

=cut

sub testing_loop
{
   $loop = shift;
}

=head2 wait_for( $condfunc )

Repeatedly call the C<loop_once()> method on the underlying loop (given to the
C<testing_loop()> function), until the given condition function callback
returns true.

To guard against stalled scripts, if the loop indicates a timeout for 10
consequentive seconds, then an error is thrown.

=cut

sub wait_for(&)
{
   my ( $cond ) = @_;

   my ( undef, $callerfile, $callerline ) = caller();

   while( !$cond->() ) {
      my $retries = 10; # Give code a generous 10 seconds to do something
      while( $retries-- ) {
         my $subcount = $loop->loop_once( 1 );
         last if $subcount;

         die "Nothing was ready after 10 second wait; called at $callerfile line $callerline\n" if $retries == 0;
      }
   }
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
