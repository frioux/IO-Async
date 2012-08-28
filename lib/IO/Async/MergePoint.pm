#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2007,2009 -- leonerd@leonerd.org.uk

package IO::Async::MergePoint;

use strict;
use warnings;

our $VERSION = '0.53';

use Carp;

use base qw( Async::MergePoint );

=head1 NAME

C<IO::Async::MergePoint> - resynchronise diverged control flow

=head1 SYNOPSIS

This module as now been moved to its own dist of L<Async::MergePoint>.

It is kept here as a trivial subclass for backward compatibility. Eventually
this subclass may be removed. Any code using C<IO::Async::MergePoint> should
instead use L<Async::MergePoint>.

 use Async::MergePoint;

 my $merge = Async::MergePoint->new(
    needs => [ "leaves", "water" ],

    on_finished => sub {
       my %items = @_;
       # Make tea using $items{leaves} and $items{water}
    }
 );

 Kettle->boil(
    on_boiled => sub { $merge->done( "water", $_[0] ) }
 );

 Cupboard->get_tea_leaves(
    on_fetched => sub { $merge->done( "leaves", $_[0] ) }
 );

=head1 DESCRIPTION

Often in program logic, multiple different steps need to be taken that are
independent of each other, but their total result is needed before the next
step can be taken. In synchonous code, the usual approach is to do them
sequentially. 

An C<IO::Async>-based program could do this, but if each step involves some IO
idle time, better overall performance can often be gained by running the steps
in parallel. A L<Async::MergePoint> object can then be used to wait for all of
the steps to complete, before passing the combined result of each step on to
the next stage.

A merge point maintains a set of outstanding operations it is waiting on;
these are arbitrary string values provided at the object's construction. Each
time the C<done> method is called, the named item is marked as being
complete. When all of the required items are so marked, the C<on_finished>
continuation is invoked.

When an item is marked as complete, a value can also be provided, which would
contain the results of that step. The C<on_finished> callback is passed a hash
(in list form, rather than by reference) of the collected item values.

=cut

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
