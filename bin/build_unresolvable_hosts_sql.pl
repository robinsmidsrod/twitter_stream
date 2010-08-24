#!/usr/bin/perl

# Build SQL statement to fetch non-resolvable hostnames

use strict;
use warnings;

# tld-names-alphabetical downloaded from:
# ftp://ftp.iana.org/assignments/tld-names-alphabetical
open(my $fh, '<', 'tld-names-alphabetical') or die ("Open failed: $!");
my @tlds;
while(<$fh>) {
    chomp;
    push @tlds, lc($_);
}
close($fh);

# Add some missing TLDs
push @tlds, qw(me eu tl mobi);

my $re = '^.+\\.(' . join('|', sort @tlds) . ')$';
print qq{select distinct host\nfrom url\nwhere host !~ '}
    . $re
    . qq{'\n and verify_failed=true;\n};
