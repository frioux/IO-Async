#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007-2011 -- leonerd@leonerd.org.uk

package IO::Async::DetachedCode;

use strict;
use warnings;

our $VERSION = '0.39';

use Carp;

use IO::Async::Function;

=head1 NAME

C<IO::Async::DetachedCode> - execute code asynchronously in child processes

=head1 SYNOPSIS

This object is used indirectly via the C<IO::Async::Loop>'s C<detach_code>
method.

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();

 my $code = $loop->detach_code(
    code => sub {
       my ( $number ) = @_;
       return is_prime( $number );
    }
 );

 $code->call(
    args => [ 123454321 ],
    on_return => sub {
       my $isprime = shift;
       print "123454321 " . ( $isprime ? "is" : "is not" ) . " a prime number\n";
    },
    on_error => sub {
       print STDERR "Cannot determine if it's prime - $_[0]\n";
    },
 );

 $loop->loop_forever;

=head1 DESCRIPTION

This object class provides a legacy compatibility layer for existing code
that tries to construct such an object. It should not be used for new code;
see instead the L<IO::Async::Function> object, for which this is now a
wrapper.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $code = $loop->detach_code( %params )

This function returns a new instance of a C<IO::Async::DetachedCode> object.
The C<%params> hash takes the following keys:

=over 8

=item code => CODE

A block of code to call in the child process. 

=item stream

=item marshaller

These arguments are no longer used; any values passed will be ignored.

=item workers => INT

Optional integer, specifies the number of parallel workers to create.

If not supplied, 1 is used.

=item exit_on_die => BOOL

=item setup => ARRAY

Passed through to the underlying C<IO::Async::Function> object.

=back

=cut

sub new
{
   my $class = shift;
   my ( %params ) = @_;

   my $loop = delete $params{loop} or croak "Expected a 'loop'";

   # No-longer supported args
   delete $params{marshaller};
   delete $params{stream};

   my $workers = delete $params{workers} || 1;

   my $function = IO::Async::Function->new(
      min_workers => $workers,
      max_workers => $workers,
      %params,
   );

   $loop->add( $function );

   return bless {
      function => $function,
   }, $class;
}

sub DESTROY
{
   my $self = shift;

   my $function = $self->{function};
   $function->get_loop->remove( $function );
}

=head1 METHODS

=cut

=head2 $code->call( %params )

Calls one invocation of the contained function code block. See the C<call>
method on C<IO::Async::Function> for more detail.

=cut

sub call
{
   my $self = shift;
   $self->{function}->call( @_ );
}

=head2 $code->shutdown

This method requests that the detached worker processes stop running.

=cut

sub shutdown
{
   my $self = shift;
   $self->{function}->stop;
}

=head2 $n_workers = $code->workers

This method in scalar context returns the number of workers currently running.

=head2 @worker_pids = $code->workers

This method in list context returns a list of the PID numbers of all the
currently running worker processes.

=cut

sub workers
{
   my $self = shift;

   # Lots of cheating here
   # Works in scalar or list
   return keys %{ $self->{function}{workers} };
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
