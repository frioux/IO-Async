use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new
  (
   module_name => 'IO::Async',
   requires => {
                 'Heap'                => 0,
                 'IO::Poll'            => 0,
                 'Socket::GetAddrInfo' => 0,
                 'Storable'            => 0,
               },
   build_requires => {
                 'File::Temp' => 0,
                 'Test::More' => 0,
                 'Test::Exception' => 0,
                 'Time::HiRes' => 0,
               },
   license => 'perl',
   create_makefile_pl => 'traditional',
  );

$build->create_build_script;
