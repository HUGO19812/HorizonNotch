# Loads HNMediaBridge.dylib into Apple's perl and hands control to it.
# Usage: /usr/bin/perl hn-media.pl /path/to/HNMediaBridge.dylib
use strict;
use warnings;
use DynaLoader;

my $path = shift or die "usage: hn-media.pl <dylib>\n";
my $lib = DynaLoader::dl_load_file($path, 0) or die "load failed: " . DynaLoader::dl_error() . "\n";
my $sym = DynaLoader::dl_find_symbol($lib, "hn_run") or die "hn_run missing\n";
DynaLoader::dl_install_xsub("main::hn_run", $sym);
hn_run();
