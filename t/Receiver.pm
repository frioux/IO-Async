package Receiver;

sub new
{
   my $class = shift;
   return bless {}, $class;
}

sub incomingData
{
   my $self = shift;
   my ( $buffref, $buffclosed ) = @_;

   if( $buffclosed ) {
      $main::closed = $buffclosed;
      undef $main::received;
      return 0;
   }

   return 0 unless( $$buffref =~ s/^(.*\n)// );
   $main::received = $1;
   return 1;
}

1;
