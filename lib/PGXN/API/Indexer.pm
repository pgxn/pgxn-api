package PGXN::API::Indexer v0.2.0;

use 5.12.0;
use utf8;
use Moose;
use PGXN::API;
use File::Spec::Functions qw(catfile catdir);
use File::Path qw(make_path);
use File::Copy::Recursive qw(fcopy dircopy);
use namespace::autoclean;

has verbose => (is => 'rw', isa => 'Int', default => 0);

sub update_mirror_meta {
    my $self = shift;
    my $api  = PGXN::API->instance;
    say "Updating mirror metadata" if $self->verbose;

    # Copy index.json.
    # XXX Will likely modify to add doc and directory URI templates.
    my $src = catfile $api->mirror_root, 'index.json';
    my $dst = catfile $api->doc_root, 'index.json';
    fcopy $src, $dst or die "Cannot copy $src to $dst: $!\n";

    # Copy meta.
    $src = catdir $api->mirror_root, 'meta';
    $dst = catdir $api->doc_root, 'meta';
    dircopy $src, $dst or die "Cannot copy directory $src to $dst: $!\n";

    return $self;
}

sub add_distribution {
    my ($self, $meta) = @_;

    $self->copy_files($meta)        or return;
    $self->merge_distmeta($meta)    or return;
    $self->update_owner($meta)      or return;
    $self->update_tags($meta)       or return;
    $self->update_extensions($meta) or return;

    return $self;
}

sub copy_files {
    my ($self, $meta) = @_;
    say "  Copying $meta->{name}-$meta->{version} files" if $self->verbose;

    # Need to copy the README, zip file, and dist meta file.
    for my $file (qw(dist readme)) {
        my $src = $self->mirror_file_for($file => $meta);
        my $dst = $self->doc_root_file_for($file => $meta);
        next if $file eq 'readme' && !-e $src;
        say "    $meta->{name}-$meta->{version}.$file" if $self->verbose > 1;
        fcopy $src, $dst or die "Cannot copy $src to $dst: $!\n";
    }
    return $self;
}

sub merge_distmeta {
    my ($self, $meta) = @_;
    say "  Merging $meta->{name}-$meta->{version} META.json" if $self->verbose;

    # Merge the list of versions into the meta file.
    my $api = PGXN::API->instance;
    my $by_dist_file = $self->mirror_file_for('by-dist' => $meta);
    my $by_dist_meta = $api->read_json_from($by_dist_file);
    $meta->{releases} = $by_dist_meta->{releases};

    # Write the merge metadata to the file.
    my $fn = $self->doc_root_file_for(meta => $meta);
    $api->write_json_to($fn, $meta);

    # Now copy it to its by-dist home.
    $by_dist_file = $self->doc_root_file_for('by-dist' => $meta );
    fcopy $fn, $by_dist_file or die "Cannot copy $fn to $by_dist_file: $!\n";

    # Now update all older versions with the complete list of verions.
    for my $versions ( values %{ $meta->{releases} }) {
        for my $version (@{ $versions}) {
            next if $version eq $meta->{version};
            local $meta->{version} = $version;

            my $vmeta_file = $self->doc_root_file_for( meta => $meta);
            next unless -e $vmeta_file;
            my $vmeta = $api->read_json_from($vmeta_file);
            $vmeta->{releases} = $meta->{releases};
            $api->write_json_to($vmeta_file => $vmeta);
        }
    }

    return $self;
}

sub update_owner {
    my ($self, $meta) = @_;
    my $api = PGXN::API->instance;

    # Read in owner metadata from the mirror.
    my $mir_file = $self->mirror_file_for('by-owner' => $meta);
    my $mir_meta = $api->read_json_from($mir_file);

    # Read in owner metadata from the doc root.
    my $doc_file = $self->doc_root_file_for('by-owner' => $meta);
    my $doc_meta = -e $doc_file ? $api->read_json_from($doc_file) : $mir_meta;

    say "  Updating owner $meta->{owner}" if $self->verbose;

    # Update *this* release with version info, abstract, and date.
    $doc_meta->{releases}{$meta->{name}} = {
        %{ $meta->{releases} },
        %{ $doc_meta->{releases}{$meta->{name}} },
        %{ $mir_meta->{releases}{$meta->{name}} },
        abstract                       => $meta->{abstract},
        "$meta->{release_status}_date" => $meta->{release_date},
    };

    # Copy the release metadata into the mirrored data and the core metadata.
    $mir_meta->{releases}  = $doc_meta->{releases};
    $meta->{releases_plus} = $doc_meta->{releases}{$meta->{name}};

    # Now write out the file again and go home.
    $api->write_json_to($doc_file => $mir_meta);
    return $self;
}

sub update_tags {
    my ($self, $meta) = @_;
    my $api = PGXN::API->instance;
    say "  Updating $meta->{name}-$meta->{version} tags" if $self->verbose;

    my $tags = $meta->{tags} or return $self;

    for my $tag (@{ $tags }) {
        # Read in tag metadata from the doc root.
        my $doc_file = $self->doc_root_file_for('by-tag' => $meta, tag => $tag);
        say "    $tag" if $self->verbose > 1;
        my $doc_meta = -e $doc_file ? $api->read_json_from($doc_file) : do {
            # Fall back on the mirror file.
            my $mir_file = $self->mirror_file_for('by-tag' => $meta, tag => $tag);
            $api->read_json_from($mir_file);
        };

        # Copy the release metadata into the doc data and write it back out.
        $doc_meta->{releases}{$meta->{name}} = $meta->{releases_plus};
        $api->write_json_to($doc_file => $doc_meta);
    }
    return $self;
}

sub update_extensions {
    my ($self, $meta) = @_;
    my $api = PGXN::API->instance;
    say "  Updating $meta->{name}-$meta->{version} extensions"
        if $self->verbose;

    while (my ($ext, $data) = each %{ $meta->{provides} }) {
        say "    $ext" if $self->verbose > 1;
        # Read in extension metadata from the mirror.
        my $mir_file = $self->mirror_file_for(
            'by-extension' => $meta,
            extension      => $ext,
        );
        my $mir_meta = $api->read_json_from($mir_file);

        # Read in extension metadata from the doc root.
        my $doc_file = $self->doc_root_file_for(
            'by-extension' => $meta,
            extension      => $ext,
        );
        my $doc_meta = -e $doc_file ? $api->read_json_from($doc_file) : {};

        # Add the abstract to the mirror data.
        my $status = $meta->{release_status};
        $mir_meta->{$status}{abstract} = $data->{abstract};
        $mir_meta->{$_} = $doc_meta->{$_} for grep {
            $doc_meta->{$_} && $_ ne $status
        } qw(stable testing unstable);

        # Copy the version info from the doc to the mirror and add the date.
        $doc_meta->{versions} ||= {};
         my $version   = $data->{version};
        my $mir_dists = $mir_meta->{versions}{$version};
        my $doc_dists = $doc_meta->{versions}{$version} ||= [];

        # Copy the doc root versions.
        $mir_meta->{versions} = $doc_meta->{versions};

        # Find the current release distribution in the versions.
        for my $i (0..$#$mir_dists) {
            my $dist = $mir_dists->[$i];
            # Make sure the doc dists are in sync.
            if (!$doc_dists->[$i]
                || $dist->{dist} ne $doc_dists->[$i]{dist}
                || $dist->{version} ne $doc_dists->[$i]{version}
            ) {
                splice @{ $doc_dists }, $i, 0, $dist;
            }

            # Is this the distribution we're currently updating?
            if ($dist->{dist} eq $meta->{name}
                && $dist->{version} eq $meta->{version}
            ) {
                # We got it. Add the releae date and copy it to the mirror data.
                $dist->{release_date} = $meta->{release_date};
                last;
            }
        }

        # Write it back out.
        $api->write_json_to($doc_file => $mir_meta);
    }

    return $self;
}

sub mirror_file_for {
    my $self = shift;
    return catfile +PGXN::API->instance->mirror_root,
        $self->_uri_for(@_)->path_segments;
}

sub doc_root_file_for {
    my $self = shift;
    return catfile +PGXN::API->instance->doc_root,
        $self->_uri_for(@_)->path_segments;
}

sub _uri_for {
    my ($self, $name, $meta, @params) = @_;
    PGXN::API->instance->uri_templates->{$name}->process(
        dist    => $meta->{name},
        version => $meta->{version},
        owner   => $meta->{owner},
        @params,
    );
}


1;

__END__

=head1 Name

PGXN::API::Index - PGXN API distribution indexer

=head1 Synopsis

  use PGXN::API::Indexer;
  PGXN::API::Indexer->add_distribution({
      meta    => $meta,
      src_dir => File::Spec->catdir(
          $self->source_dir, "$meta->{name}-$meta->{version}"
      ),
  });

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
