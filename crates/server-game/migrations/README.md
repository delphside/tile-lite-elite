# Migrations

Versioned schema migrations, run at server startup by sqlx's `Migrator`
(`persistence::migrate`, which runs `sqlx::migrate!("./migrations")`). The
tables they create are in [4.4.2](../../../docs/4.4.2-database-schema.md#actual-current-shape).

## Rules

1. **Never edit a migration file once it has been applied anywhere**, on a
   local database or on production. sqlx checksums each applied migration, and
   a changed file makes the next start fail with `MigrateError::VersionMismatch`
   ([4.4.2](../../../docs/4.4.2-database-schema.md#notes)).
2. **To change the schema, add a file** named `NNNN_description.sql`, `NNNN`
   being the next 4-digit number.
   - Write ordinary DDL: `alter table ... add column ...`, or a plain
     `create table ...` for a new table.
   - Leave out `if not exists`. Only `0001_baseline.sql` uses it, because every
     database it met already had the same shape. A migration applies once and
     fails loudly when it cannot.
3. **Keep a change additive**, as the `#[serde(default = ...)]` fields of
   `PersistedGame` and `PersistedVariantRules` in `persistence.rs` are. An older
   image does not boot against a newer schema, which is what a rollback across a
   migration meets
   ([4.3.3](../../../docs/4.3.3-testing-ci-and-release.md#112-roll-back-across-a-migration)).
4. **Drop or rename a column in two steps.** The running deployment still reads
   the column while the new one starts, so ship the new shape with the old
   column still read, then remove the old column in a later migration.

## What happens without you

- `build.rs` reruns the build when anything in `migrations/` changes, so the
  next `cargo build` or `cargo run` embeds a new file.
- Parallel test runs need no migration lock: sqlx's cross-connection lock is a
  no-op for SQLite, and each test in `crates/server-game/src/app/tests.rs` opens
  its own database file.
