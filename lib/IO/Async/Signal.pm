#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2009 -- leonerd@leonerd.org.uk

package IO::Async::Signal;

use strict;
use base qw( IO::Async::Notifier );

our $VERSION = '0.20';

use Carp;
use Scalar::Util qw( weaken );

=head1 NAME

C<IO::Async::Signal> - event callback on receipt of a POSIX signal

=head1 SYNOPSIS

 use IO::Async::Signal;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();

 my $signal = IO::Async::Signal->new(
    name => "HUP",

    on_receipt => sub {
        print "I caught SIGHUP\n";
    },
 );

 $loop->add( $signal );

 $loop->loop_forever;

=head1 DESCRIPTION

This module provides a class of C<IO::Async::Notifier> which invokes its
callback when a particular POSIX signal is received.

Multiple objects can be added to a C<Loop> that all watch for the same signal.
The callback functions will all be invoked, in no particular order.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $signal = IO::Async::Signal->new( %params )

This function returns a new instance of a C<IO::Async::Signal> object. The
C<%params> hash takes the following keys:

=over 8

=item name => STRING

The name of the signal to watch. This should be a bare name like C<TERM>.

=item on_receipt => CODE

CODE reference to callback to invoke when the signal is received.

=back

Once constructed, the C<Signal> will need to be added to the C<Loop> before it
will work.

=cut

sub new
{
   my $class = shift;
   my %params = @_;

   my $name = delete $params{name} or croak "Expected 'name'";

   $name =~ s/^SIG//; # Trim a leading "SIG"

   my $on_receipt = delete $params{on_receipt} or croak "Expected 'on_receipt' as a CODE reference";

   my $self = $class->SUPER::new( %params );

   $self->{name} = $name;
   $self->{on_receipt} = $on_receipt;

   return $self;
}

sub _add_to_loop
{
   my $self = shift;
   my ( $loop ) = @_;

   $self->{id} = $loop->attach_signal( $self->{name}, $self->{on_receipt} );
}

sub _remove_from_loop
{
   my $self = shift;
   my ( $loop ) = @_;

   $loop->detach_signal( $self->{name}, $self->{id} );
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
