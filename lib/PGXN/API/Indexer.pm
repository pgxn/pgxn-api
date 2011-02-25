package PGXN::API::Indexer v0.1.0;

use 5.12.0;
use utf8;
use Moose;
use PGXN::API;
use XML::LibXML;
use File::Spec::Functions qw(catfile catdir);
use File::Path qw(make_path);
use File::Copy::Recursive qw(fcopy);
use namespace::autoclean;
use JSON;

my $encoder = JSON->new->space_after->allow_nonref->indent->canonical;

sub add_distribution {
    my ($self, $meta) = @_;

    $self->copy_files($meta)      or return;
    $self->merge_distmeta($meta)  or return;
    $self->update_owner($meta) or return;

    return $self;
}

sub copy_files {
    my ($self, $meta) = @_;
    # Need to copy the README, zip file, and dist meta file.
    for my $file (qw(dist readme)) {
        my $src = $self->mirror_file_for($file => $meta);
        my $dest = $self->doc_root_file_for($file => $meta);
        fcopy $src, $dest or die "Cannot copy $src to $dest: $!\n";
    }
    return $self;
}

sub merge_distmeta {
    my ($self, $meta) = @_;

    # Merge the list of versions into the meta file.
    my $api = PGXN::API->instance;
    my $by_dist_file = $self->mirror_file_for('by-dist' => $meta);
    my $by_dist_meta = $api->read_json_from($by_dist_file);
    $meta->{releases} = $by_dist_meta->{releases};

    # Write the merge metadata to the file.
    my $fn = $self->doc_root_file_for(meta => $meta);
    open my $fh, '>:utf8', $fn or die "Cannot open $fn: $!\n";
    print $fh $encoder->encode($meta);
    close $fh or die "Cannot close $fn: $!\n";

    # Now copy it to its by-dist home.
    $by_dist_file = $self->doc_root_file_for('by-dist' => $meta );
    fcopy $fn, $by_dist_file or die "Cannot copy $fn to $by_dist_file: $!\n";

    # Now update all older versions with the complete list of verions.
    for my $versions ( values %{ $meta->{releases} }) {
        for my $version (@{ $versions}) {
            next if $version eq $meta->{version};
            local $meta->{version} = $version;

            my $vmeta_file = $self->doc_root_file_for( meta => $meta);
            my $vmeta = $api->read_json_from($vmeta_file);
            $vmeta->{releases} = $meta->{releases};

            open my $fh, '>:utf8', $vmeta_file
                or die "Cannot open $vmeta_file: $!\n";
            print $fh $encoder->encode($vmeta);
            close $fh or die "Cannot close $vmeta_file: $!\n";
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

    # Copy the release metadata into the mirrored data.
    $mir_meta->{releases} = $doc_meta->{releases};

    # Update *this* release with version info, abstract, and date.
    $mir_meta->{releases}{$meta->{name}} = {
        %{ $meta->{releases} },
        abstract     => $meta->{abstract},
        release_date => $meta->{release_date},
    };

    # Now write out the file again.
    open my $fh, '>:utf8', $doc_file or die "Cannot open $doc_file: $!\n";
    print $fh $encoder->encode($mir_meta);
    close $fh or die "Cannot close $doc_file: $!\n";

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
