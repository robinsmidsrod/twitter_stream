#!/usr/bin/env perl

use strict;
use warnings;

use File::HomeDir;
use Path::Class;
use Config::Any;
use AnyEvent;
use AnyEvent::Twitter::Stream;

# Lots of UTF8 in Twitter data...
binmode STDOUT, ":utf8";

my $done = AnyEvent->condvar;
my $stream = init_stream($done, @ARGV);
$done->recv();
exit;

############################################

sub init_stream {
    my ($done, $username, $password) = @_;

    my $config_file = get_config_file();
    my $config = get_config($config_file);
    $username ||= $config->{'global'}->{'username'};
    $password ||= $config->{'global'}->{'password'};

    unless ( $username and $password ) {
        die("Please specify your Twitter username and password on command line or in '$config_file'.\n");
    }

    return AnyEvent::Twitter::Stream->new(
        username => $username,
        password => $password,
        method => 'sample',
        on_tweet => sub {
            my ($tweet) = @_;
            handle_tweet($tweet);
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

sub get_config_file {
    my $home = File::HomeDir->my_data;
    my $conf_file = Path::Class::Dir->new($home)->file('.twitter_stream.ini');
    return $conf_file;
}

sub get_config {
    my ($conf_file) = @_;
    my $cfg = Config::Any->load_files({
        use_ext => 1,
        files   => [ $conf_file ],
    });
    foreach my $config_entry ( @{ $cfg } ) {
        my ($filename, $config) = %{ $config_entry };
        warn("Loaded config from file: $filename\n");
        return $config;
    }
    return {};
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
