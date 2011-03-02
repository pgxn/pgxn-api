#!/usr/local/bin/perl -w

use 5.12.0;
use utf8;
use lib 'lib';
use PGXN::API::Router;
PGXN::API::Router->app;
