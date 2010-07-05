#!/usr/bin/env perl

use strict;
use warnings;

use File::HomeDir;
use Path::Class;
use Config::Any;
use AnyEvent;
use AnyEvent::Twitter::Stream;
use URI::Find::UTF8;
use LWP::UserAgent ();
use Encode ();
use Data::Dumper qw(Dumper);
use HTML::Encoding ();
use HTML::Entities ();
use HTTP::Date ();

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

    my $ua = LWP::UserAgent->new();

    return AnyEvent::Twitter::Stream->new(
        username => $username,
        password => $password,
        method => 'sample',
        on_tweet => sub {
            my ($tweet) = @_;
            handle_tweet($tweet,$ua);
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
    my ($tweet,$ua) = @_;
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
        push @urls, $uri;
    });
    $finder->find(\( $tweet->{'text'} ));

    my $timestamp = parse_date( $tweet->{'created_at'} );

    foreach my $url ( sort @urls ) {
        my ($status_code, $redirect, $title, $encoding_from, $mimetype);
        if ( 0 ) {
            ($status_code, $redirect, $title, $encoding_from, $mimetype) = resolve_redirect($url,$ua);
        }
        foreach my $keyword ( sort keys %keywords ) {
            print "ID:            ", $tweet->{'id'}, "\n";
            print "TIMESTAMP:     ", $timestamp, "\n";
            print "NAME:          ", $tweet->{'user'}->{'name'}, "\n";
            print "KEYWORD:       ", $keyword, "\n";
            print "URL:           ", $url, "\n";
            if ( $status_code ) {
                print "HTTP STATUS:   ", $status_code, "\n";
            }
            if ( $redirect and $redirect ne $url ) {
                print "RESOLVED URL:  ", $redirect, "\n";
            }
            if ( $title ) {
                print "TITLE:         ", $title, "\n";
            }
            if ( $encoding_from ) {
                print "ENCODING FROM: ", $encoding_from, "\n";
            }
            if ( $mimetype ) {
                print "CONTENT TYPE:  ", $mimetype, "\n";
            }
            print "-" x 79, "\n";
        }
    }
    return unless @urls > 0; # No URLs, don't print hashtags
#    print "Location: ", $tweet->{'user'}->{'location'}, "\n";
#    print join("\n", keys %{ $tweet } ), "\n";
#    print Dumper($tweet);
#    print "GEO: ", $tweet->{'geo'}, "\n";
#    print "COORDINATES: ", $tweet->{'coordinates'}, "\n";
#    print "PLACE: ", $tweet->{'place'}, "\n";
#    print join(", ", keys %{ $tweet->{'coordinates'} } ), "\n";
}

sub resolve_redirect {
    my ($url,$ua) = @_;
    my $content = "";
    my $res;
    eval {
        local $SIG{ALRM} = sub { die "alarm\n" }; # NB: \n required
        alarm 3;
        my $chunks_read = 0;
        $res = $ua->get(
            $url,
            ":content_cb" => sub {
                my ($data, $res, $ua) = @_;
                die("Not HTML!\n") if $res->header('Content-type') !~ m{^(?:text/html|application/xhtml+xml)};
                $content .= $data;
                $chunks_read++;
                die("Title found!\n") if $content =~ m{</title>}xmsi;
                die("Too much data read!\n") if $chunks_read >= 5; # Read at maximum 5k
            },
            ":read_size_hint" => 1000,
        );
        alarm 0;
    };
    if ( $@ ) {
        die unless $@ eq "alarm\n";
        return ( $res->code, $res->request->uri, undef, undef, $res->header('Content-type') ); # timeout
    }
    if ( $res->is_success ) {
        my $content_type = $res->header('Content-Type');
        $content_type = (split(/;/, $content_type, 2))[0];
        my $title = $content;
        my $encoding_from = "";
        if ( $res->content_charset and Encode::resolve_alias($res->content_charset) ) {
            $encoding_from = "header";
            {
                no warnings 'utf8';
                $title = Encode::decode($res->content_charset, $title);
            }
        }
        else {
            my $encoding = $content_type eq 'text/html'
                         ? HTML::Encoding::encoding_from_html_document($title)
                         : HTML::Encoding::encoding_from_xml_declaration($title);
            if ( $encoding and Encode::resolve_alias($encoding) ) {
                $encoding_from = "content";
                {
                    no warnings 'utf8';
                    $title = Encode::decode($encoding, $title);
                }
            }
        }
        if ( $title =~ s{\A.*<title>\s*(.+?)\s*</title>.*\Z}{$1}xmsi ) {
            $title =~ s/\s+/ /gms; # trim consecutive whitespace
            $title = HTML::Entities::decode($title); # Get rid of those pesky HTML entities
            return ( $res->code, $res->request->uri, $title, $encoding_from, $content_type );
        }
        else {
            return ( $res->code, $res->request->uri, undef, undef, $content_type );
        }
    }
    return;
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
