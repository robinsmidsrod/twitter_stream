#!/usr/bin/env perl

use strict;
use warnings;

use LWP::UserAgent ();
use Encode ();
use HTML::Encoding ();
use HTML::Entities ();
use DBI ();

# Lots of UTF8 in Twitter data...
binmode STDOUT, ":utf8";

run();

exit;

############################################

sub run {
    my $ua = LWP::UserAgent->new();
    my $dbh = DBI->connect('dbi:Pg:dbname=twitter_stream', "", "", { AutoCommit => 0 } );
    die("Can't connect to database") unless $dbh;

    my $fetch_sth = $dbh->prepare(<<'EOM');
SELECT url FROM twitter
WHERE url NOT IN ( SELECT url FROM url)
GROUP BY url
ORDER BY COUNT(*) DESC
LIMIT 1
EOM
    my $insert_sth = $dbh->prepare(<<'EOM');
INSERT INTO url (url,fetched_at,response_code,real_url,title,content_type)
VALUES (?,current_timestamp, ?, ?, ?, ?)
EOM
    while( 1 ) {
        $fetch_sth->execute();
        (my $url) = $fetch_sth->fetchrow_array();
        if ( $url ) {
            handle_url( $url, $ua, $dbh, $insert_sth );
        }
        else {
            print "Sleeping...\n";
            sleep(1);
        }
    }

    print "Exiting...\n";
}

sub handle_url {
    my ($url, $ua, $dbh, $sth) = @_;

    print "URL:           ", $url, "\n";

    my ($status_code, $redirect, $title, $encoding_from, $mimetype) = resolve_redirect($url,$ua);

    if ( $status_code ) {
        print "HTTP STATUS:   ", $status_code, "\n";
    }
    if ( $redirect ) {
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
    $sth->execute(
        $url,
        $status_code,
        $redirect,
        $title,
        $mimetype
    );
    if ( $dbh->err ) {
        print "Rollback because '" . $dbh->errstr . "'!\n";
        $dbh->rollback();
    }
    else {
        $dbh->commit();
    }
    print "-" x 79, "\n";

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

1;
