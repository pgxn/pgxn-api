package PGXN::API::Stats v0.9.1;

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

has verbose            => (is => 'rw', isa => 'Int',  default => 0);
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
                        dist      TEXT      NOT NULL PRIMARY KEY,
                        releases  INT       NOT NULL,
                        version   TEXT      NOT NULL,
                        date      TIMESTAMP NOT NULL,
                        user      TEXT      NOT NULL,
                        abstract  TEXT      NOT NULL
                    )
                });
                $dbh->do(q{
                    CREATE TABLE extensions (
                        extension TEXT      NOT NULL PRIMARY KEY,
                        releases  INT       NOT NULL,
                        dist      TEXT      NOT NULL,
                        version   TEXT      NOT NULL,
                        date      TIMESTAMP NOT NULL,
                        user      TEXT      NOT NULL,
                        abstract  TEXT      NOT NULL
                    )
                });
                $dbh->do(q{
                    CREATE TABLE users (
                        nickname   TEXT      NOT NULL PRIMARY KEY,
                        name       TEXT      NOT NULL,
                        dist_count INT       NOT NULL
                    )
                });
                $dbh->do(q{
                    CREATE TABLE tags (
                        tag        TEXT      NOT NULL PRIMARY KEY,
                        dist_count INT       NOT NULL
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
            INSERT INTO dists (releases, version, date, user, abstract, dist)
            VALUES (?, ?, ?, ?, ?, ?)
        }, undef, @params) if $dbh->do(q{
            UPDATE dists
               SET releases = ?, version = ?, date = ?, user = ?, abstract = ?
             WHERE dist = ?
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
            INSERT INTO extensions (releases, dist, version, date, user, abstract, extension)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        }, undef, @params) if $dbh->do(q{
            UPDATE extensions
               SET releases = ?, dist = ?, version = ?, date = ?, user = ?, abstract = ?
             WHERE extension = ?
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
            'INSERT INTO users (dist_count, name, nickname) VALUES (?, ?, ?)',
            undef, @params
        ) if $dbh->do(
            'UPDATE users SET dist_count = ?, name = ? WHERE nickname = ?',
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
            'INSERT INTO tags (dist_count, tag) VALUES (?, ?)',
            undef, @params
        ) if $dbh->do(
            'UPDATE tags SET dist_count = ? WHERE tag = ?',
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
    my ($self, $things, $label, $cols, $order_by) = @_;

    $self->conn->run(sub {
        my $dbh = shift;
        my $count = $dbh->selectcol_arrayref(
            "SELECT COUNT(*) FROM $things"
        )->[0];

        my $sth = $dbh->prepare(qq{
            SELECT $cols
              FROM $things
             ORDER BY $order_by
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
    my $self = shift;
    $self->_write_stats(
        'dists', 'recent',
        'dist, version, date, user, abstract',
        'date DESC, dist'
    );
    $self->dists_updated(0);
    return $self;
}

sub write_user_stats {
    my $self = shift;
    $self->_write_stats(
        'users', 'prolific',
        'nickname, dist_count',
        'dist_count DESC, nickname',
    );
    $self->users_updated(0);
    return $self;
}

sub write_tag_stats {
    my $self = shift;
    $self->_write_stats(
        'tags', 'popular',
        'tag, dist_count',
        'dist_count DESC, tag',
    );
    $self->tags_updated(0);
    return $self;
}

sub write_extension_stats {
    my $self = shift;
    $self->_write_stats(
        'extensions', 'prolific',
        'releases, extension, dist, version, date, user, abstract',
        'releases DESC, extension',
    );
    $self->extensions_updated(0);
    return $self;
}

__PACKAGE__->meta->make_immutable;

__END__

=head1 Name

PGXN::API::Stats - PGXN API statistics updater

=head1 Synopsis

  use PGXN::API::Stats;
  my $stats = PGXN::API::Stats->new( verbose => $verbose );
  $stats->update_tag($path_to_tag_json);
  $stats->update_user($path_to_user_json);
  $stats->update_dist($path_to_dist_json);
  $stats->update_extension($path_to_extension_json);
  $stats->write_stats;

=head1 Description

This module manages statistics JSON files. That is, it updates the summary
information for distributions, extensions, users and tags. The files are
saved in the API document root as

=over

=item * F</stats/dists.json>

=item * F</stats/extensions.json>

=item * F</stats/users.json>

=item * F</stats/tags.json>

=back

Stats are aggregated over time, and updated only as much as necessary by a
given sync. The data is stored in an SQLite database, which is updated by the
various C<update_*()> methods and read from to write the stats JSON files.

PGXN::API::Stats is called during a sync by L<PGXN::API::Sync>, so you
probably don't have to worry about calling it directly. Still, if the details
interest you, read on.

=head1 Class Interface

=head2 Constructor

=head3 C<new>

  my $stats = PGXN::API::Stats->new(%params);

Creates and returns a new PGXN::API::Stats object. The supported parameters
are:

=over

=item C<verbose>

An incremental integer specifying the level of verbosity to use during a sync.
By default, PGXN::API::Stats runs in quiet mode, where only errors are emitted
to C<STDERR>.

=back

=head1 Instance Interface

=head2 Instance Methods

=head3 C<update_dist>

  $stats->update_dist($path_to_dist_json);

Updates 

=head3 C<update_extension>

  $stats->update_extension($path_to_extension_json);



=head3 C<update_user>

  $stats->update_user($path_to_user_json);



=head3 C<update_tag>

  $stats->update_tag($path_to_tag_json);



=head3 C<write_stats>

  $stats->write_stats;



=head3 C<write_dist_stats>

  $stats->write_dist_stats;



=head3 C<write_extension_stats>

  $stats->write_extension_stats;



=head3 C<write_user_stats>

  $stats->write_user_stats;



=head3 C<write_tag_stats>

  $stats->write_tag_stats;



=head2 Instance Accessors

=head3 C<verbose>

  my $verbose = $stats->verbose;
  $stats->verbose($verbose);

Get or set an incremental verbosity. The higher the integer specified, the
more verbose the sync.

=head1 Author

David E. Wheeler <david.wheeler@pgexperts.com>

=head1 Copyright and License

Copyright (c) 2011 David E. Wheeler.

This module is free software; you can redistribute it and/or modify it under
the L<PostgreSQL License|http://www.opensource.org/licenses/postgresql>.

Permission to use, copy, modify, and distribute this software and its
documentation for any purpose, without fee, and without a written agreement is
hereby granted, provided that the above copyright notice and this paragraph
and the following two paragraphs appear in all copies.

In no event shall David E. Wheeler be liable to any party for direct,
indirect, special, incidental, or consequential damages, including lost
profits, arising out of the use of this software and its documentation, even
if David E. Wheeler has been advised of the possibility of such damage.

David E. Wheeler specifically disclaims any warranties, including, but not
limited to, the implied warranties of merchantability and fitness for a
particular purpose. The software provided hereunder is on an "as is" basis,
and David E. Wheeler has no obligations to provide maintenance, support,
updates, enhancements, or modifications.

=cut
