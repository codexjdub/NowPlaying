#!/usr/bin/perl
# Loads the MediaRemoteAdapter dylib and invokes the requested symbol
# (default: adapter_get). The dylib prints JSON to stdout.

use strict;
use warnings;
use DynaLoader;

my $lib    = shift @ARGV or die "Usage: adapter.pl <dylib> [symbol]\n";
my $symbol = shift @ARGV // 'adapter_get';

my $handle = DynaLoader::dl_load_file($lib, 0)
    or die "Failed to load dylib: " . DynaLoader::dl_error() . "\n";

my $sym = DynaLoader::dl_find_symbol($handle, $symbol)
    or die "Failed to find symbol '$symbol' in dylib\n";

my $func = DynaLoader::dl_install_xsub("main::$symbol", $sym);
&$func();
