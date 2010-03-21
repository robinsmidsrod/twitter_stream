#!/usr/bin/env perl

use strict;
use warnings;

use AnyEvent;
use AnyEvent::Twitter::Stream;

# Lots of UTF8 in Twitter data...
binmode STDOUT, ":utf8";

my $done = AnyEvent->condvar;
my $stream = init_stream($done);
$done->recv();
exit;

############################################

sub init_stream {
    my ($done) = @_;
    return AnyEvent::Twitter::Stream->new(
        username => $ENV{TWITTER_USERNAME},
        password => $ENV{TWITTER_PASSWORD},
        method => 'sample',
        on_tweet => sub {
            handle_tweet(@_);
        },
        on_keepalive => sub {
            warn "-- keepalive --\n";
        },
        on_error => sub {
            my ($error) = @_;
            warn "ERROR: $error";
            $done->send;
        },
        on_eof   => sub {
            $done->send;
        },
        timeout => 45,
    );
}

sub handle_tweet {
    my ($tweet) = @_;
    return unless $tweet->{'user'}->{'screen_name'};
    return unless $tweet->{'text'};
    print $tweet->{'user'}->{'screen_name'}, ": ", $tweet->{'text'}, "\n";
    #print join("\n", keys %{ $tweet } ), "\n";
    #print join(", ", keys %{ $tweet->{'user'} } ), "\n";
}

1;
