#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007-2012 -- leonerd@leonerd.org.uk

package IO::Async::Loop::Select;

use strict;
use warnings;

our $VERSION = '0.49';
use constant API_VERSION => '0.49';

use base qw( IO::Async::Loop );

use Carp;

use POSIX qw( S_ISREG );

use constant HAVE_MSWIN32 => $^O eq "MSWin32";

# select() on most platforms claims that ISREG files are always read- and
# write-ready, but not on MSWin32. We need to fake this
use constant FAKE_ISREG_READY => HAVE_MSWIN32;

=head1 NAME

C<IO::Async::Loop::Select> - use C<IO::Async> with C<select(2)>

=head1 SYNOPSIS

Normally an instance of this class would not be directly constructed by a
program. It may however, be useful for runinng L<IO::Async> with an existing
program already using a C<select> call.

 use IO::Async::Loop::Select;

 my $loop = IO::Async::Loop::Select->new;

 $loop->add( ... );

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

This subclass of C<IO::Async::Loop> uses the C<select(2)> syscall to perform
read-ready and write-ready tests.

To integrate with an existing C<select>-based event loop, a pair of methods
C<pre_select> and C<post_select> can be called immediately before and
after a C<select> call. The relevant bits in the read-ready, write-ready and
exceptional-state bitvectors are set by the C<pre_select> method, and tested
by the C<post_select> method to pick which event callbacks to invoke.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $loop = IO::Async::Loop::Select->new

This function returns a new instance of a C<IO::Async::Loop::Select> object.
It takes no special arguments.

=cut

sub new
{
   my $class = shift;

   my $self = $class->__new( @_ );

   $self->{rvec} = '';
   $self->{wvec} = '';
   $self->{evec} = '';

   $self->{avec} = ''; # Bitvector of handles always to claim are ready

   return $self;
}

=head1 METHODS

=cut

=head2 $loop->pre_select( \$readvec, \$writevec, \$exceptvec, \$timeout )

This method prepares the bitvectors for a C<select> call, setting the bits
that the Loop is interested in. It will also adjust the C<$timeout> value if
appropriate, reducing it if the next event timeout the Loop requires is sooner
than the current value.

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

   # BITWISE operations
   $$readref   |= $self->{rvec};
   $$writeref  |= $self->{wvec};
   $$exceptref |= $self->{evec};

   $self->_adjust_timeout( $timeref );

   return;
}

=head2 $loop->post_select( $readvec, $writevec, $exceptvec )

This method checks the returned bitvectors from a C<select> call, and calls
any of the callbacks that are appropriate.

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

   my $iowatches = $self->{iowatches};

   my $count = 0;

   foreach my $fd ( keys %$iowatches ) {
      my $watch = $iowatches->{$fd};

      my $fileno = $watch->[0]->fileno;

      if( vec( $readvec, $fileno, 1 ) or 
          FAKE_ISREG_READY and vec( $self->{avec}, $fileno, 1 ) and vec( $self->{rvec}, $fileno, 1 ) ) {
         $count++, $watch->[1]->() if defined $watch->[1];
      }

      if( vec( $writevec, $fileno, 1 ) or
          HAVE_MSWIN32 and vec( $exceptvec, $fileno, 1 ) or
          FAKE_ISREG_READY and vec( $self->{avec}, $fileno, 1 ) and vec( $self->{wvec}, $fileno, 1 ) ) {
         $count++, $watch->[2]->() if defined $watch->[2];
      }
   }

   # Since we have no way to know if the timeout occured, we'll have to
   # attempt to fire any waiting timeout events anyway

   $self->_manage_queues;
}

=head2 $count = $loop->loop_once( $timeout )

This method calls the C<pre_select> method to prepare the bitvectors for a
C<select> syscall, performs it, then calls C<post_select> to process the
result. It returns the total number of callbacks invoked by the
C<post_select> method, or C<undef> if the underlying C<select(2)> syscall
returned an error.

=cut

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

sub watch_io
{
   my $self = shift;
   my %params = @_;

   $self->__watch_io( %params );

   my $fileno = $params{handle}->fileno;

   vec( $self->{rvec}, $fileno, 1 ) = 1 if $params{on_read_ready};
   vec( $self->{wvec}, $fileno, 1 ) = 1 if $params{on_write_ready};

   # MSWin32 does not indicate writeready for connect() errors, HUPs, etc
   # but it does indicate exceptional
   vec( $self->{evec}, $fileno, 1 ) = 1 if HAVE_MSWIN32 and $params{on_write_ready};

   vec( $self->{avec}, $fileno, 1 ) = 1 if FAKE_ISREG_READY and S_ISREG(stat $params{handle});
}

sub unwatch_io
{
   my $self = shift;
   my %params = @_;

   $self->__unwatch_io( %params );

   my $fileno = $params{handle}->fileno;

   vec( $self->{rvec}, $fileno, 1 ) = 0 if $params{on_read_ready};
   vec( $self->{wvec}, $fileno, 1 ) = 0 if $params{on_write_ready};

   vec( $self->{evec}, $fileno, 1 ) = 0 if HAVE_MSWIN32 and $params{on_write_ready};

   vec( $self->{avec}, $fileno, 1 ) = 0 if FAKE_ISREG_READY and S_ISREG(stat $params{handle});

   # vec will grow a bit vector as needed, but never shrink it. We'll trim
   # trailing null bytes
   $_ =~s/\0+\z// for $self->{rvec}, $self->{wvec}, $self->{evec}, $self->{avec};
}

=head1 SEE ALSO

=over 4

=item *

L<IO::Select> - OO interface to select system call

=back

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
