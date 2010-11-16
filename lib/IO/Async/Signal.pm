#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2009-2010 -- leonerd@leonerd.org.uk

package IO::Async::Signal;

use strict;
use warnings;
use base qw( IO::Async::Notifier );

our $VERSION = '0.31';

use Carp;

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

This subclass of L<IO::Async::Notifier> invokes its callback when a particular
POSIX signal is received.

Multiple objects can be added to a C<Loop> that all watch for the same signal.
The callback functions will all be invoked, in no particular order.

This object may be used in one of two ways; as an instance with CODE
references as callbacks, or as a base class with overridden methods.

=over 4

=item Subclassing

If a subclass is built, then it can override the following methods to handle
events:

 $self->on_receipt()

=back

=cut

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>:

=over 8

=item name => STRING

The name of the signal to watch. This should be a bare name like C<TERM>. Can
only be given at construction time.

=item on_receipt => CODE

CODE reference to callback to invoke when the signal is received. If not
supplied, the subclass method will be called instead.

 $on_receipt->( $self )

=back

Once constructed, the C<Signal> will need to be added to the C<Loop> before it
will work.

=cut

sub _init
{
   my $self = shift;
   my ( $params ) = @_;

   my $name = delete $params->{name} or croak "Expected 'name'";

   $name =~ s/^SIG//; # Trim a leading "SIG"

   $self->{name} = $name;

   $self->SUPER::_init( $params );
}

sub configure
{
   my $self = shift;
   my %params = @_;

   if( exists $params{on_receipt} ) {
      $self->{on_receipt} = delete $params{on_receipt};

      undef $self->{cb}; # Will be lazily constructed when needed

      if( my $loop = $self->get_loop ) {
         $self->_remove_from_loop( $loop );
         $self->_add_to_loop( $loop );
      }
   }

   if( !$self->{on_receipt} and !$self->can( 'on_receipt' ) ) {
      croak 'Expected either a on_receipt callback or an ->on_receipt method';
   }

   $self->SUPER::configure( %params );
}

sub _add_to_loop
{
   my $self = shift;
   my ( $loop ) = @_;

   $self->{cb} ||= $self->{on_receipt} ?
      $self->_capture_weakself( $self->{on_receipt} ) :
      $self->_capture_weakself( 'on_receipt' );

   $self->{id} = $loop->attach_signal( $self->{name}, $self->{cb} );
}

sub _remove_from_loop
{
   my $self = shift;
   my ( $loop ) = @_;

   $loop->detach_signal( $self->{name}, $self->{id} );
   undef $self->{id};
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
