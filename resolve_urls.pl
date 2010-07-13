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

run();

exit;

############################################

sub run {

    my $dbh = DBI->connect('dbi:Pg:dbname=twitter_stream', "", "", { AutoCommit => 0 } );
    die("Can't connect to database") unless $dbh;
    $dbh->{'pg_enable_utf8'} = 1; # Return data from DB already decoded
    $dbh->{'PrintError'} = 0; # Silence database warnings

    my $pid = $$; # Key by process id

    my $mention_select_sth = $dbh->prepare('SELECT * FROM mention WHERE verifier_process_id = ? ORDER BY mention_at DESC LIMIT 1');
    my $mention_lock_sth = $dbh->prepare('UPDATE mention SET verifier_process_id = ? WHERE url_id = ( SELECT url_id FROM mention WHERE verifier_process_id = 0 ORDER BY mention_at DESC LIMIT 1 )');
    my $mention_unlock_sth = $dbh->prepare('UPDATE mention SET verifier_process_id = 0 WHERE verifier_process_id = ?');

    my $url_select_sth = $dbh->prepare('SELECT * FROM url WHERE verifier_process_id = ? AND id = ?');
    my $url_lock_sth = $dbh->prepare('UPDATE url SET verifier_process_id = ? WHERE id = ? AND verifier_process_id = 0');
    my $url_unlock_sth = $dbh->prepare('UPDATE url SET verifier_process_id = 0 WHERE verifier_process_id = ?');

    while( 1 ) {
        # Set lock on mention record
        $mention_lock_sth->execute($pid);
        if ( $dbh->err ) {
            $dbh->rollback();
        }
        else {
            $dbh->commit();
        }
        $mention_select_sth->execute($pid);
        my $mention_row = $mention_select_sth->fetchrow_hashref();
        unless ( ref($mention_row) eq 'HASH' and keys %$mention_row > 0 ) {
            $mention_unlock_sth->execute($pid);
            print "Sleeping (no mention found)...\n";
            sleep(1);
            next; # Nothing found, so skip it
        }

        # Set lock on url record
        $url_lock_sth->execute( $pid, $mention_row->{'url_id'} );
        if ( $dbh->err ) {
            $dbh->rollback();
        }
        else {
            $dbh->commit();
        }

        # Fetch record according to pid
        $url_select_sth->execute( $pid, $mention_row->{'url_id'} );
        my $url_row = $url_select_sth->fetchrow_hashref();
        if ( ref($url_row) eq 'HASH' and keys %$url_row > 0 ) {
            handle_url( $dbh, $url_row );

            # Reset "lock" on url and mention record(s)
            $url_unlock_sth->execute( $pid );
            $mention_unlock_sth->execute( $pid );
            if ( $dbh->err ) {
                $dbh->rollback();
            }
            else {
                $dbh->commit();
            }

            print "-" x 79, "\n";
        }
        else {
            print "Sleeping (no url found)...\n";
            sleep(1);
        }

    }

    print "Exiting...\n";
}

sub handle_url {
    my ($dbh, $url_row) = @_;

    # Verify URL and update record ( in memory update as well )
    unless ( $url_row->{'is_verified'} ) {
        verify_url( $dbh, $url_row );
    }

    # If verification failed for some reason, bail out
    if ( $url_row->{'verify_failed'} ) {
        print "Verify (has) failed for '" . $url_row->{'url'} . "!\n";
        return;
    }

    # Fetch all mentions of this URL
    # NB: We store all records in memory because we're going to break the
    # transaction in store_mention()
    my $sth = $dbh->prepare("SELECT * FROM mention WHERE url_id = ?");
    $sth->execute( $url_row->{'id'} );
    my @mentions;
    while ( my $mention = $sth->fetchrow_hashref() ) {
        push @mentions, $mention;
    }

    # Store (and remove) mention
    foreach my $mention_row ( @mentions ) {
        store_mention( $dbh, $mention_row, $url_row );
    }

    return;
}

sub verify_url {
    my ( $dbh, $url_row ) = @_;

    print "Verifying URL: " . $url_row->{'url'} . "\n";

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
            $dbh->rollback();
        }
        else {
            $dbh->commit();
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
            $dbh->rollback();
        }
        else {
            $dbh->commit();
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

    # Create verified_url record with $url, $content_type and $title + $url_row data
    my $verified_url_sth = $dbh->prepare(<<'EOM');
INSERT INTO verified_url (id, url, verified_at,       content_type, title, first_mention_id, first_mention_at, first_mention_by_name, first_mention_by_user)
VALUES                   (?,  ?,   current_timestamp, ?,            ?,     ?,                ?,                ?,                     ?                    )
EOM

    my $verified_url_id = new_uuid();
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
        $dbh->rollback();
        my $sth = $dbh->prepare("SELECT id FROM verified_url WHERE url = ?");
        $sth->execute($url);
        ($verified_url_id) = $sth->fetchrow_array();
        if ( $dbh->err ) {
            $dbh->rollback();
            undef $verified_url_id;
        }
        else {
            $dbh->commit();
        }
    }
    else {
        $dbh->commit();
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
            $dbh->rollback();
        }
        else {
            $dbh->commit();
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
        $dbh->rollback();
    }
    else {
        $dbh->commit();
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

sub store_mention {
    my ( $dbh, $mention_row, $url_row ) = @_;

    print "Storing mention of " . $url_row->{'verified_url_id'} . "\n";

    my @precision = ( 'day', 'week', 'month', 'year' );

    my $fail = 0;

    if ( $mention_row->{'keyword_id'} ) {
        # Create record in mention_day/week/month/year_keyword
        print "    with keyword " . $mention_row->{'keyword_id'} . "\n";
        foreach my $precision ( @precision ) {
            my $sth = $dbh->prepare(<<"EOM");
INSERT INTO mention_${precision}_keyword (mention_at, verified_url_id, keyword_id, mention_count)
VALUES ( date_trunc('$precision', ?::date)::date, ?, ?, 1)
EOM
            $sth->execute(
                $mention_row->{'mention_at'},
                $url_row->{'verified_url_id'},
                $mention_row->{'keyword_id'},
            );
            if ( $dbh->err ) {
                $dbh->rollback();
                my $update_sth = $dbh->prepare(<<"EOM");
UPDATE mention_${precision}_keyword SET mention_count = mention_count + 1
WHERE mention_at = date_trunc('$precision', ?::date)::date AND verified_url_id = ? AND keyword_id = ?
EOM
                $update_sth->execute(
                    $mention_row->{'mention_at'},
                    $url_row->{'verified_url_id'},
                    $mention_row->{'keyword_id'},
                );
                if ( $dbh->err ) {
                    $dbh->rollback();
                    $fail = 1;
                }
                else {
                    $dbh->commit();
                }
            }
            else {
                $dbh->commit();
            }
        }
    }
    else {
        # Create record in mention_day/week/month/year
        foreach my $precision ( @precision ) {
            my $sth = $dbh->prepare(<<"EOM");
INSERT INTO mention_${precision} (mention_at, verified_url_id, mention_count)
VALUES ( date_trunc('$precision', ?::date)::date, ?, 1)
EOM
            $sth->execute(
                $mention_row->{'mention_at'},
                $url_row->{'verified_url_id'},
            );
            if ( $dbh->err ) {
                $dbh->rollback();
                my $update_sth = $dbh->prepare(<<"EOM");
UPDATE mention_${precision} SET mention_count = mention_count + 1
WHERE mention_at = date_trunc('$precision', ?::date)::date AND verified_url_id = ?
EOM
                $update_sth->execute(
                    $mention_row->{'mention_at'},
                    $url_row->{'verified_url_id'},
                );
                if ( $dbh->err ) {
                    $dbh->rollback();
                    $fail = 1;
                }
                else {
                    $dbh->commit();
                }
            }
            else {
                $dbh->commit();
            }
        }
    }

    # Delete mention if everything went ok
    unless ( $fail ) {
        my $delete_sth = $dbh->prepare("DELETE FROM mention WHERE id = ?");
        $delete_sth->execute( $mention_row->{'id'} );
        if ( $dbh->err ) {
            $dbh->rollback();
            print "Database error deleting mention " . $mention_row->{'id'} . "\n";
        }
        else {
            $dbh->commit();
            print "Mention stored OK\n";
        }
    }

    return;
}

sub new_uuid {
    return Data::UUID->new->create_str();
}

1;
