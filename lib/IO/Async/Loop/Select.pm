#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007,2008 -- leonerd@leonerd.org.uk

package IO::Async::Loop::Select;

use strict;

our $VERSION = '0.17';

use base qw( IO::Async::Loop );

use Carp;

=head1 NAME

C<IO::Async::Loop::Select> - a Loop using the C<select()> syscall

=head1 SYNOPSIS

 use IO::Async::Loop::Select;

 my $loop = IO::Async::Loop::Select->new();

 $loop->add( ... );

 $loop->loop_forever();

Or

 while(1) {
    $loop->loop_once();
    ...
 }

Or

 while(1) {
    my ( $rvec, $wvec, $evec ) = ('') x 3;
    my $timeout;

    $loop->pre_select( \$rvec, \$wvec, \$evec, \$timeout );
    ...
    my $ret = select( $rvec, $wvec, $evec, $timeout );
    ...
    $loop->post_select( $rvec, $evec, $wvec );
 }

=head1 DESCRIPTION

This subclass of C<IO::Async::Loop> uses the C<select()> syscall to perform
read-ready and write-ready tests.

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

=head2 $loop = IO::Async::Loop::Select->new()

This function returns a new instance of a C<IO::Async::Loop::Select> object.
It takes no special arguments.

=cut

sub new
{
   my $class = shift;
   return $class->__new( @_ );
}

=head1 METHODS

=cut

=head2 $loop->pre_select( \$readvec, \$writevec, \$exceptvec, \$timeout )

This method prepares the bitvectors for a C<select()> call, setting the bits
that notifiers registered by this loop are interested in. It will always set
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

      vec( $$readref,  $notifier->read_fileno,  1 ) = 1 if $notifier->want_readready;
      vec( $$writeref, $notifier->write_fileno, 1 ) = 1 if $notifier->want_writeready;
   }

   $self->_adjust_timeout( $timeref );

   return;
}

=head2 $loop->post_select( $readvec, $writevec, $exceptvec )

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

   # Build a list of the notifiers that are ready, then fire the callbacks
   # afterwards. This avoids races and other bad effects if any of the
   # callbacks happen to change the notifiers in the set
   my @readready;
   my @writeready;

   my $notifiers = $self->{notifiers};
   foreach my $nkey ( keys %$notifiers ) {
      my $notifier = $notifiers->{$nkey};

      my $rfileno = $notifier->read_fileno;
      my $wfileno = $notifier->write_fileno;

      if( defined $rfileno and vec( $readvec, $rfileno, 1 ) ) {
         push @readready, $notifier;
      }

      if( defined $wfileno and vec( $writevec, $wfileno, 1 ) ) {
         push @writeready, $notifier;
      }
   }

   $_->on_read_ready foreach @readready;
   $_->on_write_ready foreach @writeready;

   # Since we have no way to know if the timeout occured, we'll have to
   # attempt to fire any waiting timeout events anyway

   my $timequeue = $self->{timequeue};
   $timequeue->fire if $timequeue;
}

=head2 $count = $loop->loop_once( $timeout )

This method calls the C<pre_select()> method to prepare the bitvectors for a
C<select()> syscall, performs it, then calls C<post_select()> to process the
result. It returns the total number of callbacks invoked by the
C<post_select()> method, or C<undef> if the underlying C<select()> syscall
returned an error.

=cut

# override
sub loop_once
{
   my $self = shift;
   my ( $timeout ) = @_;

   my ( $rvec, $wvec, $evec ) = ('') x 3;

   $self->pre_select( \$rvec, \$wvec, \$evec, \$timeout );

   my $ret = select( $rvec, $wvec, $evec, $timeout );

   {
      local $!;
      $self->post_select( $rvec, $wvec, $evec );
   }

   return $ret;
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
