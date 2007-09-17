use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new
  (
   module_name => 'IO::Async',
   dist_version_from => 'lib/IO/Async/Notifier.pm',
   dist_abstract     => "a collection of modules that implement asynchronous filehandle IO",
   requires => {
                 'Heap'     => 0,
                 'IO::Poll' => 0,
                 'Storable' => 0,
               },
   build_requires => {
                 'Test::More' => 0,
                 'Test::Exception' => 0,
                 'Time::HiRes' => 0,
               },
   license => 'perl',
   create_makefile_pl => 'traditional',
  );

# We'd like to build_recommend Glib, only we can't. So we'll hack it out of
# an eval'ed require instead
eval { require Glib; 1 } or
   warn "** You don't have Glib installed.\n" .
        "** This is OK, but you would get extra testing if it were\n";
  
$build->create_build_script;
