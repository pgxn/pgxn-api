package PGXN::API::Stats v0.9.0;

use 5.12.0;
use utf8;
use Moose;
use PGXN::API;
use File::Spec::Functions qw(catfile catdir);
use File::Path qw(make_path);
use DBIx::Connector;
use DBD::SQLite;
use List::Util qw(sum first);
use namespace::autoclean;

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
                        date      TIMESTAMP NOT NULL
                    )
                });
                $dbh->do(qq{
                    CREATE TABLE $_ (
                        name      TEXT NOT NULL PRIMARY KEY,
                        rel_count INT  NOT NULL
                    )
                }) for qw(extensions users tags);
                $dbh->do(q{PRAGMA schema_version = 1});
                $dbh->commit;
                return;
            }
        }},
    });
    $conn->mode('fixup');

    $conn;
});


sub _summarize {
    my ($self, $thing, $name, $count, $date) = @_;
    $self->conn->txn(sub {
        my $dbh = shift;
        $dbh->do(
            "INSERT INTO $thing (rel_count, name) VALUES (?, ?)",
            undef, $count, $name,
        ) if $dbh->do(
            "UPDATE $thing SET rel_count = ? WHERE name = ?",
            undef, $count, $name,
        ) eq '0E0';
    });
    return $self;
}

sub update_dist {
    my ($self, $path) = @_;
    my $data = PGXN::API->instance->read_json_from($path);
    my $rel  = $data->{releases}{ first { $data->{releases}{$_} } qw(stable testing unstable) }[0];
    my @params = (
        undef,
        sum(map { scalar @{ $data->{releases}{$_} } } keys %{ $data->{releases} }),
        $rel->{version},
        $rel->{date},
        $data->{name},
    );
    $self->conn->txn(sub {
        my $dbh = shift;
        $dbh->do(
            'INSERT INTO dists (rel_count, version, date, name) VALUES (?, ?, ?, ?)',
            @params
        ) if $dbh->do(
            "UPDATE dists SET rel_count = ?, version = ?, date = ? WHERE name = ?",
            @params
        ) eq '0E0';
    });
    $self->dists_updated(1);
}

sub update_extension {
    my ($self, $path) = @_;
    my $data = PGXN::API->instance->read_json_from($path);
    $self->_summarize(
        'extensions',
        $data->{extension},
        scalar keys %{ $data->{versions} },
    );
    $self->extensions_updated(1);
}

sub update_user {
    my ($self, $path) = @_;
    my $data = PGXN::API->instance->read_json_from($path);
    $self->_summarize(
        'users',
        $data->{nickname},
        scalar keys %{ $data->{releases} },
    );
    $self->users_updated(1);
}

sub update_tag {
    my ($self, $path) = @_;
    my $data = PGXN::API->instance->read_json_from($path);
    $self->_summarize(
        'tags',
        $data->{tag},
        scalar keys %{ $data->{releases} },
    );
    $self->tags_updated(1);
}

sub write_stats {
    my $self = shift;
    $self->write_dist_stats;
    $self->write_extension_stats;
    $self->write_user_stats;
    $self->write_tag_stats;
}

sub write_dist_stats {
    my $self = shift;
    $self->conn->run(sub {
        my $dbh = shift;
        my $count = $dbh->selectcol_arrayref(
            'SELECT COUNT(*) FROM dists'
        )->[0];

        my $data = {};
        my $sth = $dbh->prepare(q{
            SELECT name AS dist, version, date
              FROM dists
             ORDER BY date DESC
             LIMIT 128
          });

        $sth->execute;
        my @recent;

        while (my $row = $sth->fetchrow_hashref) { push @recent => $row }

        my $api = PGXN::API->instance;
        $api->write_json_to(
            catfile($api->doc_root, qw(stats dists.json)),
            { count => $count, recent => \@recent },
        );
    });

    return $self;
}

sub _write_stats {
    my ($self, $things, $label) = @_;

    $self->conn->run(sub {
        my $dbh = shift;
        my $count = $dbh->selectcol_arrayref(
            "SELECT COUNT(*) FROM $things"
        )->[0];

        my $sth = $dbh->prepare(qq{
            SELECT name, rel_count
              FROM $things
             ORDER BY rel_count DESC
             LIMIT 128
          });

        $sth->execute;
        $sth->bind_columns(\my ($name, $rel_count));
        my $data;
        while ($sth->fetch) {
            $data->{$name} = $rel_count;
        }

        my $api = PGXN::API->instance;
        $api->write_json_to(
            catfile($api->doc_root, 'stats', "$things.json"),
            {count => $count, $label => $data },
        );
    });

    return $self;
}

sub write_user_stats {
    shift->_write_stats('users', 'prolific');
}

sub write_tag_stats {
    shift->_write_stats('tags', 'popular');
}

sub write_extension_stats {
    shift->_write_stats('extensions', 'prolific');
}

__PACKAGE__->meta->make_immutable;

1;
__END__
