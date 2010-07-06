#!/usr/bin/env perl

use strict;
use warnings;

use LWP::UserAgent ();
use Encode ();
use HTML::Encoding ();
use HTML::Entities ();
use DBI ();
use Parallel::Iterator ();

# Lots of UTF8 in Twitter data...
binmode STDOUT, ":utf8";

run($ARGV[0] || 1); # Set concurrency

exit;

############################################

sub run {
    my ($concurrency) = @_;

    my $dbh = DBI->connect('dbi:Pg:dbname=twitter_stream', "", "", { AutoCommit => 0 } );
    die("Can't connect to database") unless $dbh;
    $dbh->{'pg_enable_utf8'} = 1; # Return data from DB already decoded

    my $fetch_sth = $dbh->prepare(<<'EOM');
SELECT DISTINCT(twitter.url)
FROM twitter LEFT JOIN url ON twitter.url=url.url
WHERE url.url IS NULL
LIMIT ?
EOM
    my $insert_sth = $dbh->prepare(<<'EOM');
INSERT INTO url (url,fetched_at,response_code,real_url,title,content_type)
VALUES (?,current_timestamp, ?, ?, ?, ?)
EOM
    while( 1 ) {
        $fetch_sth->execute($concurrency);
        my @urls;
        while( (my $url) = $fetch_sth->fetchrow_array() ) {
            push @urls, $url;
        }
        if ( @urls > 0 ) {
            foreach my $info ( fetch_urls($dbh, @urls) ) {
                store_url( $info, $dbh, $insert_sth );
            }
        }
        else {
            print "Sleeping...\n";
            sleep(1);
        }
    }

    print "Exiting...\n";
}

sub fetch_urls {
    my ($dbh, @urls) = @_;

    my @infos = Parallel::Iterator::iterate_as_array(
        {
            workers => scalar @urls,
        },
        sub {
            my ($id, $url) = @_;
            $dbh->{'InactiveDestroy'} = 1; # Don't disconnect on exit
            return ( $id, fetch_url($url) );
        },
        \@urls,
    );
    return @infos;
}

sub fetch_url {
    my ($url) = @_;

    my $ua = LWP::UserAgent->new();
    # Let's lie about who we are, because sites like Facebook won't give us anything useful unless we do
    $ua->agent("Mozilla/5.0 (Windows; U; Windows NT 6.1; en-US; rv:1.9.2.6) Gecko/20100625 Firefox/3.6.6");

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
        print "Timeout!\n";
        return { url => $url }; # timeout
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
            return {
                url           => $url,
                code          => $res->code,
                real_url      => $res->request->uri,
                title         => ( $title || undef ),
                encoding_from => $encoding_from,
                content_type  => $content_type,
            };
        }
        else {
            return {
                url          => $url,
                code         => $res->code,
                real_url     => $res->request->uri,
                content_type => $content_type,
            };
        }
    }
    # Fetch failed, return what we got
    return {
        url => $url,
        code => $res->code,
    };
}

sub store_url {
    my ($info, $dbh, $sth) = @_;

    print "URL:           ", $info->{'url'}, "\n";

    if ( $info->{'code'} ) {
        print "HTTP STATUS:   ", $info->{'code'}, "\n";
    }
    if ( $info->{'real_url'} ) {
        print "RESOLVED URL:  ", $info->{'real_url'}, "\n";
    }
    if ( $info->{'title'} ) {
        print "TITLE:         ", $info->{'title'}, "\n";
    }
    if ( $info->{'encoding_from'} ) {
        print "ENCODING FROM: ", $info->{'encoding_from'}, "\n";
    }
    if ( $info->{'content_type'} ) {
        print "CONTENT TYPE:  ", $info->{'content_type'}, "\n";
    }
    $sth->execute(
        $info->{'url'},
        ( $info->{'code'} || undef ),
        ( $info->{'real_url'} || undef ),
        ( $info->{'title'} ? Encode::encode_utf8( $info->{'title'} ) : undef ),
        ( $info->{'content_type'} ? substr( $info->{'content_type'}, 0, 50 ) : undef ),
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


1;
