package PGXN::API::Sync v0.12.7;

use 5.12.0;
use utf8;
use Moose;
use PGXN::API;
use PGXN::API::Indexer;
use Digest::SHA1;
use List::Util qw(first);
use File::Spec::Functions qw(catfile path rel2abs tmpdir);
use File::Path qw(make_path);
use Cwd;
use Archive::Zip qw(:ERROR_CODES);
use constant WIN32 => $^O eq 'MSWin32';
use Moose::Util::TypeConstraints;
use namespace::autoclean;

subtype Executable => as 'Str', where {
    my $exe = $_;
    first { -f $_ && -x _ } $exe, map { catfile $_, $exe } path;
};

has rsync_path   => (is => 'rw', isa => 'Executable', default => 'rsync', required => 1);
has source       => (is => 'rw', isa => 'Str', required => 1);
has verbose      => (is => 'rw', isa => 'Int', default => 0);
has log_file     => (is => 'rw', isa => 'Str', required => 1, default => sub {
    catfile tmpdir, "pgxn-api-sync-$$.txt"
});
has mirror_uri_templates => (is => 'ro', isa => 'HashRef', lazy => 1, default => sub {
    my $self = shift;
    my $api  = PGXN::API->instance;
    my $tmpl = $api->read_json_from(catfile $api->mirror_root, 'index.json');
    return { map { $_ => URI::Template->new($tmpl->{$_}) } keys %{ $tmpl } };
});

sub run {
    my $self = shift;
    $self->run_rsync;
    $self->update_index;
}

sub DESTROY {
    my $self = shift;
    unlink $self->log_file;
    $self->SUPER::DESTROY;
}

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
    my $indexer = PGXN::API::Indexer->new(verbose => $self->verbose);

    my $meta_re = $self->regex_for_uri_template('meta');
    my $mirr_re = $self->regex_for_uri_template('mirrors');
    my $spec_re = $self->regex_for_uri_template('spec');
    my $stat_re = $self->regex_for_uri_template('stats');
    my $user_re = $self->regex_for_uri_template('user');
    my $log     = $self->log_file;

    say 'Parsing the rsync log file' if $self->verbose > 1;
    open my $fh, '<:encoding(UTF-8)', $log or die "Canot open $log: $!\n";
    while (my $line = <$fh>) {
        if ($line =~ $meta_re) {
            if (my $params = $self->validate_distribution($1)) {
                $indexer->add_distribution($params);
            }
        } elsif ($line =~ $stat_re || $line =~ $mirr_re) {
            $indexer->copy_from_mirror($1);
        } elsif ($line =~ $spec_re) {
            my $path = $1;
            $indexer->copy_from_mirror($path);
            $indexer->parse_from_mirror($path, 'Multimarkdown');
        } elsif ($line =~ /\s>f[+]+\sindex[.]json$/) {
            $indexer->update_root_json;
        } elsif ($line =~ $user_re) {
            $indexer->merge_user($2);
        }
    }
    close $fh or die "Cannot close $log: $!\n";
    $indexer->finalize;
    say 'Sync complete' if $self->verbose;
    return $self;
}

sub regex_for_uri_template {
    my ($self, $name) = @_;

    # Get the URI for the template.
    my $uri = $self->mirror_uri_templates->{$name}->process(
        map { $_ => "{$_}" } qw(dist version user extension tag stats format)
    );

    my %regex_for = (
        '{dist}'      => qr{[^/]+?},
        '{version}'   => qr{(?:0|[1-9][0-9]*)(?:[.][0-9]+){2,}(?:[a-z][-0-9a-z]*)?},
        '{user}'      => qr{([a-z]([-a-z0-9]{0,61}[a-z0-9])?)}i,
        '{extension}' => qr{[^/]+?},
        '{tag}'       => qr{[^/]+?},
        '{stats}'     => qr{(?:dist|tag|user|extension|summary)},
        '{format}'    => qr{(?:txt|html|atom|xml)},
    );

    # Assemble the regex corresponding to the template.
    my $regex = join '', map {
        $regex_for{$_} || quotemeta $_
    } grep { defined && length } map {
        split /(\{.+?\})/
    } catfile grep { defined && length } $uri->path_segments;

    # Return the regex to match new or updated in rsync output lines.
    return qr{\s>f(?:[+]+|(?:c|.s|..t)[^ ]+)\s($regex)$};

    # The rsync %i output format:
    # YXcstpogz    # Snow Leopard
    # YXcstpoguax  # Debian
    # c: checkum has changed, file will be updated
    # s: file size has changed, file will be updated
    # t: modtime has changed, file will be updated
    # +++++++: New item
}


sub validate_distribution {
    my ($self, $fn) = shift->_rel_to_mirror(@_);
    my $meta     = PGXN::API->instance->read_json_from($fn);
    my $zip_path = $self->download_for($meta);

    # Validate it against the SHA1 checksum.
    say '  Checksumming ', $zip_path if $self->verbose;
    if ($self->digest_for($zip_path) ne $meta->{sha1}) {
        warn "Checksum verification failed for $fn\n";
        return;
    }

    # Unpack the distribution.
    my $zip = $self->unzip($zip_path, $meta) or return;
    return { meta => $meta, zip => $zip };
}

sub download_for {
    my ($self, $meta) = @_;
    my $zip_uri = $self->mirror_uri_templates->{download}->process(
        dist    => lc $meta->{name},
        version => lc $meta->{version},
    );

    my (undef, @segments) = $zip_uri->path_segments;
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
    my ($self, $zip_path, $meta) = shift->_rel_to_mirror(@_);

    my $zip = Archive::Zip->new;
    if ($zip->read(rel2abs $zip_path) != AZ_OK) {
        warn "Error reading $zip_path\n";
        return;
    }

    my $dir = PGXN::API->instance->source_dir;
    chdir $dir or die "Cannot cd to $dir: $!\n";
    my $dist_name = lc $meta->{name};
    make_path $dist_name unless -e $dist_name && -d _;
    chdir $dist_name;
    my $ret = $zip->extractTree;
    chdir $CWD;

    if ($ret != AZ_OK) {
        warn "Error extracting $zip_path\n";
        ## XXX clean up the mess here.
        return;
    }

    return $zip;
}

sub _rel_to_mirror {
    return shift, catfile(+PGXN::API->instance->mirror_root, shift), @_;
}

__PACKAGE__->meta->make_immutable(inline_destructor => 0);

1;

__END__

=head1 Name

PGXN::API::Sync - Sync from a PGXN mirror and update the index

=head1 Synopsis

  use PGXN::API::Sync;
  PGXN::API::Sync->new(
      source     => $source,
      rsync_path => $rsync_path,
      verbose    => $verbose,
  )->run;

=head1 Description

This module provides the implementation for C<pgxn_api_sync>, the command-line
utility for syncing to a PGXN mirror and creating the API. It syncs to the
specified PGXN rsync source URL, which should be a PGXN mirror server, and
then verifies and unpacks newly-uploaded distributions and hands them off to
L<PGXN::API::Indexer> to index.

=head1 Class Interface

=head2 Constructor

=head3 C<new>

  my $sync = PGXN::API::Sync->new(%params);

Creates and returns a new PGXN::API::Sync object. The supported parameters
are:

=over

=item C<rsync_path>

Path to the rsync executable. Defaults to C<rsync>, which should work find if
there is an executable with that name in your path.

=item C<source>

An C<rsync> URL specifying the source from which to sync. The source should be
an C<rsync> server serving up a PGXN mirror source as created or mirrored from
a PGXN Manager server.

=item C<verbose>

An incremental integer specifying the level of verbosity to use during a sync.
By default, PGXN::API::Sync runs in quiet mode, where only errors are emitted
to C<STDERR>.

=back

=head1 Instance Interface

=head2 Instance Methods

=head3 C<run>

  $sync->run;

Runs the sync, C<rsync>ing from the source mirror server, verifying and
unpacking distributions, and handing them off to the indexer for indexing.
This is the main method called by C<pgxn_api_sync> to just do the job.

=head3 C<run_rsync>

  $sync->run_rsync;

C<rsync>s from the source mirror server. Called by C<run>.

=head3 C<update_index>

  $sync->update_index;

Parses the log generated by the execution of C<run_rsync()> for new
distribution F<META.json> files and passes any found off to
C<validate_distribution()> and L<PGXN::API::Indexer/add_distribution> for
validation, unpacking, and indexing. Called internally by C<run()>.

=head3 C<regex_for_uri_template>

  my $regex = $sync->regex_for_uri_template('download');

Returns a regular expression that will match the path to a file in the rsync
logs. The regular expression is created from a named URI template as loaded
from the F</index.json> file synced from the mirror server. Used internally to
parse the paths to distribution files from the rsync logs so that they can be
validated, unpacked, and indexed.

=head3 C<download_for>

  my $download = $sync->download_for($meta);

Given the metadata loaded from a mirror server F<META.json> file, returns the
path to the download file for the distribution. Used internally by
C<validate_distribution()> to find the file to validate.

=head3 C<validate_distribution>

  my $params = $sync->validate_distribution($path_to_dist_meta);

Given the path to a distribution F<META.json> file, this method validates the
digest for the download file and unpacks it. Returns parameters suitable for
passing to L<PGXN::Indexer/add_distribution> for indexing.

=head3 C<digest_for>

  my $digest = $sync->digest_for($zipfile);

Returns the SHA-1 hex digest for a distribution file (or any file, really).
Called by C<validate_distribution()>.

=head3 C<unzip>

  $sync->unzip($download, $meta);)

Given a download file for a distribution, and the metadata loaded from the
C<META.json> describing the download, this method unpacks the download under
the F<src/>directory under the document root. This provides the browsable file
interface for the API server to server. Called internally by
C<validate_distribution()>.

=head2 Instance Accessors

=head3 C<rsync_path>

  my $rsync_path = $sync->rsync_path;
  $sync->rsync_path($rsync_path);

Get or set the path to the C<rsync> executable.

=head3 C<source>

  my $source = $sync->source;
  $sync->source($source);

Get or set the source C<rsync> URL from which to sync a PGXN mirror.

=head3 C<verbose>

  my $verbose = $sync->verbose;
  $sync->verbose($verbose);

Get or set an incremental verbosity. The higher the integer specified, the
more verbose the sync.

=head3 C<log_file>

  my $log_file = $sync->log_file;
  $sync->log_file($log_file);

Get or set the path to use for the C<rsync> log file. This file will then be
parsed by C<update_index> for new distributions to index.

=head3 C<mirror_uri_templates>

  my $templates = $pgxn->mirror_uri_templates;

Returns a hash reference of the URI templates loaded from the F<index.json>
file in the mirror root. The keys are the names of the templates, and the
values are L<URI::Template> objects.

=cut

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
