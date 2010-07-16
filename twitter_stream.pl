#!/usr/bin/env perl

use strict;
use warnings;

use lib 'lib';

use AnyEvent;
use AnyEvent::Twitter::Stream;
use URI::Find::UTF8;

use TwitterStream;

# Lots of UTF8 in Twitter data...
binmode STDOUT, ":utf8";

run();

exit;

############################################

sub run {

    my $timeout = 1;
    while ( 1 ) {
        last if $timeout >= 960; # Exit if more than 16 minutes has passed
        print "Sleeping $timeout second(s) before connecting to Twitter stream...\n";
        sleep($timeout);
        eval {
            my $done = AnyEvent->condvar;
            my $stream = init_stream($done, \$timeout);
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
    my ($done, $timeout_ref) = @_;

    my $ts = TwitterStream->new();

    my $dbh = $ts->dbh;

    my $mention_insert_sth = $dbh->prepare("INSERT INTO mention (id, mention_at, url_id, keyword_id) VALUES (?,?,?,?)");
    my $keyword_insert_sth = $dbh->prepare("INSERT INTO keyword (id, keyword) VALUES (?,?)");
    my $keyword_select_sth = $dbh->prepare("SELECT id FROM keyword WHERE keyword = ?");
    my $url_insert_sth     = $dbh->prepare("INSERT INTO url (id, url, host, first_mention_id, first_mention_at, first_mention_by_name, first_mention_by_user) VALUES (?,?,?,?,?,?,?)");
    my $url_select_sth     = $dbh->prepare("SELECT id, verified_url_id FROM url WHERE url = ?");

    print "Using '" . $ts->twitter_method . "' method to track the following keywords: " . $ts->twitter_track . "\n";

    return AnyEvent::Twitter::Stream->new(
        username => $ts->twitter_username,
        password => $ts->twitter_password,
        method   => $ts->twitter_method,
        track    => $ts->twitter_track,
        on_tweet => sub {
            my ($tweet) = @_;
            eval {
                handle_tweet(
                    tweet              => $tweet,
                    ts                 => $ts,
                    mention_insert_sth => $mention_insert_sth,
                    keyword_insert_sth => $keyword_insert_sth,
                    keyword_select_sth => $keyword_select_sth,
                    url_insert_sth     => $url_insert_sth,
                    url_select_sth     => $url_select_sth,
                );
            };
            if ($@) {
                warn("Error handling tweet: $@\n");
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

sub handle_tweet {
    my (%args) = @_;
    my $tweet = $args{'tweet'};
    my $ts    = $args{'ts'};

    return unless $tweet->{'user'}->{'screen_name'};
    return unless $tweet->{'text'};
    return unless $tweet->{'text'} =~ m{http}i;

    my $dbh = $ts->dbh;

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
        $uri->path('') if $uri->path eq '/'; # Strip trailing slash for root path
        push @urls, $uri;
    });
    $finder->find(\( $tweet->{'text'} ));

    my $timestamp = $ts->parse_date( $tweet->{'created_at'} );
    my $user = $tweet->{'user'}->{'screen_name'};
    my $name = $tweet->{'user'}->{'name'} || $user;

    print "ID:            ", $tweet->{'id'}, "\n";
    print "TIMESTAMP:     ", $timestamp, "\n";
    print "NAME:          ", $name, "\n";

    foreach my $url ( sort @urls ) {

        print "URL:           ", $url, "\n";
        $dbh->pg_savepoint('url_insert');

        my $url_id = $ts->new_uuid();
        my $verified_url_id;
        $args{'url_insert_sth'}->execute( $url_id, $url, $url->host, $tweet->{'id'}, $timestamp, $name, $user );
        if ( $dbh->err ) {
            $dbh->pg_rollback_to('url_insert');
            $args{'url_select_sth'}->execute($url);
            ($url_id, $verified_url_id) = $args{'url_select_sth'}->fetchrow_array();
        }
        # If we couldn't resolve url_id, rollback (which basically means skip)
        unless ( $url_id ) {
            print "Unable to resolve id for '$url'\n";
            $dbh->pg_rollback_to('url_insert');
            next;
        }
        print "URL ID:        ", $url_id, "\n";

        if ( $verified_url_id ) {
            print "VERIFIED URL ID: ", $verified_url_id, "\n";
        }

        if ( $verified_url_id ) {
            # URL is already verified, add to summary tables immediately
            $ts->store_mention(
                {
                    mention_at => $timestamp,
                    url_id     => $url_id,
                },
                $verified_url_id,
            );
        }
        else {
            # Add record to 'mention' table for later resolution
            $args{'mention_insert_sth'}->execute(
                $ts->new_uuid(),
                $timestamp,
                $url_id,
                undef, # no keyword specified
            );

            if ( $dbh->err ) {
                print "Storing mention of '$url' failed: ", $dbh->errstr, "\n";
                $dbh->pg_rollback_to('url_insert');
                next; # Skip to next URL if bad stuff happened
            }
        }

        foreach my $keyword ( sort keys %keywords ) {
            $keyword = lc $keyword;

            print "KEYWORD:       ", $keyword, "\n";
            $dbh->pg_savepoint('keyword_insert');

            my $keyword_id = $ts->new_uuid();
            $args{'keyword_insert_sth'}->execute( $keyword_id, $keyword );
            if ( $dbh->err ) {
                $dbh->pg_rollback_to('keyword_insert');
                $args{'keyword_select_sth'}->execute($keyword);
                ($keyword_id) = $args{'keyword_select_sth'}->fetchrow_array();
            }
            # If we couldn't resolve keyword id, skip this keyword
            unless ( $keyword_id ) {
                $dbh->pg_rollback_to('keyword_insert');
                next;
            }
            print "KEYWORD ID:    ", $keyword_id, "\n";

            if ( $verified_url_id ) {
                # URL is already verified, add to keyword summary tables immediately
                $ts->store_mention(
                    {
                        mention_at => $timestamp,
                        url_id     => $url_id,
                        keyword_id => $keyword_id,
                    },
                    $verified_url_id,
                );
            }
            else {
                # Add record to 'mention' table with keyword for later resolution
                $args{'mention_insert_sth'}->execute(
                    $ts->new_uuid(),
                    $timestamp,
                    $url_id,
                    $keyword_id,
                );
                if ( $dbh->err ) {
                    print "Inserting mention of '$url' with keyword '$keyword' failed: ", $dbh->errstr, "\n";
                    $dbh->pg_rollback_to('keyword_insert');
                    next;
                }
            }
        }
    }

    # Check that everything went well
    if ( $dbh->err ) {
        print "Storing mentions of urls in tweet failed: ", $dbh->errstr, "\n";
        $dbh->rollback();
    }
    else {
        $dbh->commit();
    }

    print "-" x 79, "\n";
}

1;
