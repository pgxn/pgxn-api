package PGXN::API::Sync v0.1.0;

use 5.12.0;
use utf8;
use Moose;
use PGXN::API;
use Digest::SHA1;
use File::Spec::Functions qw(catfile rel2abs);
use namespace::autoclean;
use Cwd;
use File::Path qw(make_path);
use Archive::Zip qw(:ERROR_CODES);
use constant WIN32 => $^O eq 'MSWin32';

has rsync_output  => (is => 'rw', isa => 'FileHandle');
has source_dir => (is => 'rw', 'isa' => 'Str', default => sub {
    my $dir = catfile +PGXN::API->instance->config->{mirror_root}, 'src';
    if (!-e $dir) {
        make_path $dir;
    } elsif (!-d $dir) {
        die "Distributions will be unzipped into $dir, but $dir is not a directory\n";
    }
    $dir;
});

sub run {
    my $self = shift;
    $self->run_rsync;
    $self->update_index;
}

sub run_rsync {
    my $self   = shift;
    my $config = PGXN::API->instance->config;
    my $fh     = $self->_pipe(
        '-|',
        $config->{rsync_path} || 'rsync',
        qw(--archive --compress --delete --out-format), '%i %n',
        $config->{rsync_source},
        $config->{mirror_root},
    );
    $self->rsync_output($fh);
}

# Stolen from SVN::Notify.
sub _pipe {
    my ($self, $mode) = (shift, shift);

    # Safer version of backtick (see perlipc(1)).
    if (WIN32) {
        my $cmd = $mode eq '-|'
            ? q{"}  . join(q{" "}, @_) . q{"|}
            : q{|"} . join(q{" "}, @_) . q{"};
        open my $pipe, $cmd or die "Cannot fork: $!\n";
        binmode $pipe, ':encoding(utf-8)';
        return $pipe;
    }

    my $pid = open my ($pipe), $mode;
    die "Cannot fork: $!\n" unless defined $pid;

    if ($pid) {
        # Parent process. Set the encoding layer and return the file handle.
        binmode $pipe, ':encoding(utf-8)';
        return $pipe;
    } else {
        # Child process. Execute the commands.
        exec @_ or die "Cannot exec $_[0]: $!\n";
        # Not reached.
    }
}

sub update_index {
    my $self  = shift;
    my $regex = $self->regex_for_uri_template('meta');
    my $fh    = $self->rsync_output;
    while (my $line = <$fh>) {
        $self->process_meta($1) if $line =~ $regex;
    }
    return $self;
}

sub regex_for_uri_template {
    my ($self, $name) = @_;

    # Get the URI for the template.
    my $uri = PGXN::API->instance->uri_templates->{$name}->process(
        map { $_ => "{$_}" } qw(dist version owner extension tag)
    );

    my %regex_for = (
        '{dist}'      => qr{[^/]+?},
        '{version}'   => qr{(?:0|[1-9][0-9]*)(?:[.][0-9]+){2,}(?:[a-zA-Z][-0-9A-Za-z]*)?},
        '{owner}'     => qr{[a-z]([-a-z0-9]{0,61}[a-z0-9])?}i,
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
    return qr{^>f[+]{9}\s($regex)$};
}

sub process_meta {
    my ($self, $fn) = @_;
    my $meta = PGXN::API->instance->read_json_from($fn);
    my $dist = $self->dist_for($meta);

    # Validate it against the SHA1 checksum.
    if ($self->digest_for($dist) ne $meta->{sha1}) {
        warn "Checksum verification failed for $fn\n";
        return;
    }

    # Unpack the distribution.
    $self->unzip($dist) or return;
    return $self;
}

sub dist_for {
    my ($self, $meta) = @_;
    my $dist_uri = PGXN::API->instance->uri_templates->{dist}->process(
        dist    => $meta->{name},
        version => $meta->{version},
    );

    return catfile +PGXN::API->instance->config->{mirror_root},
        $dist_uri->path_segments;
}

sub digest_for {
    my ($self, $fn) = @_;
    open my $fh, '<:raw', $fn or die "Cannot open $fn: $!\n";
    my $sha1 = Digest::SHA1->new;
    $sha1->addfile($fh);
    return $sha1->hexdigest;
}

my $CWD = cwd;
sub unzip {
    my ($self, $dist) = @_;

    my $zip = Archive::Zip->new;
    if ($zip->read(rel2abs $dist) != AZ_OK) {
        warn "Error reading $dist\n";
        return;
    }

    my $dir = $self->source_dir;
    chdir $dir or die "Cannot cd to $dir: $!\n";
    my $ret = $zip->extractTree;
    chdir $CWD;

    if ($ret != AZ_OK) {
        warn "Error extracting $dist\n";
        ## XXX clean up the mess here.
        return;
    }

    return $self;
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
