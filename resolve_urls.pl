#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use LWP::UserAgent ();
use Encode ();
use HTML::Encoding ();
use HTML::Entities ();
use Scalar::Util qw(blessed);
#use DBD::Pg qw(:pg_types);

# For cleaning junk query params (utm_*) from URLs
use URI;
use URI::QueryParam;

use TwitterStream;

$0 = 'ts_resolver';

# Lots of UTF8 in Twitter data...
binmode STDOUT, ":utf8";

run();

exit;

############################################

sub run {

    my $pid = $$; # Key by process id
    my $ts = TwitterStream->new();
    my $dbh = $ts->dbh;

    my $concurrency_max = 100;

    my $url_select_sth = $dbh->prepare(<<'EOM');
SELECT u.* FROM (
 SELECT * FROM url
 WHERE (
  is_verified = FALSE
   OR
  ( is_verified = TRUE AND verify_failed = TRUE AND verified_at < (current_timestamp - interval '1 hour') )
 )
 ORDER BY first_mention_at DESC
 LIMIT ? -- max workers
) u
WHERE pg_try_advisory_lock('url'::regclass::integer,u.verify_lock_id::integer)
LIMIT 1;
EOM

    my $url_select_leftover_sth = $dbh->prepare(<<'EOM');
SELECT u.* FROM (
    SELECT url.*
    FROM url join mention on url.id=mention.url_id
    WHERE url.is_verified = TRUE AND verify_failed = FALSE
    ORDER BY first_mention_at DESC
    LIMIT ? -- max workers
) u
WHERE pg_try_advisory_lock('url'::regclass::integer,u.verify_lock_id::integer)
LIMIT 1;
EOM

    my $url_unlock_sth = $dbh->prepare("SELECT pg_advisory_unlock('url'::regclass::integer, verify_lock_id::integer) FROM url WHERE id = ?");

    while( 1 ) {

        # Advisory lock first available 'url' record
        $url_select_sth->execute($concurrency_max);
        if ( $dbh->err ) {
            print "Database error occured: ", $dbh->errstr, "\n";
            $dbh->rollback();
            print "Sleeping a little before trying again...\n";
            sleep(1);
            next;
        }

        # Actually fetch the data from the record
        my $url_row = $url_select_sth->fetchrow_hashref();
        if ( $dbh->err ) {
            print "Database error occured: ", $dbh->errstr, "\n";
            $dbh->rollback();
            print "Sleeping a little before trying again...\n";
            sleep(1);
            next;
        }

        # Try to fetch leftover mentions if no URL record found
        unless ( ref($url_row) eq 'HASH' and keys %$url_row > 0 ) {

            print "Trying leftovers...\n";

            # Try to fetch leftover mentions
            $url_select_leftover_sth->execute($concurrency_max);
            if ( $dbh->err ) {
                print "Database error occured: ", $dbh->errstr, "\n";
                $dbh->rollback();
                print "Sleeping a little before trying again...\n";
                sleep(1);
                next;
            }

            # Actually fetch the data from the record
            $url_row = $url_select_leftover_sth->fetchrow_hashref();
            if ( $dbh->err ) {
                print "Database error occured: ", $dbh->errstr, "\n";
                $dbh->rollback();
                print "Sleeping a little before trying again...\n";
                sleep(1);
                next;
            }

            # Do nothing if nothing found
            unless ( ref($url_row) eq 'HASH' and keys %$url_row > 0 ) {
                $dbh->rollback(); # No record found, abort work
                print "Sleeping (no url record found)...\n";
                sleep(1);
                next;
			}

			print "Leftover found: " . $url_row->{'url'} . "\n";
        }

        # We've got advisory lock (which releases only on disconnect), commit transaction and get to work
        $dbh->commit();

        # Do work with url record
        handle_url( $ts, $url_row );

        # Remove advisory lock on url record
        $url_unlock_sth->execute( $url_row->{'id'} );
        if ( $dbh->err ) {
            print "Database error occured: ", $dbh->errstr, "\n";
            $dbh->rollback();
            print "Sleeping a little before trying again...\n";
            sleep(1);
        }
        else {
            $dbh->commit();
            print "-" x 79, "\n";
        }

    }

    print "Exiting...\n";
}

sub handle_url {
    my ($ts, $url_row) = @_;

    my $dbh = $ts->dbh;

    print "Processing URL: " . $url_row->{'url'} . "\n";

    # Verify URL and update record ( in memory update as well )
    unless ( $url_row->{'verified_url_id'} ) {
        verify_url( $ts, $url_row );
    }

    # If verification failed for some reason, bail out
    unless ( $url_row->{'verified_url_id'} ) {
        print "URL '" . $url_row->{'url'} . "' not yet resolved successfully!\n";
        return;
    }

    # Finalize the changes we did in verification of the URL (if any)
    if ( $dbh->err ) {
        print "Database error occured: ", $dbh->errstr, "\n";
        $dbh->rollback();
        return;
    }
    else {
        $dbh->commit();
    }

    # Fetch all mentions of this URL and store (and remove) mention
    my $sth = $dbh->prepare("SELECT * FROM mention WHERE url_id = ?");
    $sth->execute( $url_row->{'id'} );
    if ( $dbh->err ) {
        print "Database error occured: ", $dbh->errstr, "\n";
        $dbh->rollback();
        return;
    }
    my @mentions;
    while ( my $mention_row = $sth->fetchrow_hashref() ) {
        if ( $dbh->err ) {
            print "Database error occured: ", $dbh->errstr, "\n";
            $dbh->rollback();
            return;
        }
        push @mentions, $mention_row;
    }

    foreach my $mention_row ( @mentions ) {
        $ts->store_mention( $mention_row, $url_row->{'verified_url_id'} );
        if ( $dbh->err ) {
            print "Database error occured: ", $dbh->errstr, "\n";
            $dbh->rollback();
            return;
        }
        else {
            $dbh->commit();
        }
    }

    return 1; # OK
}

sub verify_url {
    my ( $ts, $url_row ) = @_;

    my $dbh = $ts->dbh;

    print "Verifying URL: " . $url_row->{'url'} . "\n";

    $dbh->pg_savepoint("verify_url");

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
            $url_row->{'url'},
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
        die($@) unless $@ eq "alarm\n";
        print "Timeout while fetching '" . $url_row->{'url'} . "'!\n";

        # Inform caller about result
        $url_row->{'is_verified'} = 1;
        $url_row->{'verify_failed'} = 1;

        my $sth = $dbh->prepare("UPDATE url SET is_verified=TRUE, verify_failed=TRUE, verified_at=current_timestamp, verified_url_id=NULL WHERE id = ?");
        $sth->execute( $url_row->{'id'} );
        if ( $dbh->err ) {
            print "Database error occured: ", $dbh->errstr, "\n";
            $dbh->pg_rollback_to("verify_url");
        }
        return;
    }

    if ( $res->code >= 400 and $res->code < 500 ) {
        # Permanent URL error, delete URL + mention record(s)

        print "HTTP error " . $res->code . " while fetching '" . $url_row->{'url'} . "'\n";

        # Inform caller about result
        $url_row->{'is_verified'} = 1;
        $url_row->{'verify_failed'} = 1;

        my $sth = $dbh->prepare("DELETE FROM url WHERE id = ?");
        $sth->execute( $url_row->{'id'} );
        if ( $dbh->err ) {
            print "Database error occured: ", $dbh->errstr, "\n";
            $dbh->pg_rollback_to("verify_url");
        }

        print "Deleted URL record " . $url_row->{'id'} . "\n";

        return;
    }

    if ( $res->code < 200 or $res->code >= 300 ) {
        # Fetch failed, we got something else than 2xx return code (we consider 3xx failure)

        print "HTTP error " . $res->code . " while fetching '" . $url_row->{'url'} . "'!\n";

        # Inform caller about result
        $url_row->{'is_verified'} = 1;
        $url_row->{'verify_failed'} = 1;

        my $sth = $dbh->prepare("UPDATE url SET is_verified=TRUE, verify_failed=TRUE, verified_at=current_timestamp, verified_url_id=NULL WHERE id = ?");
        $sth->execute( $url_row->{'id'} );
        if ( $dbh->err ) {
            print "Database error occured: ", $dbh->errstr, "\n";
            $dbh->pg_rollback_to("verify_url");
        }
        return;
    }

    # Fetch succeeded, extract info
    my $content_type = $res->header('Content-Type');
    $content_type = (split(/;/, $content_type, 2))[0];

    # Get rid of utm_ junk query parameters and some other stuff
    my $url = clean_url($res->request->uri);

    my $title = $content;
    my $encoding_from = "";
    if ( $res->content_charset and Encode::resolve_alias($res->content_charset) ) {
        $encoding_from = "header";
        {
            no warnings 'utf8';
            $title = eval { Encode::decode($res->content_charset, $title); };
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
                $title = eval { Encode::decode($encoding, $title); };
            }
        }
    }
    if ( $title =~ s{\A.*<title>\s*(.+?)\s*</title>.*\Z}{$1}xmsi ) {
        $title =~ s/\s+/ /gms; # trim consecutive whitespace
        $title = HTML::Entities::decode($title); # Get rid of those pesky HTML entities
    }
    else {
        $title = undef;
    }

    $dbh->pg_savepoint("insert_verified_url");

    # Create verified_url record with $url, $content_type and $title + $url_row data
    my $verified_url_sth = $dbh->prepare(<<'EOM');
INSERT INTO verified_url (id, url, verified_at,       content_type, title, first_mention_id, first_mention_at, first_mention_by_name, first_mention_by_user)
VALUES                   (?,  ?,   current_timestamp, ?,            ?,     ?,                ?,                ?,                     ?                    )
EOM

    my $verified_url_id = $ts->new_uuid();
#    $verified_url_sth->bind_param(1, $verified_url_id, { pg_type => PG_UUID });
#    $verified_url_sth->bind_param(2, $url); # VARCHAR
#    $verified_url_sth->bind_param(3, substr( $content_type, 0, 50 ) ); # VARCHAR
#    $verified_url_sth->bind_param(4, defined($title) ? Encode::encode_utf8($title) : undef ); # VARCHAR
#    $verified_url_sth->bind_param(5, $url_row->{'first_mention_id'}, { pg_type => PG_INT8 } );
#    $verified_url_sth->bind_param(6, $url_row->{'first_mention_at'}, { pg_type => PG_TIMESTAMPTZ } );
#    $verified_url_sth->bind_param(7, $url_row->{'first_mention_by_name'} ); # VARCHAR
#    $verified_url_sth->bind_param(8, $url_row->{'first_mention_by_user'} ); # VARCHAR
#    $verified_url_sth->execute();
    $verified_url_sth->execute(
        $verified_url_id,
        $url,
        substr( $content_type, 0, 50 ),
        ( defined($title) ? Encode::encode_utf8($title) : undef ),
        $url_row->{'first_mention_id'},
        $url_row->{'first_mention_at'},
        $url_row->{'first_mention_by_name'},
        $url_row->{'first_mention_by_user'},
    );
    if ( $dbh->err ) {
        $dbh->pg_rollback_to("insert_verified_url");
        my $sth = $dbh->prepare("SELECT id FROM verified_url WHERE url = ?");
        $sth->execute($url);
        ($verified_url_id) = $sth->fetchrow_array();
        if ( $dbh->err ) {
            print "Database error occured: ", $dbh->errstr, "\n";
            $dbh->pg_rollback_to("insert_verified_url");
        }
    }
    unless ( $verified_url_id ) {
        # Storing the verified URL failed in some way, signal failure
        $url_row->{'is_verified'} = 1;
        $url_row->{'verify_failed'} = 1;

        print "Failed resolving verified_url_id for '" . $url . "'!\n";

        # Update the database about verification failure - this might fail as well, because database inconsitency was what brought us here
        # This avoids hammering URLs in repetition because of database errors
        my $sth = $dbh->prepare("UPDATE url SET is_verified=TRUE, verify_failed=TRUE, verified_at=current_timestamp, verified_url_id=NULL WHERE id = ?");
        $sth->execute( $url_row->{'id'} );
        if ( $dbh->err ) {
            print "Database error occured: ", $dbh->errstr, "\n";
            $dbh->pg_rollback_to("verify_url");
        }
        return;
    }

    # Update url record with info about verification
    my $sth = $dbh->prepare("UPDATE url SET is_verified=TRUE, verify_failed=FALSE, verified_at=current_timestamp, verified_url_id=? WHERE id = ?");
    $sth->execute(
        $verified_url_id,
        $url_row->{'id'}
    );
    if ( $dbh->err ) {
        print "Database error occured: ", $dbh->errstr, "\n";
        $dbh->pg_rollback_to("verify_url");
    }

    # Inform caller about result
    $url_row->{'is_verified'} = 1;
    $url_row->{'verify_failed'} = 0;
    $url_row->{'verified_url_id'} = $verified_url_id;

    print "Full URL: ", $url, "\n";
    print "Title: ", $title, "\n" if defined( $title );
    print "Content-Type: ", $content_type, "\n";
    print "Verified OK: ", $verified_url_id, "\n";

    return 1; # OK
}

sub clean_url {
    my ($url) = @_;

    # Do some verification of input, ensure class knows how to manipulate query parameters
    return $url unless blessed($url);
    return $url unless $url->isa('URI');
    return $url->canonical unless $url->can('query_param_delete');

    # Get rid of unwanted Google Analytics tags
    my @blacklisted_query_keys = qw(utm_source utm_medium utm_campaign utm_term);
    $url->query_param_delete($_) for @blacklisted_query_keys;

    # Strip trailing slash for root path
    $url->path('') if $url->path eq '/';

    return $url->canonical;
}

1;
