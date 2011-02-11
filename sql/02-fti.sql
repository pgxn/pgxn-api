-- sql/02-fti.sql SQL Migration

SET client_min_messages TO warning;
SET log_min_messages    TO warning;

BEGIN;

CREATE TABLE fti (
    type       TEXT,
    name       TEXT,
    abstract   TEXT,
    owner      TEXT,
    created_at TIMESTAMPTZ,
    document   TEXT
);

COMMIT;
