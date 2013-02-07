#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013 -- leonerd@leonerd.org.uk

package IO::Async::Future;

use strict;
use warnings;

our $VERSION = '0.54';

use base qw( Future );
Future->VERSION( '0.05' ); # to respect subclassing

=head1 NAME

C<IO::Async::Future> - use L<Future> with L<IO::Async>

=head1 SYNOPSIS

 use IO::Async::Loop;

 my $loop = IO::Async::Loop->new;

 my $future = $loop->new_future;

 $loop->watch_time( after => 3, code => sub { $future->done( "Done" ) } );

 print $future->get, "\n";

=head1 DESCRIPTION

This subclass of L<Future> stores a reference to the L<IO::Async::Loop>
instance that created it, allowing the C<await> method to block until the
Future is ready. These objects should not be constructed directly; instead
the C<new_future> method on the containing Loop should be used.

For a full description on how to use Futures, see the L<Future> documentation.

=cut

sub new
{
   my $proto = shift;
   my $self = $proto->SUPER::new;

   if( ref $proto ) {
      $self->{loop} = $proto->{loop};
   }
   else {
      $self->{loop} = shift;
   }

   return $self;
}

sub await
{
   my $self = shift;
   $self->{loop}->loop_once;
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
