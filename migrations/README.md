# Migrations

## Baseline

`0000_baseline.sql` is a `pg_dump --schema-only` snapshot of the current HEAD of the migration chain. There are no Git tags yet, so no releases have been tagged; the baseline therefore represents the current migration history rather than any fixed release version.

That snapshot matches what every deployment that has been migrated through the full numbered chain already has.

## Baseline upgrade path

### 1. On a fresh database

```bash
psql -U postgres -d sp -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
psql -U postgres -d sp < migrations/0000_baseline.sql
```

The database is now at the current HEAD state with no further migrations to apply.

### 2. On an existing deployment at the current chain

An existing deployment whose `_sqlx_migrations` table already contains all 125 numbered versions will be identified as already at baseline, so no migrations run at all:

```bash
psql -U postgres -d sp < migrations/0000_baseline.sql
```

This is intended to be a no-op:

- `CREATE EXTENSION IF NOT EXISTS`, `CREATE TABLE IF NOT EXISTS`,
  `CREATE MATERIALIZED VIEW IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`
  are all idempotent.
- The old 247 numbered migration files are preserved in `migrations/archive/`
  for reference and audits; they are not replaced.

## Verifying a fresh baseline

```bash
docker exec -it sp-pg psql -U postgres -d sp -c "SELECT count(*) AS tables FROM pg_tables WHERE schemaname='public';"
docker exec -it sp-pg psql -U postgres -d sp -c "SELECT count(*) AS matviews FROM pg_matviews;"
docker exec -it sp-pg psql -U postgres -d sp -c "SELECT count(*) AS functions FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public';"
```

A fresh baseline apply produces the same table/view/function counts that the
full numbered chain produces: 130 tables, 7 materialized views, 70 functions.

## `sqlx` stamp for the baseline

When `sqlx` runs migrations it records each applied migration version in the
`_sqlx_migrations` table. After loading the baseline on a fresh database,
stamp the baseline as applied so `sqlx` does not try to re-apply the numbered
chain:

```bash
psql -U postgres -d sp -c \
  "INSERT INTO _sqlx_migrations(id, checksum) VALUES ('0000_baseline', '<sha384>') ON CONFLICT DO NOTHING;"
```

The sha384 checksum below is for an old (pre-repair) dump and is only a
reference shape. After the baseline is regenerated in CI, record the real
checksum there.
```
