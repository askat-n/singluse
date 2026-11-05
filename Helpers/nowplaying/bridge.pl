use DynaLoader;
my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
my $sym = DynaLoader::dl_find_symbol($lib, "singluse_stream") or die "symbol";
my $run = DynaLoader::dl_install_xsub("main::run", $sym);
main::run();
