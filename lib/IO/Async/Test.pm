#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007,2008 -- leonerd@leonerd.org.uk

package IO::Async::Test;

use strict;
use warnings;

our $VERSION = '0.25';

use Exporter;
our @ISA = qw( Exporter );
our @EXPORT = qw(
   testing_loop
   wait_for
   wait_for_stream
);

use IO::Async::Stream;

=head1 NAME

C<IO::Async::Test> - utility functions for use in test scripts

=head1 SYNOPSIS

 use Test::More tests => 1;
 use IO::Async::Test;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();
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

 ...

 my $buffer = "";
 my $handle = IO::Handle-> ...

 wait_for_stream { length $buffer >= 10 } $handle => $buffer;

 is( substr( $buffer, 0, 10, "" ), "0123456789", 'Buffer was correct' );

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

Because the primary purpose of C<IO::Async> is to provide IO operations on
filehandles, a great many tests will likely be based around connected pipes or
socket handles. The C<wait_for_stream()> function provides a convenient way
to wait for some content to be written through such a connected stream.

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

   my $timedout = 0;
   my $timerid = $loop->enqueue_timer(
      delay => 10,
      code => sub { $timedout = 1 },
   );

   $loop->loop_once( 1 ) while !$cond->() and !$timedout;

   if( $timedout ) {
      die "Nothing was ready after 10 second wait; called at $callerfile line $callerline\n";
   }
   else {
      $loop->cancel_timer( $timerid );
   }
}

=head2 wait_for_stream( $condfunc, $handle, $buffer )

Set up an C<IO::Async::Stream> object around the given $handle. Data read from
the stream will be appended into $buffer (which is NOT initialised when the
function is entered, in case data remains from a previous call). The
C<loop_once> method is then repeatedly called until the condition function
callback returns true. After this, the temporary stream will be removed from
the loop.

=cut

sub wait_for_stream(&$$)
{
   my ( $cond, $handle, undef ) = @_;
   my $varref = \$_[2]; # So that we can modify it from the on_read callback

   $loop->watch_io(
      handle => $handle,
      on_read_ready => sub {
         my $ret = $handle->sysread( $$varref, 8192, length $$varref );
         if( !defined $ret ) {
            die "Read failed on $handle - $!\n";
         }
         elsif( $ret == 0 ) {
            die "Read returned EOF on $handle\n";
         }
      }
   );

   # Have to defeat the prototype... grr I hate these
   &wait_for( $cond );

   $loop->unwatch_io(
      handle => $handle,
      on_read_ready => 1,
   );
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
