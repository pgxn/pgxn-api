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
    return $self;
}

sub update_extension {
    my ($self, $path) = @_;
    my $data = PGXN::API->instance->read_json_from($path);
    $self->_summarize(
        'extensions',
        $data->{extension},
        scalar keys %{ $data->{versions} },
    );
}

sub update_user {
    my ($self, $path) = @_;
    my $data = PGXN::API->instance->read_json_from($path);
    $self->_summarize(
        'users',
        $data->{nickname},
        scalar keys %{ $data->{releases} },
    );
}

sub update_tag {
    my ($self, $path) = @_;
    my $data = PGXN::API->instance->read_json_from($path);
    $self->_summarize(
        'tags',
        $data->{tag},
        scalar keys %{ $data->{releases} },
    );
}

__PACKAGE__->meta->make_immutable;

1;
__END__
