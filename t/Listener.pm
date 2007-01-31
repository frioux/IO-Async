package Listener;

sub new
{
   my $class = shift;
   return bless {}, $class;
}

sub want_writeready
{
   return $main::want_writeready;
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
