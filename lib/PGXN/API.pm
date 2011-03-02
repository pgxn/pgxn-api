package PGXN::API v0.1.0;

use 5.12.0;
use utf8;
use MooseX::Singleton;
use File::Spec::Functions qw(catfile catdir);
use File::Path qw(make_path);
use URI::Template;
use JSON;
use namespace::autoclean;

=head1 Interface

=head2 Constructor

=head3 C<instance>

  my $app = PGXN::Manager->instance;

Returns the singleton instance of PGXN::Manager. This is the recommended way
to get the PGXN::Manager object.

=head2 Attributes

=head3 C<uri_templates>

  my $templates = $pgxn->uri_templates;

Returns a hash reference of the URI templates for the various files stored in
the mirror root. The keys are the names of the templates, and the values are
L<URI::Template> objects.

=cut

has uri_templates => (is => 'ro', isa => 'HashRef', lazy => 1, default => sub {
    my $self = shift;
    my $tmpl = $self->read_json_from(
        catfile $self->mirror_root, 'index.json'
    );
    return { map { $_ => URI::Template->new($tmpl->{$_}) } keys %{ $tmpl } };
});

=head3 C<doc_root>

  my $doc_root = $pgxn->doc_root;

Returns the document root for the API server. The default is the F<www>
directory in the root directory of this distribution.

=cut

my $trig = sub {
    my ($self, $dir) = @_;
     if (!-e $dir) {
         make_path $dir;
         # Pre-generate the by/ directories.
         make_path catdir $dir, 'by', $_ for qw(owner tag dist extension);
     } elsif (!-d $dir) {
         die qq{Location for document root "$dir" is not a directory\n};
     }
};

has doc_root => (is => 'rw', isa => 'Str', lazy => 1, trigger => $trig, default => sub {
     my $file = quotemeta catfile qw(lib PGXN API.pm);
     my $blib = quotemeta catfile 'blib', '';
     (my $dir = __FILE__) =~ s{(?:$blib)?$file$}{www};
     $trig->(shift, $dir);
     $dir;
});

=head3 C<source_dir>

  my $source_dir = $pgxn->source_dir;

Returns the directory on the file system where sources should be unzipped,
which is just the F<src> subdirectory of C<doc_root>.

=cut

has source_dir => (is => 'ro', 'isa' => 'Str', lazy => 1, default => sub {
    my $dir = catdir shift->doc_root, 'src';
    if (!-e $dir) {
        make_path $dir;
    } elsif (!-d $dir) {
        die qq{Location for source files "$dir" is not a directory\n};
    }
    $dir;
});

=head3 C<mirror_root>

  my $mirror_root = $pgxn->mirror_root;

Returns the directory on the file system where the PGXN mirror lives, which is
just the F<pgxn> subdirectory of C<doc_root>.

=cut

has mirror_root => (is => 'ro', 'isa' => 'Str', lazy => 1, default => sub {
    my $dir = catdir shift->doc_root, 'pgxn';
    if (!-e $dir) {
        make_path $dir;
    } elsif (!-d $dir) {
        die qq{Location for source files "$dir" is not a directory\n};
    }
    $dir;
});

=head3 C<read_json_from>

  my $data = $pgxn->read_json_from($filename);

Loads the contents of C<$filename>, parses them as JSON, and returns the
resulting data structure.

=cut

sub read_json_from {
    my ($self, $fn) = @_;
    open my $fh, '<:raw', $fn or die "Cannot open $fn: $!\n";
    local $/;
    return JSON->new->utf8->decode(<$fh>);
}

=head3 C<write_json_to>

  my $data = $pgxn->write_json_to($filename, $data);

Writes C<$data> to C<$filename> as JSON.

=cut

sub write_json_to {
    my ($self, $fn, $data) = @_;
    my $encoder = JSON->new->space_after->allow_nonref->indent->canonical;
    open my $fh, '>:utf8', $fn or die "Cannot open $fn: $!\n";
    print $fh $encoder->encode($data);
    close $fh or die "Cannot close $fn: $!\n";
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 Name

PGXN::API - Maintain and serve a REST API to search PGXN mirrors

=head1 Synopsis

  use PGXN::API;
  my $api = PGXN::API->instance;

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
