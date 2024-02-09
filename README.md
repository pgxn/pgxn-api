PGXN/API
========

This application provides a REST API for flexible searching of PGXN distribution
metadata and documentation. See [the docs](https://github.com/pgxn/pgxn-api/wiki)
for details on using the API.

Installation
------------

To install this module, type the following:

    perl Build.PL
    ./Build
    ./Build test
    ./Build install

Dependencies
------------

PGXN-API requires Perl 5.14 and the following modules:

*   Archive::Zip
*   Cwd
*   CommonMark
*   Data::Dump
*   Digest::SHA1
*   Email::MIME::Creator
*   Email::Sender::Simple
*   File::Path
*   File::Copy::Recursive
*   File::Spec
*   JSON
*   JSON::XS
*   List::Util
*   List::MoreUtils
*   Lucy
*   Moose
*   Moose::Util::TypeConstraints
*   MooseX::Singleton
*   namespace::autoclean
*   PGXN::API::Searcher
*   Plack
*   Plack::App::Directory
*   Plack::App::File
*   Plack::Middleware::JSONP
*   Plack::Builder
*   Text::Markup
*   URI::Template
*   XML::LibXML

Copyright and License
---------------------

Copyright (c) 2011-2024 David E. Wheeler.

This module is free software; you can redistribute it and/or modify it under
the [PostgreSQL License](http://www.opensource.org/licenses/postgresql).

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
