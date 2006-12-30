use ExtUtils::MakeMaker;

WriteMakefile(
   NAME => 'IO::SelectNotifier',
   VERSION_FROM => 'lib/IO/SelectNotifier.pm',
   PREREQ_PM => {
      'Error'      => '0.15',
   },
);
