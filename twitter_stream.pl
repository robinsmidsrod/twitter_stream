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
use Data::UUID ();

# Lots of UTF8 in Twitter data...
binmode STDOUT, ":utf8";

#track => 'perl,java,python,ruby,rails,bash,linux,windows,freebsd,solaris,nexenta,openbsd,opensolaris,windows7', #,html,css,javascript,flickr,smugsmug,photo,photography,camera,canon,nikon,sony,pentax,picture,image,hdr',

my @keywords = @ARGV;

unless ( scalar @keywords ) {
    print "No keywords specified, terminating...\n";
    exit;
}

run(@keywords);

exit;

############################################

sub run {
    my (@keywords) = @_;
    my $timeout = 1;
    while ( 1 ) {
        last if $timeout >= 960; # Exit if more than 16 minutes has passed
        print "Sleeping $timeout second(s) before connecting to Twitter stream...\n";
        sleep($timeout);
        eval {
            my $done = AnyEvent->condvar;
            my $stream = init_stream($done, \$timeout, @keywords);
            $done->recv();
        };
        if ($@) {
            warn("Twitter connection gave error: $@");
        }
        $timeout *= 2;
    }
    print "Exiting because of timeout...\n";
}

sub init_stream {
    my ($done, $timeout_ref, @keywords) = @_;

    my $config_file = get_config_file();
    my $config = get_config($config_file);
    my $username = $ENV{'TWITTER_STREAM_USERNAME'} || $config->{'global'}->{'username'};
    my $password = $ENV{'TWITTER_STREAM_PASSWORD'} || $config->{'global'}->{'password'};

    unless ( $username and $password ) {
        die("Please specify your Twitter username and password on command line or in '$config_file'.\n");
    }

    my $dbh = DBI->connect('dbi:Pg:dbname=twitter_stream', "", "", { AutoCommit => 0 } );
    die("Can't connect to database") unless $dbh;

    my $mention_sth        = $dbh->prepare("INSERT INTO mention (id, mention_at, url_id, keyword_id) VALUES (?,?,?,?)");
    my $keyword_insert_sth = $dbh->prepare("INSERT INTO keyword (id, keyword) VALUES (?,?)");
    my $keyword_select_sth = $dbh->prepare("SELECT id FROM keyword WHERE keyword = ?");
    my $url_insert_sth     = $dbh->prepare("INSERT INTO url (id, url, host, first_mention_id, first_mention_at, first_mention_by_name, first_mention_by_user) VALUES (?,?,?,?,?,?,?)");
    my $url_select_sth     = $dbh->prepare("SELECT id FROM url WHERE url = ?");

    return AnyEvent::Twitter::Stream->new(
        username => $username,
        password => $password,
        method   => 'filter',
        track    => join(",", @keywords),
        on_tweet => sub {
            my ($tweet) = @_;
            eval {
                handle_tweet(
                    tweet              => $tweet,
                    dbh                => $dbh,
                    mention_sth        => $mention_sth,
                    keyword_insert_sth => $keyword_insert_sth,
                    keyword_select_sth => $keyword_select_sth,
                    url_insert_sth     => $url_insert_sth,
                    url_select_sth     => $url_select_sth,
                );
            };
            if ($@) {
                warn("Error handling tweet...\n");
            }
            $$timeout_ref = 1; # Reset timeout counter
        },
        on_keepalive => sub {
            warn "-- keepalive --\n";
            $$timeout_ref = 1; # Reset timeout counter
        },
        on_error => sub {
            my ($error) = @_;
            warn "ERROR: $error\n";
            $done->send;
        },
        on_eof => sub {
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
    my (%args) = @_;
    my $tweet = $args{'tweet'};
    my $dbh   = $args{'dbh'};

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
    my $user = $tweet->{'user'}->{'screen_name'};
    my $name = $tweet->{'user'}->{'name'} || $user;

    print "ID:            ", $tweet->{'id'}, "\n";
    print "TIMESTAMP:     ", $timestamp, "\n";
    print "NAME:          ", $name, "\n";

    foreach my $url ( sort @urls ) {

        my $url_id = new_uuid();
        $args{'url_insert_sth'}->execute( $url_id, $url, $url->host, $tweet->{'id'}, $timestamp, $name, $user );
        if ( $dbh->err ) {
            $dbh->rollback();

            $args{'url_select_sth'}->execute($url);
            ($url_id ) = $args{'url_select_sth'}->fetchrow_array();
            if ( $dbh->err ) {
                print "Fetching url.id failed: ", $dbh->errstr, "\n";
                $dbh->rollback();
                undef $url_id;
            }
            else {
                $dbh->commit;
            }
        }
        else {
            $dbh->commit();
        }
        next unless $url_id; # Skip if wrong stuff happened

        $args{'mention_sth'}->execute( new_uuid(), $timestamp, $url_id, undef );
        if ( $dbh->err ) {
            print "Storing mention of $url failed: ", $dbh->errstr, "\n";
            $dbh->rollback();
            next; # Skip to next URL if bad stuff happened
        }
        else {
            $dbh->commit();
        }
        print "URL:           ", $url, "\n";
        print "URL ID:        ", $url_id, "\n";

        foreach my $keyword ( sort keys %keywords ) {
            $keyword = lc $keyword;
            my $keyword_id = new_uuid();
            $args{'keyword_insert_sth'}->execute( $keyword_id, $keyword );
            if ( $dbh->err ) {
                $dbh->rollback();
                $args{'keyword_select_sth'}->execute($keyword);
                ($keyword_id) = $args{'keyword_select_sth'}->fetchrow_array();
                if ( $dbh->err ) {
                    print "Fetching keyword.id failed: ", $dbh->errstr, "\n";
                    $dbh->rollback();
                    undef $keyword_id;
                }
                else {
                    $dbh->commit;
                }
            }
            else {
                $dbh->commit();
            }
            next unless $keyword_id; # Skip if wrong stuff happened

            print "KEYWORD:       ", $keyword, "\n";
            print "KEYWORD ID:    ", $keyword_id, "\n";

            $args{'mention_sth'}->execute(
                new_uuid(),
                $timestamp,
                $url_id,
                $keyword_id,
            );
            if ( $dbh->err ) {
                print "Storing URL => keyword map failed: ", $dbh->errstr, "\n";
                $dbh->rollback();
            }
            else {
                $dbh->commit();
            }
        }
    }
    print "-" x 79, "\n";
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

sub new_uuid {
    return Data::UUID->new->create_str();
}

1;
