package Listener;

sub new
{
   my $class = shift;
   return bless {}, $class;
}

sub readready
{
   $main::readready = 1;
}

sub writeready
{
   $main::writeready = 1;
}

1;
