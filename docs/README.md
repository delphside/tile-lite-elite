# Tile Lite Elite Docs

This folder collects the design notes and operating guides for Tile Lite Elite, organized into four numbered groups. Within a group, the number order is the reading order; across groups, roughly: understand the system (1.x) → understand a specific domain (2.x) → run it through its lifecycle (3.x) → look something up (4.x).

## 1.x — Meta: overview, functionality, architecture

- [1.0 Rules](1.0-rules.md) — the decisions about how the service behaves, cited by id from tests and commits
- [1.1 Architecture](1.1-architecture.md) — system overview, deployment topology, guiding principles and roles
- [1.2 Components and Interactions](1.2-components-and-interactions.md) — component diagram, move/turn sequence diagrams
- [1.3 Technology Decisions](1.3-technology-decisions.md) — why Axum/SQLite/Dioxus/etc.
- [1.4 Roadmap](1.4-roadmap.md) — CLI prototype → UI direction → MVP → v1 → Later

## 2.x — Design & Domain

- [2.1 Rules Engine](2.1-rules-engine.md)
- [2.2 Rules Engine Implementation](2.2-rules-engine-implementation.md)
- [2.3 Engine Interface](2.3-engine-interface.md)
- [2.4 Persistence](2.4-persistence.md) — original persistence design principles (see [4.2](4.2-database-schema.md) for the as-built schema)
- [2.5 Authentication](2.5-authentication.md)
- [2.6 Authentication Examples](2.6-authentication-examples.md) — worked request/response walkthroughs
- [2.7 Authentication and Invitations](2.7-authentication-and-invitations.md)

## 3.x — Lifecycle

Run in this order for a typical change: Setup once, then Development → Testing, CI & Release → Deployment → Production Support & Maintenance repeatedly.

- [3.0 Tools](3.0-tools.md) — every script, linking to where it's explained
- [3.1 Setup](3.1-setup.md) — one-time: dev machine, Oracle VM, HTTPS, troubleshooting
- [3.2 Development](3.2-development.md) — running services locally, building, resetting local state
- [3.3 Testing, CI & Release](3.3-testing-ci-and-release.md) — `cargo test`, GitHub Actions CI, the local preview environment, the end-to-end release runbook, and how `deploy.sh` ships an image
- [3.4 Production Environment & Operations](3.4-production-environment.md) — the running system: container topology, secrets, admin CLI, inspecting the database, logging, backups, wiping production
- [3.5 Word Lists & Dictionaries](3.5-word-lists-and-dictionaries.md) — how a published word list becomes the trie the engine searches: sourcing, normalising, generating the denylist and greylist, and the runbooks for changing either

## 4.x — Reference

Facts you look up rather than read start to end.

Each of these carries a **freshness stamp** under its title — the commit its
contents were last checked against the code. Only the 4.x documents have one:
they're the ones making falsifiable claims ("these are the columns", "this is
every endpoint"), so they're the ones that can silently go wrong when the code
moves. A stamp turns "is this still true?" into an answerable question —
`git log <stamp>..HEAD -- crates/` — rather than a feeling. Update it when you
re-verify a document, not merely when you edit one.

There is no per-document changelog, deliberately: `git log --follow --
docs/<file>` already gives one, with the diffs and the reasoning attached, and
can't drift the way a hand-maintained list would.

- [4.1 Configuration](4.1-configuration.md) — environments, environment variables, versioning scheme
- [4.2 Database Schema](4.2-database-schema.md)
- [4.3 API Schema](4.3-api-schema.md) — every HTTP/WebSocket endpoint and DTO
- [4.4 snapshot_json Schema](4.4-snapshot-json-schema.md) — the authoritative game-state JSON blob's shape
- [4.5 Data Dictionary](4.5-data-dictionary.md) — where each game field lives across snapshot/DB/DTO, and its kind
- [4.6 Client-Local Storage](4.6-client-local-storage.md) — StoredAuth / chat watermarks kept on the device

## How these documents are written

Five habits, learned by breaking them.

**Give a commit's app version alongside its id.** `25e9e09` alone dates a
change only for somebody willing to go and look it up; `25e9e09` (app 0.4.12)
places it in the release history a reader already carries. The id stays,
because it is the thing you can `git show`.

**Reference answers "what is there" and "what do I type".** Not "why is it
like that". The why belongs in an overview section or a 2.x design note. A
reader looking up a command should not have to read the reasoning that
produced it.

**Imply the rationale rather than narrating it.** Often an adjective carries
what a sentence would restate — "the safe default", "one throwaway worktree",
"a single source of truth". Explaining the history to explain the thinking is
tempting and usually unnecessary.

Where history does earn its place is a rule that would otherwise look
arbitrary and get tidied away by someone who has never been bitten. Keep it
then, and keep it short. The test: would a reader do the wrong thing without
this? If it only makes the decision feel justified, cut it.

**No issue numbers.** `#42` means nothing once the tracker has moved on, and
these documents outlive it. Provenance belongs in commit messages, which are
permanent and carry their own context; the document carries current truth.

**Say what we do, not what we rejected.** Options considered and dropped
belong to the discussion, not the document. "We change the dates in the
database" — not "not the system clock, and not the CLI either". The reader
never proposed those.

This is the hardest one to hold, because the alternatives are vivid to
whoever just chose between them and invisible to everyone else. It is also
where documents rot: a decision changes, the new choice is written in, and
the old one survives as an aside that now describes something nobody does.

Where a rejected option was carrying a real constraint, keep the constraint
and drop the comparison. "It must be in-module: backdating needs `state.db`"
says everything "rather than an external test" did, and stays true when the
alternative is forgotten.

**Say what is, not what should be.** `should`, `may` and `typically` describe
an intention. "Each environment has one SQLite database" beats "the project
should use one primary database file per environment".

## Current Direction

The project is moving toward a client-server design where the server owns game state and rule enforcement, and clients are thin presentation layers for web, desktop, CLI, or mobile.

The engine system is designed so multiple computer engines can plug into the server and play against human or computer opponents.

The project is a hobby project, so the architecture should favor local-first development and hosting options that are free or nearly free to run.

Axum is the backend web server layer for the project; no separate web server is required unless deployment needs change later.
