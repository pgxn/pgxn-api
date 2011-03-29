#!/usr/local/bin/perl -w

use 5.12.0;
use utf8;
use lib 'lib';
use PGXN::API::Router;

my $self = shift;

my @args;
while (my $v = shift @ARGV) {
    push @args, $v => shift @ARGV
        if $v ~~ [qw(errors_to errors_from doc_root)];
}

unless (@args >= 4) {
    say STDERR "\n  Usage: $self \\
         errors_to alert\@example.com \\
         errors_from pgxn-api\@example.com \\
         [doc_root /path/to/doc/root]\n";
    exit 1;
}

PGXN::API::Router->app(@args);
