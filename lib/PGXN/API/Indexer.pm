package PGXN::API::Indexer v0.5.6;

use 5.12.0;
use utf8;
use Moose;
use PGXN::API;
use File::Spec::Functions qw(catfile catdir);
use File::Path qw(make_path);
use File::Copy::Recursive qw(fcopy dircopy);
use File::Basename;
use Text::Markup;
use XML::LibXML;
use KinoSearch::Plan::Schema;
use KinoSearch::Plan::FullTextType;
use KinoSearch::Analysis::PolyAnalyzer;
use KinoSearch::Analysis::Tokenizer;
use KinoSearch::Index::Indexer;
use namespace::autoclean;

has verbose => (is => 'rw', isa => 'Int', default => 0);
has docs => (is => 'ro', isa => 'ArrayRef', default => sub { [] });
has ksi => (is => 'ro', isa => 'KinoSearch::Index::Indexer', lazy => 1, default => sub {
    # Create the analyzer.
    my $polyanalyzer = KinoSearch::Analysis::PolyAnalyzer->new(
        language => 'en',
    );

    # Create the data types.
    my $fti_type = KinoSearch::Plan::FullTextType->new(
        analyzer      => $polyanalyzer,
        highlightable => 1,
    );

    my $cat_type = KinoSearch::Plan::StringType->new(
        indexed => 1,
        stored  => 1,
    );

    my $key_type = KinoSearch::Plan::StringType->new(
        indexed => 1,
        stored  => 0,
    );

    my $tag_type  = KinoSearch::Plan::FullTextType->new(
        indexed       => 1,
        stored        => 1,
        boost         => 2.0,
        analyzer      => KinoSearch::Analysis::Tokenizer->new(pattern => '[^\003]'),
        highlightable => 1,
    );

    # Create the schema.
    my $schema = KinoSearch::Plan::Schema->new;
    $schema->spec_field( name => 'key',      type => $key_type );
    $schema->spec_field( name => 'category', type => $cat_type );
    $schema->spec_field( name => 'title',    type => $fti_type );
    $schema->spec_field( name => 'abstract', type => $fti_type );
    $schema->spec_field( name => 'body',     type => $fti_type );
    $schema->spec_field( name => 'tags',     type => $tag_type );
    $schema->spec_field( name => 'meta',     type => $fti_type );

    # Create Indexer.
    KinoSearch::Index::Indexer->new(
        index    => catfile(PGXN::API->instance->doc_root, '_index'),
        schema   => $schema,
        create   => 1,
    );
});

sub update_mirror_meta {
    my $self = shift;
    my $api  = PGXN::API->instance;
    say "Updating mirror metadata" if $self->verbose;

    # Augment and write index.json.
    my $src = catfile $api->mirror_root, 'index.json';
    my $dst = catfile $api->doc_root, 'index.json';
    my $tmpl = $api->read_json_from($src);
    $tmpl->{source} = "/src/{dist}/{dist}-{version}/";
    ($tmpl->{doc}   = $tmpl->{meta}) =~ s{/META[.]json$}{/{+path}.html};
    $api->write_json_to($dst, $tmpl);

    # Copy meta.
    $src = catdir $api->mirror_root, 'meta';
    $dst = catdir $api->doc_root, 'meta';
    dircopy $src, $dst or die "Cannot copy directory $src to $dst: $!\n";

    return $self;
}

sub add_distribution {
    my ($self, $params) = @_;

    $self->copy_files($params)        or return $self->_rollback;
    $self->merge_distmeta($params)    or return $self->_rollback;
    $self->update_user($params)       or return $self->_rollback;
    $self->update_tags($params)       or return $self->_rollback;
    $self->update_extensions($params) or return $self->_rollback;
    return $self->_commit;
}

sub copy_files {
    my ($self, $p) = @_;
    my $meta = $p->{meta};
    say "  Copying $meta->{name}-$meta->{version} files" if $self->verbose;

    # Need to copy the README, zip file, and dist meta file.
    for my $file (qw(dist readme)) {
        my $src = $self->mirror_file_for($file => $meta);
        my $dst = $self->doc_root_file_for($file => $meta);
        next if $file eq 'readme' && !-e $src;
        say "    $meta->{name}-$meta->{version}.$file" if $self->verbose > 1;
        make_path dirname $dst;
        fcopy $src, $dst or die "Cannot copy $src to $dst: $!\n";
    }
    return $self;
}

sub merge_distmeta {
    my ($self, $p) = @_;
    my $meta = $p->{meta};
    say "  Merging $meta->{name}-$meta->{version} META.json" if $self->verbose;

    # Merge the list of versions into the meta file.
    my $api = PGXN::API->instance;
    my $by_dist_file = $self->mirror_file_for('by-dist' => $meta);
    my $by_dist_meta = $api->read_json_from($by_dist_file);
    $meta->{releases} = $by_dist_meta->{releases};

    # Add a list of special files and docs.
    $meta->{special_files} = $self->_source_files($p);
    $meta->{docs}          = $self->parse_docs($p);

    # Write the merge metadata to the file.
    my $fn = $self->doc_root_file_for(meta => $meta);
    make_path dirname $fn;
    $api->write_json_to($fn, $meta);

    $by_dist_file = $self->doc_root_file_for('by-dist' => $meta );
    if ($meta->{release_status} eq 'stable') {
        # Copy it to its by-dist home.
        fcopy $fn, $by_dist_file or die "Cannot copy $fn to $by_dist_file: $!\n";
    } else {
        # Determine latest stable release or fall back on testing, unstable.
        for my $status (qw(stable testing unstable)) {
            my $rels = $meta->{releases}{$status} or next;
            $meta->{version} = $rels->[0]{version};
            last;
        }

        # Now rite out the by-dist version.
        $api->write_json_to($by_dist_file => $meta);
    }

    # Now update all older versions with the complete list of releases.
    for my $releases ( values %{ $meta->{releases} }) {
        for my $release (@{ $releases}) {
            next if $release->{version} eq $meta->{version};
            local $meta->{version} = $release->{version};

            my $vmeta_file = $self->doc_root_file_for(meta => $meta);
            next unless -e $vmeta_file;
            my $vmeta = $api->read_json_from($vmeta_file);
            $vmeta->{releases} = $meta->{releases};
            $api->write_json_to($vmeta_file => $vmeta);
        }
    }

    return $self;
}

sub update_user {
    my ($self, $p) = @_;
    say "  Updating user $p->{meta}{user}" if $self->verbose;
    $self->_update_releases('by-user' => $p->{meta});
    return $self;
}

sub update_tags {
    my ($self, $p) = @_;
    my $meta = $p->{meta};
    say "  Updating $meta->{name}-$meta->{version} tags" if $self->verbose;

    my $tags = $meta->{tags} or return $self;

    for my $tag (@{ $tags }) {
        say "    $tag" if $self->verbose > 1;
        $self->_update_releases('by-tag' => $meta, tag => $tag);
    }
    return $self;
}

sub _update_releases {
    my $self = shift;
    my $meta = $_[1];
    my $api = PGXN::API->instance;

    # Read in metadata from the mirror.
    my $mir_file = $self->mirror_file_for(@_);
    my $mir_meta = $api->read_json_from($mir_file);

    # Read in metadata from the doc root.
    my $doc_file = $self->doc_root_file_for(@_);
    my $doc_meta = -e $doc_file ? $api->read_json_from($doc_file) : $mir_meta;

    # Update with latest release info and abstract.
    my $rels = $doc_meta->{releases}{$meta->{name}}
        = $mir_meta->{releases}{$meta->{name}};
    $rels->{abstract} = $meta->{abstract};

    # Write out the data to the doc root.
    $api->write_json_to($doc_file => $doc_meta);
}

sub update_extensions {
    my ($self, $p) = @_;
    my $meta = $p->{meta};
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

        # Copy the other release status data from the doc data.
        $mir_meta->{$_} = $doc_meta->{$_} for grep {
            $doc_meta->{$_} && $_ ne $status
        } qw(stable testing unstable);

        # Copy the version info from the doc to the mirror and add the date.
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
                # Got it. Add the release date
                $dist->{date} = $meta->{date};
            }
        }

        # Write it back out.
        $api->write_json_to($doc_file => $mir_meta);
    }

    return $self;
}

sub parse_docs {
    my ($self, $p) = @_;
    my $meta = $p->{meta};
    my $zip  = $p->{zip};
    say "  Parsing $meta->{name}-$meta->{version} docs" if $self->verbose;

    my $markup = Text::Markup->new(default_encoding => 'UTF-8');
    my $dir    = $self->doc_root_file_for(source => $meta);
    my $prefix = quotemeta "$meta->{name}-$meta->{version}";
    my $libxml = XML::LibXML->new(
        recover    => 2,
        no_network => 1,
        no_blanks  => 1,
        no_cdata   => 1,
    );

    # Find all doc files and write them out.
    my %docs;
    for my $regex (
        qr{README(?:[.][^.]+)?$}i,
        qr{docs?/},
    ) {
        for my $member ($zip->membersMatching(qr{^$prefix/$regex})) {
            next if $member->isDirectory;
            (my $fn  = $member->fileName) =~ s{^$prefix/}{};
            my $src  = catfile $dir, $fn;
            my $doc  = $libxml->parse_html_string($markup->parse(file => $src), {
                suppress_warnings => 1,
                suppress_errors   => 1,
                recover           => 2,
            });

            (my $noext = $fn) =~ s{[.][^.]+$}{};
            # XXX Nasty hack until we get + operator in URI Template v4.
            local $URI::Escape::escapes{'/'} = '/';
            my $dst  = $self->doc_root_file_for(
                doc     => $meta,
                path    => $noext,
                '+path' => $noext, # XXX Part of above-mentioned hack.
            );
            make_path dirname $dst;

            # Determine the title before we mangle the HTML.
            (my $file = $noext) =~ s{^doc/}{};
            my $title = $doc->findvalue('/html/head/title')
                     || $doc->findvalue('//h1[1]')
                     || $file;

            # Grab abstract if this looks like extension documentation.
            my $abstract = $meta->{provides}{$file}
                ? $meta->{provides}{$file}{abstract}
                : undef;

            # Clean up the HTML and write it out.
            open my $fh, '>:utf8', $dst or die "Cannot open $dst: $!\n";
            print $fh _clean_html_body($doc->findnodes('/html/body'));
            close $fh or die "Cannot close $fn: $!\n";

            $docs{$noext} = {
                title => $title,
                ($abstract) ? (abstract => $abstract) : ()
            };
        }
    }
    return \%docs;
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

sub _index {
    my $self = shift;
    push @{ $self->docs } => shift;
}

sub _rollback {
    @{ shift->docs } = ();
    return;
}

sub _commit {
    my $self = shift;
    my $docs = $self->docs;
    return unless @{ $docs };

    @{ $self->docs } = ();

    my $ksi = $self->ksi;
    for my $doc (@{ $docs }) {
        $ksi->delete_by_term( field => 'key', term => $doc->{key});
        $ksi->add_doc($doc);
    }

    return $self;
}

sub _uri_for {
    my ($self, $name, $meta, @params) = @_;
    PGXN::API->instance->uri_templates->{$name}->process(
        dist    => $meta->{name},
        version => $meta->{version},
        user    => $meta->{user},
        @params,
    );
}

sub _source_files {
    my ($self, $p) = @_;
    my $zip = $p->{zip};
    my $prefix  = quotemeta "$p->{meta}{name}-$p->{meta}{version}";
    my @files;
    for my $regex (
        qr{Change(?:s|Log)(?:[.][^.]+)?}i,
        qr{README(?:[.][^.]+)?}i,
        qr{LICENSE(?:[.][^.]+)?}i,
        qr{META[.]json},
        qr{Makefile},
        qr{MANIFEST},
        qr{\Q$p->{meta}{name}\E[.]control},
    ) {
        my ($member) = $zip->membersMatching(qr{^$prefix/$regex$});
        next unless $member;
        (my $fn = $member->fileName) =~ s{^$prefix/}{};
        push @files => $fn;
    }
    return \@files;
}

# List of allowed elements and attributes.
# http://www.w3schools.com/tags/default.asp
# http://www.w3schools.com/html5/html5_reference.asp
my %allowed = do {
    my $attrs = { title => 1, dir => 1, lang => 1 };
    map { $_ => $attrs } qw(
        a
        abbr
        acronym
        address
        area
        article
        aside
        audio
        b
        bdo
        big
        blockquote
        br
        canvas
        caption
        cite
        code
        col
        colgroup
        dd
        del
        details
        dfn
        dir
        div
        dl
        dt
        em
        figcaption
        figure
        footer
        h1
        h2
        h3
        h4
        h5
        h6
        header
        hgroup
        hr
        i
        img
        ins
        kbd
        li
        map
        mark
        meter
        ol
        output
        p
        pre
        q
        rp
        rt
        ruby
        s
        samp
        section
        small
        source
        span
        strike
        strong
        sub
        summary
        sup
        table
        tbody
        td
        tfoot
        th
        thead
        time
        tr
        tt
        u
        ul
        var
        video
        wbr
        xmp
    );
};

# A few elements may retain other attributes.
$allowed{a}        = { %{ $allowed{a} }, map { $_  => 1 } qw(href hreflang media rel target type) };
$allowed{area}     = { %{ $allowed{area} }, map { $_  => 1 } qw(alt coords href hreflang media rel shape target tytpe) };
$allowed{article}  = { %{ $allowed{article} }, cite  => 1, pubdate   => 1 };
$allowed{audio}    = { %{ $allowed{audio} }, map { $_  => 1 } qw(src) };
$allowed{canvas}   = { %{ $allowed{canvas} }, map { $_  => 1 } qw(height width) };
$allowed{col}      = { %{ $allowed{col} }, map { $_  => 1 } qw(span align valign width) };
$allowed{colgroup} = $allowed{col};
$allowed{del}      = { %{ $allowed{del} },     cite  => 1, datetime  => 1 };
$allowed{details}  = { %{ $allowed{details} }, open  => 1 };
$allowed{img}      = { %{ $allowed{img} }, map { $_  => 1 } qw(alt src height ismap usemap width) };
$allowed{ins}      = $allowed{del};
$allowed{li}       = { %{ $allowed{li} }, value  => 1 };
$allowed{map}      = { %{ $allowed{map} }, name  => 1 };
$allowed{meter}    = { %{ $allowed{meter} }, map { $_  => 1 } qw(high low min max optimum value) };
$allowed{source}   = { %{ $allowed{source} }, map { $_  => 1 } qw(media src type) };
$allowed{ol}       = { %{ $allowed{ol} }, revese  => 1, start  => 1 };
$allowed{q}        = { %{ $allowed{q} }, cite  => 1 };
$allowed{section}  = $allowed{q};
$allowed{table}    = { %{ $allowed{table} }, map { $_  => 1 } qw(sumary width) };
$allowed{tbody}    = { %{ $allowed{tbody} }, map { $_  => 1 } qw(align valign) };
$allowed{td}       = { %{ $allowed{td} }, map { $_  => 1 } qw(align colspan headers height nowrap rowspan scope valign width) };
$allowed{tfoot}    = $allowed{tbody};
$allowed{th}       = $allowed{td};
$allowed{tfoot}    = $allowed{tbody};
$allowed{tr}       = $allowed{tbody};
$allowed{time}     = { %{ $allowed{time} }, datetime  => 1, pubdate => 1 };
$allowed{video}    = { %{ $allowed{video} }, map { $_  => 1 } qw(audio height poster src width) };

# We delete all other elements except for these, for which we keep text.
my %keep_children = map { $_ => 1 } qw(
    blink
    center
    font
);

sub _clean_html_body {
    my $top = my $elem = shift;

    # Create an element for the table of contents.
    my $toc = XML::LibXML::Element->new('div');
    $toc->setAttribute(id => 'pgxntoc');
    $toc->appendText("\n    ");
    my $contents = XML::LibXML::Element->new('h3');
    $contents->appendText('Contents');
    $toc->appendChild($contents);
    $toc->appendText("\n    ");

    my $topul = my $ul = XML::LibXML::Element->new('ul');
    $ul->setAttribute(class => 'pgxntocroot');
    $toc->addChild($ul);

    my %gen_ids;
    my $level = 1;

    while ($elem) {
        if ($elem->nodeType == XML_ELEMENT_NODE) {
            my $name = $elem->nodeName;
            if ($name eq 'body') {
                # Remove all attributes and rewrite it as a div.
                $elem->removeAttribute($_) for map {
                    $_->nodeName
                } $elem->attributes;
                $elem->setNodeName('div');
                $elem->setAttribute(id => 'pgxnbod');
                $elem = $elem->firstChild || last;
                next;
            }

            if (my $attrs = $allowed{$name}) {
                # Keep only allowed attributes.
                $elem->removeAttribute($_) for grep { !$attrs->{$_} }
                    map { $_->nodeName } $elem->attributes;

                if ($name =~ /^h([123])$/) {
                    my $header = $1;
                    # Create an ID.
                    # http://www.w3schools.com/tags/att_standard_id.aps
                    (my $id = $elem->textContent) =~ s{^([^a-zA-Z])}{L$1};
                    $id =~ s{[^a-zA-Z0-9_:.-]+}{.}g;
                    $id .= $gen_ids{$id}++ || '';
                    $elem->setAttribute(id => $id);
                    if ($header != $level) {
                        # Add and remove unordered lists as needed.
                        while ($header < $level) {
                            $ul->appendText("\n    " . '  ' x (2 * $level - 2));
                            my $li = $ul->parentNode;
                            $li->appendText("\n    " . '  ' x (2 * $level - 3));
                            $ul = $li->parentNode;
                            $level--;
                        }
                        while ($header > $level) {
                            my $newul = XML::LibXML::Element->new('ul');
                            my $li = $ul->find('./li[last()]')->shift || do {
                                XML::LibXML::Element->new('li');
                            };
                            $li->appendText("\n    " . '  ' x (2 * $level));
                            $li->addChild($newul);
                            $ul = $newul;
                            $level++;
                        }
                    }

                    # Add the item to the TOC.
                    my $li = XML::LibXML::Element->new('li');
                    my $a = XML::LibXML::Element->new('a');
                    $a->setAttribute(href => "#$id");
                    $a->appendText($elem->textContent);
                    $li->addChild($a);
                    $ul->appendText("\n    " . '  ' x (2 * $level - 1));
                    $ul->addChild($li);
                }

                # Descend into children.
                if (my $next = $elem->firstChild) {
                    $elem = $next;
                    next;
                }
            } else {
                # You are not wanted.
                my $parent = $elem->parentNode;
                if ($keep_children{$name}) {
                    # Keep the children.
                    $parent->insertAfter($_, $elem) for reverse $elem->childNodes;
                }

                # Take it out and jump to the next sibling.
                my $next = $elem;
                NEXT: {
                    if (my $sib = $next->nextSibling) {
                        $next = $sib;
                        last;
                    }

                    # No sibling, try parent's sibling
                    $next = $next->parentNode;
                    redo if $next && $next ne $top;
                }
                $parent->removeChild($elem);
                $elem = $next;
                next;
            }
        }

        # Find the next node.
        NEXT: {
            if (my $sib = $elem->nextSibling) {
                $elem = $sib;
                last;
            }

            # No sibling, try parent's sibling
            $elem = $elem->parentNode;
            redo if $elem;
        }
    }

    # Add the documentation to the overall document and stringify.
    my $doc = XML::LibXML::Element->new('div');
    $doc->setAttribute(id => 'pgxndoc');
    $doc->appendText("\n  ");
    $doc->addChild($toc);
    $topul->appendText("\n    ");
    $toc->appendText("\n  ");
    $doc->appendText("\n  ");
    $doc->addChild($top);
    $top->appendText("");
    $doc->appendText("\n");
    return $doc->toString . "\n";
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
