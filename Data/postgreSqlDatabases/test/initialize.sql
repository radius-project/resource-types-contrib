CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gin;
CREATE SCHEMA IF NOT EXISTS rtc_nightly;
CREATE TABLE IF NOT EXISTS rtc_nightly.seed (id integer PRIMARY KEY, value text NOT NULL);
INSERT INTO rtc_nightly.seed (id, value) VALUES (1, 'nightly-seed')
  ON CONFLICT (id) DO UPDATE SET value = EXCLUDED.value;
