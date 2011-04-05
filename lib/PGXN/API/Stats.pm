package PGXN::API::Stats v0.9.0;

use 5.12.0;
use utf8;
use Moose;
use PGXN::API;
use File::Spec::Functions qw(catfile catdir);
use File::Path qw(make_path);
use DBIx::Connector;
use DBD::SQLite;
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
                $dbh->do($_) for (
                    q{
                        CREATE TABLE stats (
                            thing TEXT NOT NULL PRIMARY KEY,
                            count INT NOT NULL
                        );
                    },
                    q{
                        CREATE TABLE tags (
                            name       TEXT NOT NULL PRIMARY KEY,
                            dist_count INT NOT NULL
                        );
                    },
                    q{PRAGMA schema_version = 1},
                );
                $dbh->commit;
                return;
            }
        }},
    });
    $conn->mode('fixup');

    $conn;
});

sub summarize_tag {
    my ($self, $path) = @_;
    
}

__PACKAGE__->meta->make_immutable;

1;
__END__
