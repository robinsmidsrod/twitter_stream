use strict;
use warnings;

package TwitterStream;
use Moose;

use Data::UUID ();
use DBI ();
use File::HomeDir ();
use Path::Class::Dir ();
use Config::Any ();

sub BUILD {
    my ($self) = @_;
    die "Please specify 'username' in the [twitter] section of '" . $self->config_file . "'\n" unless $self->twitter_username;
    die "Please specify 'password' in the [twitter] section of '" . $self->config_file . "'\n" unless $self->twitter_password;
    die "Please specify 'method' in the [twitter] section of '"   . $self->config_file . "'\n" unless $self->twitter_method;
    die "Please specify 'track' in the [twitter] section of '"    . $self->config_file . "'\n" unless $self->twitter_track;
}

has 'config_file' => (
    is => 'ro',
    isa => 'Path::Class::File',
    lazy_build => 1,
);

sub _build_config_file {
    my ($self) = @_;
    my $home = File::HomeDir->my_data;
    my $conf_file = Path::Class::Dir->new($home)->file('.twitter_stream.ini');
    return $conf_file;
}

has 'config' => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build_config {
    my ($self) = @_;
    my $cfg = Config::Any->load_files({
        use_ext => 1,
        files   => [ $self->config_file ],
    });
    foreach my $config_entry ( @{ $cfg } ) {
        my ($filename, $config) = %{ $config_entry };
        warn("Loaded config from file: $filename\n");
        return $config;
    }
    return {};
}

has 'twitter_username' => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => sub { return (shift)->config->{'twitter'}->{'username'}; },
);

has 'twitter_password' => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => sub { return (shift)->config->{'twitter'}->{'password'}; },
);

has 'twitter_method' => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => sub { return (shift)->config->{'twitter'}->{'method'}; },
);

has 'twitter_track' => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => sub { return (shift)->config->{'twitter'}->{'track'}; },
);

has 'dbh' => (
    is => 'ro',
    isa => 'DBI::db',
    lazy_build => 1,
);

sub _build_dbh {
    my ($self) = @_;

    my $dbh = DBI->connect(
        'dbi:Pg:dbname=twitter_stream',
        "",
        "",
        {
            AutoCommit => 0,
        }
    );
    die("Can't connect to database!") unless $dbh;

    # Return data from DB already decoded as native perl string
    $dbh->{'pg_enable_utf8'} = 1;

    # Silence database warnings
    $dbh->{'PrintError'} = 0;

    return $dbh;
}

has '_uuid_generator' => (
    is      => 'ro',
    isa     => 'Data::UUID',
    default => sub { Data::UUID->new; },
);

sub new_uuid {
    my ($self) = @_;
    return $self->_uuid_generator->create_str();
}

sub parse_date {
    my ( $self, $str ) = @_;
    confess("Please specify a timestamp string") unless $str;

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

sub store_mention {
    my ( $self, $mention_row, $verified_url_id ) = @_;
    confess("No verified_url_id specified") unless $verified_url_id;

    print "Storing mention of " . $verified_url_id . "\n";

    $self->dbh->pg_savepoint("store_mention");

    my $mention_delete_sth = $self->dbh->prepare("DELETE FROM mention WHERE id = ?");

    my @precision = ( 'day', 'week', 'month', 'year' );

    if ( $mention_row->{'keyword_id'} ) {
        # Create record in mention_day/week/month/year_keyword
        print "      with keyword " . $mention_row->{'keyword_id'} . "\n";
        foreach my $precision ( @precision ) {
            $self->dbh->pg_savepoint("insert_mention_keyword_$precision");
            my $sth = $self->dbh->prepare(<<"EOM");
INSERT INTO mention_${precision}_keyword (mention_at, verified_url_id, keyword_id, mention_count)
VALUES ( date_trunc('$precision', ?::date)::date, ?, ?, 1)
EOM
            $sth->execute(
                $mention_row->{'mention_at'},
                $verified_url_id,
                $mention_row->{'keyword_id'},
            );
            if ( $self->dbh->err ) {
                $self->dbh->pg_rollback_to("insert_mention_keyword_$precision");
                my $update_sth = $self->dbh->prepare(<<"EOM");
UPDATE mention_${precision}_keyword SET mention_count = mention_count + 1
WHERE mention_at = date_trunc('$precision', ?::date)::date AND verified_url_id = ? AND keyword_id = ?
EOM
                $update_sth->execute(
                    $mention_row->{'mention_at'},
                    $verified_url_id,
                    $mention_row->{'keyword_id'},
                );
                if ( $self->dbh->err ) {
                    print "Database error occured: ", $self->dbh->errstr, "\n";
                    $self->dbh->pg_rollback_to("store_mention");
                    return;
                }
            }
        }

        # Delete mention record (if exists)
        if ( $mention_row->{'id'} ) {
            $mention_delete_sth->execute( $mention_row->{'id'} );
            if ( $self->dbh->err ) {
                print "Database error occured: ", $self->dbh->errstr, "\n";
                $self->dbh->pg_rollback_to("store_mention");
                return;
            }
        }

        print "Mention (with keyword) stored OK.\n";
        return;
    }

    # Create record in mention_day/week/month/year
    foreach my $precision ( @precision ) {
        $self->dbh->pg_savepoint("insert_mention_$precision");
        my $sth = $self->dbh->prepare(<<"EOM");
INSERT INTO mention_${precision} (mention_at, verified_url_id, mention_count)
VALUES ( date_trunc('$precision', ?::date)::date, ?, 1)
EOM
        $sth->execute(
            $mention_row->{'mention_at'},
            $verified_url_id,
        );
        if ( $self->dbh->err ) {
            $self->dbh->pg_rollback_to("insert_mention_$precision");
            my $update_sth = $self->dbh->prepare(<<"EOM");
UPDATE mention_${precision} SET mention_count = mention_count + 1
WHERE mention_at = date_trunc('$precision', ?::date)::date AND verified_url_id = ?
EOM
            $update_sth->execute(
                $mention_row->{'mention_at'},
                $verified_url_id,
            );
            if ( $self->dbh->err ) {
                print "Database error occured: ", $self->dbh->errstr, "\n";
                $self->dbh->pg_rollback_to("store_mention");
                return;
            }
        }
    }

    # Delete mention record (if exists)
    if ( $mention_row->{'id'} ) {
        $mention_delete_sth->execute( $mention_row->{'id'} );
        if ( $self->dbh->err ) {
            print "Database error occured: ", $self->dbh->errstr, "\n";
            $self->dbh->pg_rollback_to("store_mention");
            return;
        }
    }

    print "Mention stored OK.\n";
    return;
}

no Moose;
__PACKAGE__->meta->make_immutable();

1;
