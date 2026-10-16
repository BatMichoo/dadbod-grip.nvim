-- Disposable local cluster only. No persistent server settings are changed.
\set ON_ERROR_STOP on
BEGIN;
CREATE ROLE grip_live_reader LOGIN NOSUPERUSER NOINHERIT NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE grip_live_full LOGIN NOSUPERUSER NOINHERIT NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE SCHEMA grip_live;
CREATE SCHEMA grip_live_archive;
CREATE SCHEMA grip_live_hidden;
CREATE TABLE grip_live.events (id int, occurred date) PARTITION BY RANGE (occurred);
CREATE TABLE grip_live.events_2026 PARTITION OF grip_live.events
  FOR VALUES FROM ('2026-01-01') TO ('2027-01-01') PARTITION BY RANGE (occurred);
CREATE TABLE grip_live.events_2026_01 PARTITION OF grip_live.events_2026
  FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE grip_live_archive.events_2026_02 PARTITION OF grip_live.events_2026
  FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE grip_live.events_default PARTITION OF grip_live.events DEFAULT;
INSERT INTO grip_live.events VALUES (1, '2026-01-10'), (2, '2026-02-10'), (3, '2028-01-10');
CREATE INDEX grip_live_events_idx ON grip_live.events (id);
CREATE TABLE grip_live.private_parent (id int) PARTITION BY RANGE (id);
CREATE TABLE grip_live.orphan_leaf PARTITION OF grip_live.private_parent FOR VALUES FROM (0) TO (10);
INSERT INTO grip_live.orphan_leaf VALUES (4);
CREATE TABLE grip_live.column_only (id int, secret text);
INSERT INTO grip_live.column_only VALUES (5, 'synthetic');
CREATE TABLE grip_live_hidden.hidden_usage (id int);
CREATE TABLE grip_live.secured (id int);
INSERT INTO grip_live.secured VALUES (1), (2);
ALTER TABLE grip_live.secured ENABLE ROW LEVEL SECURITY;
CREATE POLICY grip_live_read_policy ON grip_live.secured FOR SELECT USING (id = 1);
CREATE TABLE grip_live.legacy (id int);
CREATE TABLE grip_live.legacy_child () INHERITS (grip_live.legacy);
CREATE TABLE grip_live.other_parent (id int);
CREATE TABLE grip_live.multi_child () INHERITS (grip_live.legacy, grip_live.other_parent);
CREATE VIEW grip_live.recent_events AS SELECT * FROM grip_live.events;
GRANT USAGE ON SCHEMA grip_live TO grip_live_reader;
GRANT SELECT ON grip_live.events, grip_live.orphan_leaf, grip_live.secured TO grip_live_reader;
GRANT SELECT (id) ON grip_live.column_only TO grip_live_reader;
GRANT SELECT ON grip_live_hidden.hidden_usage TO grip_live_reader;
GRANT USAGE ON SCHEMA grip_live, grip_live_archive, grip_live_hidden TO grip_live_full;
GRANT SELECT ON ALL TABLES IN SCHEMA grip_live, grip_live_archive, grip_live_hidden TO grip_live_full;
CREATE FUNCTION grip_live.calc(value integer) RETURNS integer LANGUAGE sql AS 'SELECT value + 1';
CREATE FUNCTION grip_live.calc(value text) RETURNS text LANGUAGE sql AS 'SELECT value || ''_text''';
CREATE PROCEDURE grip_live.touch(value integer) LANGUAGE sql AS 'SELECT value';
COMMIT;
