#!perl -w

use strict;
use Test::More;
eval "use Test::Spelling";
plan skip_all => "Test::Spelling required for testing POD spelling" if $@;

add_stopwords(<DATA>);
all_pod_files_spelling_ok();

__DATA__
XPath
xmlns
xml
namespace
namespaces
DOCTYPE
DTD
img
html
js
lang
libxml
src
uri
GitHub
