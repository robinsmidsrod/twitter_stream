#!/usr/bin/env perl

use strict;
use warnings;

use LWP::UserAgent ();
use Encode ();
use HTML::Encoding ();
use HTML::Entities ();
use DBI ();
use Parallel::Iterator ();
use Data::UUID ();

# Lots of UTF8 in Twitter data...
binmode STDOUT, ":utf8";

run($ARGV[0] || 5); # Set concurrency to 5 (bit.ly's default rate limit)

exit;

############################################

sub run {
    my ($concurrency) = @_;

    my $dbh = DBI->connect('dbi:Pg:dbname=twitter_stream', "", "", { AutoCommit => 0 } );
    die("Can't connect to database") unless $dbh;
    $dbh->{'pg_enable_utf8'} = 1; # Return data from DB already decoded

    my $fetch_sth = $dbh->prepare(<<'EOM');
SELECT id,url
FROM url
WHERE url.fetched_at IS NULL
LIMIT ?
EOM
    while( 1 ) {
        $fetch_sth->execute($concurrency);
        my @urls;
        while( my ($id, $url) = $fetch_sth->fetchrow_array() ) {
            push @urls, [ $id, $url ];
        }
        if ( @urls > 0 ) {
            foreach my $info ( fetch_urls($dbh, @urls) ) {
                store_url( $info, $dbh );
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

    # Dereference
    my $id = $url->[0];
    $url = $url->[1];

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
        return {
          id => $id,
         url => $url
        }; # timeout
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
                id            => $id,
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
                id           => $id,
                url          => $url,
                code         => $res->code,
                real_url     => $res->request->uri,
                content_type => $content_type,
            };
        }
    }
    # Fetch failed, return what we got
    return {
        id   => $id,
        url  => $url,
        code => $res->code,
    };
}

sub store_url {
    my ($info, $dbh) = @_;

    print "ID:            ", $info->{'id'}, "\n";
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

    my $insert_sth = $dbh->prepare(<<'EOM');
INSERT INTO url (id,url,fetched_at,response_code,title,content_type)
VALUES (?,?,current_timestamp,?,?,?)
EOM

    my $update_fail_sth = $dbh->prepare(<<'EOM');
UPDATE url SET
 fetched_at = current_timestamp,
 response_code = ?
WHERE id = ?
EOM

    my $update_success_sth = $dbh->prepare(<<'EOM');
UPDATE url SET
 fetched_at = current_timestamp,
 redirect_id = ?,
 response_code = ?,
 title = ?,
 content_type = ?
WHERE id = ?
EOM

    if ( $info->{'real_url'} ) {
        # A URL was actually resolved, let's try to link it
        my $url_id = new_uuid();
        $insert_sth->execute(
            $url_id,
            $info->{'real_url'},
            ( $info->{'code'} || undef ),
            ( $info->{'title'} ? Encode::encode_utf8( $info->{'title'} ) : undef ),
            ( $info->{'content_type'} ? substr( $info->{'content_type'}, 0, 50 ) : undef ),
        );
        if ( $dbh->err ) {
            $dbh->rollback();
            my $sth = $dbh->prepare("select id from url where url = ?");
            $sth->execute( $info->{'real_url'} );
            ($url_id) = $sth->fetchrow_array();
            if ( $dbh->err ) {
                $dbh->rollback();
            }
            else {
                $dbh->commit();
            }
        }
        else {
            $dbh->commit();
        }
        # If id of resolved url was found, update original
        if ( $url_id ) {
            # First store on original (shortened URL)
            $update_success_sth->execute(
                $url_id, # Store redirect to yourself, makes querying easier
                ( $info->{'code'} || undef ),
                ( $info->{'title'} ? Encode::encode_utf8( $info->{'title'} ) : undef ),
                ( $info->{'content_type'} ? substr( $info->{'content_type'}, 0, 50 ) : undef ),
                $info->{'id'},
            );
            # Then update the URL pointed to (expanded)
            $update_success_sth->execute(
                $url_id, # Store redirect to yourself, makes querying easier
                ( $info->{'code'} || undef ),
                ( $info->{'title'} ? Encode::encode_utf8( $info->{'title'} ) : undef ),
                ( $info->{'content_type'} ? substr( $info->{'content_type'}, 0, 50 ) : undef ),
                $url_id,
            );
            if ( $dbh->err ) {
                $dbh->rollback();
            }
            else {
                $dbh->commit();
            }
        }
    }
    else {
        # We couldn't resolve the URL, log attempt
        $update_fail_sth->execute(
            $info->{'response_code'},
            $info->{'id'},
        );
        if ( $dbh->err ) {
            print "Rollback because '" . $dbh->errstr . "'!\n";
            $dbh->rollback();
        }
        else {
            $dbh->commit();
        }
    }
    print "-" x 79, "\n";

}

sub new_uuid {
    return Data::UUID->new->create_str();
}

1;
