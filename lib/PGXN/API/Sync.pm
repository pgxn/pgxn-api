package PGXN::API::Sync v0.6.8;

use 5.12.0;
use utf8;
use Moose;
use PGXN::API;
use PGXN::API::Indexer;
use Digest::SHA1;
use List::Util qw(first);
use File::Spec::Functions qw(catfile path rel2abs tmpdir);
use File::Path qw(make_path);
use namespace::autoclean;
use Cwd;
use Archive::Zip qw(:ERROR_CODES);
use constant WIN32 => $^O eq 'MSWin32';
use Moose::Util::TypeConstraints;

subtype Executable => as 'Str', where {
    my $exe = $_;
    first { -f $_ && -x _ } $exe, map { catfile $_, $exe } path;
};

has rsync_path   => (is => 'rw', isa => 'Executable', default => 'rsync', required => 1);
has source       => (is => 'rw', isa => 'Str', required => 1);
has verbose      => (is => 'rw', isa => 'Int', default => 0);
has log_file     => (is => 'rw', isa => 'Str', required =>1, default => sub {
    catfile tmpdir, "pgxn-api-sync-$$.txt"
});

sub run {
    my $self = shift;
    $self->run_rsync;
    $self->update_index;
}

sub DESTROY { unlink shift->log_file }

sub run_rsync {
    my $self = shift;

    # Sync the mirror.
    say "Updating the mirror from ", $self->source if $self->verbose;
    system (
        $self->rsync_path,
        qw(--archive --compress --delete --quiet),
        '--log-file-format' => '%i %n',
        '--log-file'        => $self->log_file,
        $self->source,
        PGXN::API->instance->mirror_root,
    ) == 0 or die;
}

sub update_index {
    my $self    = shift;

    # Update the mirror metadata.
    my $indexer = PGXN::API::Indexer->new(verbose => $self->verbose);
    $indexer->update_mirror_meta;

    my $regex = $self->regex_for_uri_template('meta');
    my $log   = $self->log_file;

    say 'Parsing the rsync log file' if $self->verbose > 1;
    open my $fh, '<:encoding(UTF-8)', $log or die "Canot open $log: $!\n";
    while (my $line = <$fh>) {
        next if $line !~ $regex;
        my $params = $self->validate_distribution($1) or next;
        $indexer->add_distribution($params);
    }
    close $fh or die "Cannot close $log: $!\n";
    say 'Sync complete' if $self->verbose;
    return $self;
}

sub regex_for_uri_template {
    my ($self, $name) = @_;

    # Get the URI for the template.
    my $uri = PGXN::API->instance->uri_templates->{$name}->process(
        map { $_ => "{$_}" } qw(dist version user extension tag)
    );

    my %regex_for = (
        '{dist}'      => qr{[^/]+?},
        '{version}'   => qr{(?:0|[1-9][0-9]*)(?:[.][0-9]+){2,}(?:[a-zA-Z][-0-9A-Za-z]*)?},
        '{user}'      => qr{[a-z]([-a-z0-9]{0,61}[a-z0-9])?}i,
        '{extension}' => qr{[^/]+?},
        '{tag}'       => qr{[^/]+?},
    );

    # Assemble the regex corresponding to the template.
    my $regex = join '', map {
        $regex_for{$_} || quotemeta $_
    } grep { defined && length } map {
        split /(\{.+?\})/
    } catfile grep { defined && length } $uri->path_segments;

    # Return the regex to match new files in rsync output lines.
    return qr{\s>f[+]+\s($regex)$};
}

sub validate_distribution {
    my ($self, $fn) = shift->_rel_to_mirror(@_);
    my $meta = PGXN::API->instance->read_json_from($fn);
    my $dist = $self->dist_for($meta);

    # Validate it against the SHA1 checksum.
    say '  Checksumming ', $dist if $self->verbose;
    if ($self->digest_for($dist) ne $meta->{sha1}) {
        warn "Checksum verification failed for $fn\n";
        return;
    }

    # Unpack the distribution.
    my $zip = $self->unzip($dist, $meta) or return;
    return { meta => $meta, zip => $zip };
}

sub dist_for {
    my ($self, $meta) = @_;
    my $dist_uri = PGXN::API->instance->uri_templates->{download}->process(
        dist    => $meta->{name},
        version => $meta->{version},
    );

    my (undef, @segments) = $dist_uri->path_segments;
    return catfile @segments;
}

sub digest_for {
    my ($self, $fn) = shift->_rel_to_mirror(@_);
    open my $fh, '<:raw', $fn or die "Cannot open $fn: $!\n";
    my $sha1 = Digest::SHA1->new;
    $sha1->addfile($fh);
    return $sha1->hexdigest;
}

my $CWD = cwd;
sub unzip {
    say '  Extracting ', $_[1] if $_[0]->verbose;
    my ($self, $dist, $meta) = shift->_rel_to_mirror(@_);

    my $zip = Archive::Zip->new;
    if ($zip->read(rel2abs $dist) != AZ_OK) {
        warn "Error reading $dist\n";
        return;
    }

    my $dir = PGXN::API->instance->source_dir;
    chdir $dir or die "Cannot cd to $dir: $!\n";
    make_path $meta->{name} unless -e $meta->{name} && -d _;
    chdir $meta->{name};
    my $ret = $zip->extractTree;
    chdir $CWD;

    if ($ret != AZ_OK) {
        warn "Error extracting $dist\n";
        ## XXX clean up the mess here.
        return;
    }

    return $zip;
}

sub _rel_to_mirror {
    return shift, catfile(+PGXN::API->instance->mirror_root, shift), @_;
}

1;

__END__

=head1 Name

PGXN::API::Sync - Sync from a PGXN mirror and update the index

=head1 Synopsis

  use PGXN::API::Sync;
  my $api = PGXN::API::Sync->run;

=head1 Description

More to come.

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
