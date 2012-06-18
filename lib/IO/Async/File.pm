#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2012 -- leonerd@leonerd.org.uk

package IO::Async::File;

use strict;
use warnings;

our $VERSION = '0.49';

use base qw( IO::Async::Timer::Periodic );

use File::stat;

# No point watching blksize or blocks
my @STATS = qw( dev ino mode nlink uid gid rdev size atime mtime ctime );

=head1 NAME

C<IO::Async::File> - watch a filehandle for changes

=head1 SYNOPSIS

 use IO::Async::FileStream;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new;

 open my $fileh, "<", "config.ini" or
    die "Cannot open config file - $!";

 my $file = IO::Async::File->new(
    handle => $fileh,
    on_mtime_changed => sub {
       print STDERR "Config file has changed\n";
       reload_config();
    }
 );

 $loop->add( $file );

 $loop->run;

=head1 DESCRIPTION

This subclass of L<IO::Async::Notifier> watches an open filehandle for changes
in its C<stat()> fields. It invokes various events when the values of these
fields change. It is most often used to watch a file for size changes; for
this task see also L<IO::Async::FileStream>.

While called "File", it is not required that the watched filehandle be a
regular file. It is possible to watch anything that C<stat(2)> may be called
on, such as directories or other filesystem entities.

=cut

=head1 EVENTS

The following events are invoked, either using subclass methods or CODE
references in parameters.

=head2 on_dev_changed $new_dev, $old_dev

=head2 on_ino_changed $new_ino, $old_ino

=head2 ...

=head2 on_ctime_changed $new_ctime, $old_ctime

Invoked when each of the individual C<stat()> fields have changed. All the
C<stat()> fields are supported apart from C<blocks> and C<blksize>. Each is
passed the new and old values of the field.

=head2 on_stat_changed $new_stat, $old_stat

Invoked when any of the C<stat()> fields have changed. It is passed two
L<File::stat> instances containing the old and new C<stat()> fields.

=cut

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>.

=over 8

=item handle => IO

The filehandle to watch for C<stat()> changes.

=item interval => NUM

Optional. The interval in seconds to poll the filehandle using C<stat(2)>
looking for size changes. A default of 2 seconds will be applied if not
defined.

=back

=cut

sub _init
{
   my $self = shift;
   my ( $params ) = @_;

   $params->{interval} ||= 2;

   $self->SUPER::_init( $params );
}

sub configure
{
   my $self = shift;
   my %params = @_;

   if( exists $params{handle} ) {
      $self->{handle} = delete $params{handle};
      undef $self->{last_stat};
   }

   foreach ( @STATS, "stat" ) {
      $self->{"on_${_}_changed"} = delete $params{"on_${_}_changed"} if exists $params{"on_${_}_changed"};
   }

   $self->SUPER::configure( %params );

   if( $self->{handle} and !defined $self->{last_stat} ) {
      $self->{last_stat} = stat $self->{handle};
      $self->start;
   }
}

sub on_tick
{
   my $self = shift;

   my $old = $self->{last_stat};
   my $new = stat $self->{handle};

   my $any_changed;
   foreach my $stat ( @STATS ) {
      next if $old->$stat == $new->$stat;

      $any_changed++;
      $self->maybe_invoke_event( "on_${stat}_changed", $new->$stat, $old->$stat );
   }

   $self->maybe_invoke_event( on_stat_changed => $new, $old ) if $any_changed;

   $self->{last_stat} = $new if $any_changed;
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
