package Listener;

sub new
{
   my $class = shift;
   return bless {}, $class;
}

sub read_ready
{
   $main::readready = 1;
}

sub write_ready
{
   $main::writeready = 1;
}

1;
