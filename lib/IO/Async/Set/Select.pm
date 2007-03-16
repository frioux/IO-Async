#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007 -- leonerd@leonerd.org.uk

package IO::Async::Set::Select;

use strict;

our $VERSION = '0.04';

use base qw( IO::Async::Set );

use Carp;

=head1 NAME

C<IO::Async::Set::Select> - a class that maintains a set of
C<IO::Async::Notifier> objects by using the C<select()> syscall.

=head1 SYNOPSIS

 use IO::Async::Set::Select;

 my $set = IO::Async::Set::Select->new();

 $set->add( ... );

 while(1) {
    my ( $rvec, $wvec, $evec ) = ('') x 3;
    my $timeout;

    $set->pre_select( \$rvec, \$wvec, \$evec, \$timeout );
    ...
    my $ret = select( $rvec, $wvec, $evec, $timeout );
    ...
    $set->post_select( $rvec, $evec, $wvec );
 }

=head1 DESCRIPTION

This subclass of C<IO::Async::Notifier> uses the C<select()> syscall to
perform read-ready and write-ready tests.

To integrate with an existing C<select()>-based event loop, a pair of methods
C<pre_select()> and C<post_select()> can be called immediately before and
after a C<select()> call. The relevant bit in the read-ready bitvector is
always set by the C<pre_select()> method, but the corresponding bit in
write-ready vector is set depending on the state of the C<'want_writeready'>
property. The C<post_select()> method will invoke the C<on_read_ready()> or
C<on_write_ready()> methods or callbacks as appropriate.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $set = IO::Async::Set::Select->new()

This function returns a new instance of a C<IO::Async::Set::Select> object.
It takes no special arguments.

=cut

sub new
{
   my $class = shift;
   return $class->__new( @_ );
}

=head1 METHODS

=cut

=head2 $set->pre_select( \$readvec, \$writevec, \$exceptvec, \$timeout )

This method prepares the bitvectors for a C<select()> call, setting the bits
that notifiers registered by this set are interested in. It will always set
the appropriate bits in the read vector, but will only set them in the write
vector if the notifier's C<want_writeready()> property is true. Neither the
exception vector nor the timeout are affected.

=over 8

=item \$readvec

=item \$writevec

=item \$exceptvec

Scalar references to the reading, writing and exception bitvectors

=item \$timeout

Scalar reference to the timeout value

=back

=cut

sub pre_select
{
   my $self = shift;
   my ( $readref, $writeref, $exceptref, $timeref ) = @_;

   my $notifiers = $self->{notifiers};

   foreach my $nkey ( keys %$notifiers ) {
      my $notifier = $notifiers->{$nkey};

      vec( $$readref, $notifier->read_fileno, 1 ) = 1;

      vec( $$writeref, $notifier->write_fileno, 1 ) = 1 if( $notifier->want_writeready );
   }

   return;
}

=head2 $set->post_select( $readvec, $writevec, $exceptvec )

This method checks the returned bitvectors from a C<select()> call, and calls
any of the notification methods or callbacks that are appropriate.

=over 8

=item $readvec

=item $writevec

=item $exceptvec

Scalars containing the read-ready, write-ready and exception bitvectors

=back

=cut

sub post_select
{
   my $self = shift;
   my ( $readvec, $writevec, $exceptvec ) = @_;

   my $notifiers = $self->{notifiers};
   foreach my $nkey ( keys %$notifiers ) {
      my $notifier = $notifiers->{$nkey};

      my $rfileno = $notifier->read_fileno;
      my $wfileno = $notifier->write_fileno;

      if( vec( $readvec, $rfileno, 1 ) ) {
         $notifier->on_read_ready;
      }

      if( defined $wfileno and vec( $writevec, $wfileno, 1 ) ) {
         $notifier->on_write_ready;
      }
   }
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 SEE ALSO

=over 4

=item *

L<IO::Select> - OO interface to select system call

=back

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
