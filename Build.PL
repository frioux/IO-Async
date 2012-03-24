use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new(
   module_name => 'IO::Async',
   requires => {
      'Async::MergePoint' => '0.03',
      'CPS' => 0,
      'Exporter' => '5.57',
      'Heap' => '0.80',
      'IO::Poll' => 0,
      'Socket' => '1.95',
      'Storable' => 0,
      'Time::HiRes' => 0,

      # Fails on perl 5.8.3 for unknown reasons
      #   https://rt.cpan.org/Ticket/Display.html?id=64493
      # Now 5.14 is stable, I see even less reason to worry about such an old Perl
      'perl' => '5.008005',
   },
   build_requires => {
      'File::Temp' => 0,
      'Test::More' => 0,
      'Test::Fatal' => 0,
      'Test::Identity' => 0,
      'Test::Refcount' => 0,
      'Test::Warn' => 0,
   },
   configure_requires => {
      'Module::Build' => 0,
   },
   license => 'perl',
   create_makefile_pl => 'small',
   create_license => 1,
   create_readme  => 1,
);

$build->create_build_script;
