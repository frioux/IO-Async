use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new
  (
   module_name => 'IO::Async',
   dist_version_from => 'lib/IO/Async/Notifier.pm',
   requires => {
                 'Error' => '0.15'
               },
   build_requires => {
                 'Test::Exception' => 0,
               },
   license => 'perl',
  );
  
$build->create_build_script;
