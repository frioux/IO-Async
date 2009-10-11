#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2009 -- leonerd@leonerd.org.uk

package IO::Async::LoopTests;

use strict;
use warnings;

use base qw( Exporter );
our @EXPORT = qw(
   run_tests
);

use Test::More;
use Test::Refcount;

use IO::Async::Test;

use POSIX qw( SIGTERM WIFEXITED WEXITSTATUS WIFSIGNALED WTERMSIG );

our $VERSION = '0.23';

=head1 NAME

C<IO::Async::LoopTests> - acceptance testing for C<IO::Async::Loop> subclasses

=head1 SYNOPSIS

 TODO

=head1 DESCRIPTION

This module contains a collection of test functions for running acceptance
tests on L<IO::Async::Loop> subclasses. It is provided as a facility for
authors of such subclasses to ensure that the code conforms to the Loop API
required by C<IO::Async>.

=cut

=head1 FUNCTIONS

=cut

=head2 run_tests( $class, @tests )

Runs a test or collection of tests against the loop subclass given. The class
being tested is loaded by this function; the containing script does not need
to C<require> or C<use> it first.

This function runs C<Test::More::plan> to output its expected test count; the
containing script should not do this.

=cut

sub run_tests
{
   my ( $testclass, @tests ) = @_;

   my $count = 0;
   $count += __PACKAGE__->can( "count_tests_$_" )->() for @tests;

   plan tests => $count;

   ( my $file = "$testclass.pm" ) =~ s{::}{/}g;

   eval { require $file };
   if( $@ ) {
      BAIL_OUT( "Unable to load $testclass - $@" );
   }

   __PACKAGE__->can( "run_tests_$_" )->( $testclass ) for @tests;
}

=head1 TEST SUITES

The following test suite names exist, to be passed as a name in the C<@tests>
argument to C<run_tests>:

=cut

=head2 child

Tests the Loop's support for watching child processes by PID

=cut

use constant count_tests_child => 9;
sub run_tests_child
{
   my ( $class ) = @_;

   my $loop = $class->new();
   is_oneref( $loop, '$loop has refcount 1' );

   testing_loop( $loop );
   is_refcount( $loop, 2, '$loop has refcount 2 after adding to IO::Async::Test' );

   my $kid = fork();
   defined $kid or die "Cannot fork() - $!";

   if( $kid == 0 ) {
      exit( 3 );
   }

   my $exitcode;

   $loop->watch_child( $kid => sub { ( undef, $exitcode ) = @_; } );

   is_refcount( $loop, 2, '$loop has refcount 2 after watch_child' );
   ok( !defined $exitcode, '$exitcode not defined before ->loop_once' );

   undef $exitcode;
   wait_for { defined $exitcode };

   ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after child exit' );
   is( WEXITSTATUS($exitcode), 3, 'WEXITSTATUS($exitcode) after child exit' );

   $kid = fork();
   defined $kid or die "Cannot fork() - $!";

   if( $kid == 0 ) {
      sleep( 10 );
      # Just in case the parent died already and didn't kill us
      exit( 0 );
   }

   $loop->watch_child( $kid => sub { ( undef, $exitcode ) = @_; } );

   kill SIGTERM, $kid;

   undef $exitcode;
   wait_for { defined $exitcode };

   ok( WIFSIGNALED($exitcode),          'WIFSIGNALED($exitcode) after SIGTERM' );
   is( WTERMSIG($exitcode),    SIGTERM, 'WTERMSIG($exitcode) after SIGTERM' );

   is_refcount( $loop, 2, '$loop has refcount 2 at EOF' );

   testing_loop( undef );
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
