package PGXN::API::Stats v0.9.0;

use 5.12.0;
use utf8;
use Moose;
use PGXN::API;
use File::Spec::Functions qw(catfile catdir);
use File::Path qw(make_path);
use DBIx::Connector;
use DBD::SQLite;
use Encode;
use List::Util qw(sum first);
use namespace::autoclean;

# XXX Consider moving this functionality to PGXN::Manager so it's on all mirrors?

has dists_updated      => (is => 'rw', isa => 'Bool', default => 0);
has extensions_updated => (is => 'rw', isa => 'Bool', default => 0);
has tags_updated       => (is => 'rw', isa => 'Bool', default => 0);
has users_updated      => (is => 'rw', isa => 'Bool', default => 0);

has conn => (is => 'rw', isa => 'DBIx::Connector', lazy => 1, default => sub {
    my $dir   = catdir +PGXN::API->instance->doc_root, '_index';
    make_path $dir;
    my $db   = catfile $dir, 'stats.db';
    my $conn = DBIx::Connector->new("dbi:SQLite:dbname=$db", '', '', {
        PrintError     => 0,
        RaiseError     => 1,
        AutoCommit     => 1,
        sqlite_unicode => 1,
        Callbacks      => { connected => sub {
            my $dbh = shift;
            my ($version) = $dbh->selectrow_array('PRAGMA schema_version');
            # Build the schema.
            if ($version < 1) {
                $dbh->begin_work;
                $dbh->do(q{
                    CREATE TABLE dists (
                        name      TEXT      NOT NULL PRIMARY KEY,
                        rel_count INT       NOT NULL,
                        version   TEXT      NOT NULL,
                        date      TIMESTAMP NOT NULL,
                        user      TEXT      NOT NULL,
                        abstract  TEXT      NOT NULL
                    )
                });
                $dbh->do(q{
                    CREATE TABLE extensions (
                        name      TEXT      NOT NULL PRIMARY KEY,
                        rel_count INT       NOT NULL,
                        dist      TEXT      NOT NULL,
                        version   TEXT      NOT NULL,
                        date      TIMESTAMP NOT NULL,
                        user      TEXT      NOT NULL,
                        abstract  TEXT      NOT NULL
                    )
                });
                $dbh->do(q{
                    CREATE TABLE users (
                        name      TEXT      NOT NULL PRIMARY KEY,
                        rel_count INT       NOT NULL,
                        full_name TEXT      NOT NULL
                    )
                });
                $dbh->do(q{
                    CREATE TABLE tags (
                        name      TEXT      NOT NULL PRIMARY KEY,
                        rel_count INT       NOT NULL
                    )
                });
                $dbh->do(q{PRAGMA schema_version = 1});
                $dbh->commit;
                return;
            }
        }},
    });
    $conn->mode('fixup');

    $conn;
});

sub update_dist {
    my ($self, $path) = @_;
    my $api  = PGXN::API->instance;
    my $data = $api->read_json_from($path);
    my $rel  = $data->{releases}{ first { $data->{releases}{$_} } qw(stable testing unstable) }[0];
    my $meta = $api->read_json_from(
        catfile $api->mirror_root, $api->uri_templates->{meta}->process({
            dist    => $data->{name},
            version => $rel->{version},
        })->path_segments
    );

    my @params = map { encode_utf8 $_ } (
        sum(map { scalar @{ $data->{releases}{$_} } } keys %{ $data->{releases} }),
        $meta->{version},
        $meta->{date},
        $meta->{user},
        $meta->{abstract},
        $meta->{name},
    );

    $self->conn->txn(sub {
        my $dbh = shift;
        $dbh->do(q{
            INSERT INTO dists (rel_count, version, date, user, abstract, name)
            VALUES (?, ?, ?, ?, ?, ?)
        }, undef, @params) if $dbh->do(q{
            UPDATE dists
               SET rel_count = ?, version = ?, date = ?, user = ?, abstract = ?
             WHERE name = ?
         }, undef, @params) eq '0E0';
    });
    $self->dists_updated(1);
}

sub update_extension {
    my ($self, $path) = @_;
    my $api  = PGXN::API->instance;
    my $data = PGXN::API->instance->read_json_from($path);
    my $meta = $api->read_json_from(
        catfile $api->mirror_root, $api->uri_templates->{meta}->process(
            $data->{ $data->{latest} }
        )->path_segments
    );

    my @params = map { encode_utf8 $_ } (
        scalar keys %{ $data->{versions} },
        $meta->{name},
        $meta->{version},
        $meta->{date},
        $meta->{user},
        $meta->{provides}{ $data->{extension} }{abstract},
        $data->{extension},
    );

    $self->conn->txn(sub {
        my $dbh = shift;
        $dbh->do(q{
            INSERT INTO extensions (rel_count, dist, version, date, user, abstract, name)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        }, undef, @params) if $dbh->do(q{
            UPDATE extensions
               SET rel_count = ?, dist = ?, version = ?, date = ?, user = ?, abstract = ?
             WHERE name = ?
         }, undef, @params) eq '0E0';
    });
    $self->extensions_updated(1);
}

sub update_user {
    my ($self, $path) = @_;
    my $data = PGXN::API->instance->read_json_from($path);
    my @params = map { encode_utf8 $_ } (
        scalar keys %{ $data->{releases} },
        $data->{name},
        $data->{nickname},
    );

    $self->conn->txn(sub {
        my $dbh = shift;
        $dbh->do(
            'INSERT INTO users (rel_count, full_name, name) VALUES (?, ?, ?)',
            undef, @params
        ) if $dbh->do(
            'UPDATE users SET rel_count = ?, full_name = ? WHERE name = ?',
            undef, @params
        ) eq '0E0';
    });
    $self->users_updated(1);
}

sub update_tag {
    my ($self, $path) = @_;
    my $data = PGXN::API->instance->read_json_from($path); 
    my @params = map { encode_utf8 $_ } (
        scalar keys %{ $data->{releases} },
        $data->{tag},
    );

   $self->conn->txn(sub {
        my $dbh = shift;
        $dbh->do(
            'INSERT INTO tags (rel_count, name) VALUES (?, ?)',
            undef, @params
        ) if $dbh->do(
            'UPDATE tags SET rel_count = ? WHERE name = ?',
            undef, @params
        ) eq '0E0';
    });
    $self->tags_updated(1);
}

sub write_stats {
    my $self = shift;
    $self->write_dist_stats;
    $self->write_extension_stats;
    $self->write_user_stats;
    $self->write_tag_stats;
}

sub _write_stats {
    my ($self, $things, $label, $cols) = @_;

    $self->conn->run(sub {
        my $dbh = shift;
        my $count = $dbh->selectcol_arrayref(
            "SELECT COUNT(*) FROM $things"
        )->[0];

        my $sth = $dbh->prepare(qq{
            SELECT $cols
              FROM $things
             ORDER BY rel_count DESC
             LIMIT 128
          });

        $sth->execute;
        my @sample;
        while (my $row = $sth->fetchrow_hashref) { push @sample => $row }

        my $api = PGXN::API->instance;
        $api->write_json_to(
            catfile($api->doc_root, 'stats', "$things.json"),
            {count => $count, $label => \@sample },
        );
    });

    return $self;
}

sub write_dist_stats {
    shift->_write_stats(
        'dists', 'recent',
        'name AS dist, version, date, user, abstract',
    );
}

sub write_user_stats {
    shift->_write_stats(
        'users', 'prolific',
        'name AS nickname, rel_count AS dist_count'
    );
}

sub write_tag_stats {
    shift->_write_stats(
        'tags', 'popular',
        'name AS tag, rel_count AS dist_count'
    );
}

sub write_extension_stats {
    shift->_write_stats(
        'extensions', 'prolific',
        'rel_count AS releases, name AS extension, dist, version, date, user, abstract',
    );
}

__PACKAGE__->meta->make_immutable;

1;
__END__
