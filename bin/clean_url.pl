#!/usr/bin/perl

use URI;
use URI::QueryParam;

print clean_url($_), "\n" for @ARGV;

exit;

sub clean_url {
    my ($uri) = @_;
    my @blacklisted_query_keys = qw(utm_source utm_medium utm_campaign utm_term);
    my $u = URI->new($uri);
    $u->query_param_delete($_) for @blacklisted_query_keys;
    return $u->canonical->as_string;
}
