#!/usr/bin/env perl

use strict;
use warnings;

use File::HomeDir;
use Path::Class;
use Config::Any;
use AnyEvent;
use AnyEvent::Twitter::Stream;
use URI::Find::UTF8;
use DBI ();

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

    my $dbh = DBI->connect('dbi:Pg:dbname=twitter_stream', "", "", { AutoCommit => 0 } );
    die("Can't connect to database") unless $dbh;

    my $insert_sth = $dbh->prepare("INSERT INTO twitter (twitter_id,created_at,created_by,keyword,url) VALUES (?,?,?,?,?)");

    return AnyEvent::Twitter::Stream->new(
        username => $username,
        password => $password,
        method => 'sample',
        on_tweet => sub {
            my ($tweet) = @_;
            handle_tweet($tweet, $dbh, $insert_sth);
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
    my ($tweet, $dbh, $sth) = @_;
    return unless $tweet->{'user'}->{'screen_name'};
    return unless $tweet->{'text'};
    return unless $tweet->{'text'} =~ m{http}i;
    my %keywords;
    foreach my $hashtag ( sort $tweet->{'text'} =~ m{#(\w+?)\b}g ) {
        next if $hashtag =~ m{^\d+$}; # Skip digits only
        $keywords{$hashtag} = 1;
    }
    my @urls;
    my $finder = URI::Find::UTF8->new(sub {
        my ($uri, $uri_str) = @_;
        return unless $uri->scheme =~ m{^(?:ftp|http|https)$}; # We just care about HTTP(S) and FTP
        return unless $uri->host; # Skip URLs without hostname part
        return unless $uri->host =~ m{\.\w{2,}$}; # Need at least one dot + two (or more) word chars at the end of the hostname
        push @urls, $uri;
    });
    $finder->find(\( $tweet->{'text'} ));

    my $timestamp = parse_date( $tweet->{'created_at'} );

    foreach my $url ( sort @urls ) {
        foreach my $keyword ( sort keys %keywords ) {
            print "ID:            ", $tweet->{'id'}, "\n";
            print "TIMESTAMP:     ", $timestamp, "\n";
            print "NAME:          ", $tweet->{'user'}->{'name'}, "\n";
            print "KEYWORD:       ", $keyword, "\n";
            print "URL:           ", $url, "\n";
            $sth->execute(
                $tweet->{'id'},
                $timestamp,
                $tweet->{'user'}->{'name'},
                $keyword,
                $url
            );
            if ( $dbh->err ) {
                $dbh->rollback();
            }
            else {
                $dbh->commit();
            }
            print "-" x 79, "\n";
        }
    }
}

sub parse_date {
    my ($str) = @_;
    ( my $year = $str ) =~ s/\A.+(\d{4})\Z/$1/xms;
    ( my $month = $str ) =~ s/\A.+?\s+(\w+?)\s.*\Z/$1/xms;
    my %months = (
        Jan => "01",
        Feb => "02",
        Mar => "03",
        Apr => "04",
        May => "05",
        Jun => "06",
        Jul => "07",
        Aug => "08",
        Sep => "09",
        Oct => "10",
        Nov => "11",
        Dec => "12",
    );
    $month = $months{$month};
    ( my $day = $str ) =~ s/\A\w+?\s+?\w+?\s+?(\d{2}).*\Z/$1/xms;
    ( my $hour = $str ) =~ s/\A\w+?\s+?\w+?\s+?\d+?\s+?(\d{2}).*\Z/$1/xms;
    ( my $minute = $str ) =~ s/\A\w+?\s+?\w+?\s+?\d+?\s+?\d+?:(\d{2}).*\Z/$1/xms;
    ( my $second = $str ) =~ s/\A\w+?\s+?\w+?\s+?\d+?\s+?\d+?:\d+?:(\d{2}).*\Z/$1/xms;
    return "$year-$month-$day $hour:$minute:$second UTC";
}

1;
