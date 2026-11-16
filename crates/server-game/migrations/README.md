# Migrations

Versioned schema migrations, run by sqlx's `Migrator` (`persistence::migrate`)
at server startup, and by a deploy as a step of its own
([4.3.7 §5](../../../docs/4.3.7-how-testing-and-release-work.md#5-how-deploysh-ships-an-image)).

The folder holds one `NNNN_description.sql` per schema change, from
`0001_baseline.sql` on, applied in number order. The tables they create are in
[4.4.2](../../../docs/4.4.2-database-schema.md#actual-current-shape).

## Rules

1. **Never edit a migration file once it has been applied anywhere**, a local
   database included. sqlx checksums each applied migration, and a changed file
   makes the next start fail with `MigrateError::VersionMismatch`
   ([4.4.2](../../../docs/4.4.2-database-schema.md#notes)).
2. **To change the schema, add a file** named `NNNN_description.sql`, `NNNN`
   being the next 4-digit number and `description` in lower-case snake case.
   - Write ordinary schema statements: `alter table ... add column ...`, or a
     plain `create table ...` for a new table.
   - Leave out `if not exists`, which only `0001_baseline.sql` uses, because it
     had to be a no-op on the databases the old code had already shaped. A
     migration applies once and fails loudly when it cannot.
3. **Keep a change additive**, as the `#[serde(default = ...)]` fields of
   `PersistedGame` and `PersistedVariantRules` in `persistence.rs` are, or
   discard games as
   [4.2.4](../../../docs/4.2.4-persistence.md#games-may-be-discarded-for-a-breaking-schema-change)
   allows.
4. **Drop or rename a column in two releases.** To drop one:
   1. ship code that stops reading and writing it (a `not null` column needs a
      default first);
   2. drop it in a migration in a later release.

   To rename one:
   1. ship a migration that adds the new column and backfills it from the old
      one, with code that reads the new column and writes both;
   2. in a later release, stop writing the old column and drop it in a
      migration.

Rolling back across any migration, additive or not, restores the database from
the snapshot taken before it
([4.3.6](../../../docs/4.3.6-when-a-release-goes-wrong.md#2-roll-back-across-a-migration)).

## Build and tests

- `build.rs` reruns the build when anything in `migrations/` changes, so the
  next `cargo build` or `cargo run` embeds a new file.
- Each test in `crates/server-game/src/app/` opens and migrates a database file
  of its own (`test_database_url`), so parallel test runs share none; sqlx's
  cross-connection migration lock is a no-op for SQLite.
