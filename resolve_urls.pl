#!/usr/bin/env perl

use strict;
use warnings;

use lib 'lib';

use LWP::UserAgent ();
use Encode ();
use HTML::Encoding ();
use HTML::Entities ();
#use DBD::Pg qw(:pg_types);

use TwitterStream;

# Lots of UTF8 in Twitter data...
binmode STDOUT, ":utf8";

run();

exit;

############################################

sub run {

    my $pid = $$; # Key by process id
    my $ts = TwitterStream->new();
    my $dbh = $ts->dbh;

    my $mention_select_sth = $dbh->prepare('SELECT * FROM mention WHERE verifier_process_id = ? ORDER BY mention_at DESC LIMIT 1');
    my $mention_lock_sth = $dbh->prepare('UPDATE mention SET verifier_process_id = ? WHERE url_id = ( SELECT url_id FROM mention WHERE verifier_process_id = 0 ORDER BY mention_at DESC LIMIT 1 )');
    my $mention_unlock_sth = $dbh->prepare('UPDATE mention SET verifier_process_id = 0 WHERE verifier_process_id = ?');

    my $url_select_sth = $dbh->prepare('SELECT * FROM url WHERE verifier_process_id = ? AND id = ?');
    my $url_lock_sth = $dbh->prepare('UPDATE url SET verifier_process_id = ? WHERE id = ? AND verifier_process_id = 0');
    my $url_unlock_sth = $dbh->prepare('UPDATE url SET verifier_process_id = 0 WHERE verifier_process_id = ?');

    while( 1 ) {
        # Lock mention/url table to set verifier_process_id
        $dbh->do("LOCK TABLE mention, url IN EXCLUSIVE MODE");
#        if ( $dbh->err ) {
#            $dbh->rollback();
#            next;
#        }

        # Tag mention records with this process' pid
        $mention_lock_sth->execute($pid);
#        if ( $dbh->err ) {
#            $dbh->rollback();
#            next;
#        }
        $mention_select_sth->execute($pid);
#        if ( $dbh->err ) {
#            $dbh->rollback();
#            next;
#        }
        my $mention_row = $mention_select_sth->fetchrow_hashref();
#        if ( $dbh->err ) {
#            $dbh->rollback();
#            next;
#        }
        unless ( ref($mention_row) eq 'HASH' and keys %$mention_row > 0 ) {
            $dbh->rollback(); # No record found, abort work (will release exclusive locks)
            print "Sleeping (no mention found)...\n";
            sleep(1);
            next; # Nothing found, so skip it
        }

        # Tag url record with this process' pid
        $url_lock_sth->execute( $pid, $mention_row->{'url_id'} );
        if ( $dbh->err ) {
            print "Error while tagging 'url' record: ", $dbh->errstr, "\n";
            $dbh->rollback(); # Will release exclusive lock
            next;
        }
        else {
            $dbh->commit(); # Will also release exclusive lock
        }

        # Fetch record according to pid
        $url_select_sth->execute( $pid, $mention_row->{'url_id'} );
 #       if ( $dbh->err ) {
 #           $dbh->rollback();
 #           next;
 #       }
        my $url_row = $url_select_sth->fetchrow_hashref();
 #       if ( $dbh->err ) {
 #           $dbh->rollback();
 #           next;
 #       }
        unless ( ref($url_row) eq 'HASH' and keys %$url_row > 0 ) {
            $dbh->rollback(); # No record found, abort work
            print "Sleeping (no url found)...\n";
            sleep(1);
            next;
        }

        # Do work with url record
        handle_url( $ts, $url_row );

        # Reset "lock" on url and mention record(s)
        $url_unlock_sth->execute( $pid );
        $mention_unlock_sth->execute( $pid );
        if ( $dbh->err ) {
            print "Database error occured: ", $dbh->errstr, "\n";
            $dbh->rollback();
        }
        else {
            $dbh->commit();
        }

        print "-" x 79, "\n";

    }

    print "Exiting...\n";
}

sub handle_url {
    my ($ts, $url_row) = @_;

    my $dbh = $ts->dbh;

    # Verify URL and update record ( in memory update as well )
    unless ( $url_row->{'is_verified'} ) {
        verify_url( $ts, $url_row );
    }

    # If verification failed for some reason, bail out
    unless ( $url_row->{'verified_url_id'} ) {
        print "URL '" . $url_row->{'url'} . "' not yet resolved successfully!\n";
        return;
    }

    $dbh->pg_savepoint("handle_url");

    # Fetch all mentions of this URL and store (and remove) mention
    my $sth = $dbh->prepare("SELECT * FROM mention WHERE verifier_process_id = ? AND url_id = ?");
    $sth->execute( $$, $url_row->{'id'} );
    if ( $dbh->err ) {
        print "Database error occured: ", $dbh->errstr, "\n";
        $dbh->pg_rollback_to("handle_url");
        return;
    }
    while ( my $mention_row = $sth->fetchrow_hashref() ) {
        if ( $dbh->err ) {
            print "Database error occured: ", $dbh->errstr, "\n";
            $dbh->pg_rollback_to("handle_url");
            return;
        }
        $ts->store_mention( $mention_row, $url_row->{'verified_url_id'} );
    }

    return;
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

    my $url = $res->request->uri;
    $url->path('') if $url->path eq '/'; # Strip trailing slash for root path

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

    return;
}

1;
