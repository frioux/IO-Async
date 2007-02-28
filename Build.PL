use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new
  (
   module_name => 'IO::Async',
   dist_version_from => 'lib/IO/Async/Notifier.pm',
   dist_abstract     => "a collection of modules that implement asynchronous filehandle IO",
   requires => {
                 'IO::Poll' => 0,
               },
   build_requires => {
                 'Test::Exception' => 0,
                 'Glib' => '0',
                 'Time::HiRes' => 0,
               },
   license => 'perl',
  );
  
$build->create_build_script;
