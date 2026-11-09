# Tile Lite Elite docs

The documentation for Tile Lite Elite, in four numbered groups, each covering
one scope. The numbers are Tile Lite Elite's range, `4.x.y`, in the
programme-wide numbering
([1.5](https://github.com/delphside/programme/blob/main/docs/1.5-writing-documents.md#each-range-covers-one-scope)).

| Group | Section |
| --- | --- |
| 4.1 | [Overview](#41-overview) |
| 4.2 | [Functional design](#42-functional-design) |
| 4.3 | [Development and operation](#43-development-and-operation) |
| 4.4 | [Reference](#44-reference) |

## I need to

| Task | Read |
| --- | --- |
| set up a development machine | [4.3.1 Setup](4.3.1-setup.md) |
| build a production or rehearsal host | [4.3.4 Building a host](4.3.4-production-environment.md#building-a-host) |
| run it locally | [4.3.2 Development](4.3.2-development.md) |
| test, release or roll back | [4.3.3 Testing, CI and release](4.3.3-testing-ci-and-release.md), and the test policy in [1.9](https://github.com/delphside/programme/blob/main/docs/1.9-testing-standards.md) |
| operate production | [4.3.4 Production environment and operations](4.3.4-production-environment.md) |
| raise, plan or ship a change | [1.2 The change lifecycle](https://github.com/delphside/programme/blob/main/docs/1.2-change-lifecycle.md), and the one-page rules in [`CLAUDE.md`](../CLAUDE.md) |
| find a script | [4.3.0 Tools](4.3.0-tools.md) for the application's, [1.1 Programme tooling](https://github.com/delphside/programme/blob/main/docs/1.1-programme-tooling.md) for the programme's |
| look up a value | [4.4 Reference](#44-reference) |
| find where a fact lives, before writing it | [4.1.6 Document map](4.1.6-document-map.md) |
| write or change a document | [1.5 Writing documents](https://github.com/delphside/programme/blob/main/docs/1.5-writing-documents.md) |
| see what is in flight | [4.1.5 Work in progress](4.1.5-work-in-progress.md) |

## 4.1 Overview

- [4.1.0 Rules](4.1.0-rules.md) — the decisions about how the service
  behaves, cited by ID from tests and commits
- [4.1.1 Architecture](4.1.1-architecture.md) — system overview, deployment
  topology, guiding principles and roles
- [4.1.2 Components and interactions](4.1.2-components-and-interactions.md) —
  the move sequence diagram and its notes
- [4.1.3 Technology decisions](4.1.3-technology-decisions.md) — why Axum,
  SQLite, Dioxus and the rest
- [4.1.4 Roadmap](4.1.4-roadmap.md) — what the minimum viable product (MVP)
  holds, what has been built since, and what is left for v1 and later
- [4.1.5 Work in progress](4.1.5-work-in-progress.md) — what is in flight,
  generated from the issues
- [4.1.6 Document map](4.1.6-document-map.md) — every heading in `docs/`,
  generated, for finding where a fact belongs

## 4.2 Functional design

- [4.2.0 Design map](4.2.0-design-map.md) — the Container and Component views,
  generated
- [4.2.1 Rules engine design](4.2.1-rules-engine.md) — whether a move is
  legal and what it scores
- [4.2.2 Rules engine modules and types](4.2.2-rules-engine-implementation.md)
  — the modules and types of `rules-shared`
- [4.2.3 Engine interface](4.2.3-engine-interface.md) — the trait an engine
  implements, and how the server runs one
- [4.2.4 Persistence](4.2.4-persistence.md) — what is persisted and where, and
  how long games are kept (the tables are [4.4.2](4.4.2-database-schema.md))
- [4.2.5 Authentication and player recognition](4.2.5-authentication.md) —
  players, sessions, passwords and email
- [4.2.6 Authentication and invitation examples](4.2.6-authentication-examples.md)
  — worked request and response walkthroughs
- [4.2.7 Seats and invitations](4.2.7-authentication-and-invitations.md) — how
  seats are claimed and a waiting game's roster is managed
- [4.2.8 Engine performance](4.2.8-engine-performance.md) — what the engine's
  search costs, and where in a game the work falls

## 4.3 Development and operation

- [4.3.0 Tools](4.3.0-tools.md) — what the owner runs by task, and every
  script that acts on the application
- [4.3.1 Setup](4.3.1-setup.md) — one-time: the development machine, cloud
  sessions and troubleshooting the build
- [4.3.2 Development](4.3.2-development.md) — running services locally,
  building, resetting local state
- [4.3.3 Testing, CI and release](4.3.3-testing-ci-and-release.md) —
  `cargo test`, GitHub Actions CI, the local preview environment, the
  end-to-end release runbook and how `deploy.sh` ships an image
- [4.3.4 Production environment and operations](4.3.4-production-environment.md)
  — building a host, and the running system: container topology, secrets,
  admin CLI, inspecting the database, logging, monitoring, backups, changing
  production configuration, keeping the hosts current and wiping production
- [4.3.5 Word lists and dictionaries](4.3.5-word-lists-and-dictionaries.md) —
  how a published word list becomes the trie the engine searches: sourcing,
  normalising, generating the denylist and greylist, and the runbooks for
  changing either
- [4.3.10 Benchmarking](4.3.10-benchmarking.md) — measuring the engine's
  performance, and reading a run

## 4.4 Reference

- [4.4.1 Configuration](4.4.1-configuration.md) — environments, environment
  variables, rate limits, infrastructure configuration and the versioning
  scheme
- [4.4.2 Database schema](4.4.2-database-schema.md) — the tables and columns
- [4.4.3 API schema](4.4.3-api-schema.md) — every HTTP and WebSocket endpoint
  and data transfer object
- [4.4.4 `snapshot_json` schema](4.4.4-snapshot-json-schema.md) — the
  authoritative game-state JSON blob's shape
- [4.4.5 Data dictionary](4.4.5-data-dictionary.md) — where each game field
  lives across the snapshot, the database and the transfer objects, and its
  kind
- [4.4.6 Client-local storage](4.4.6-client-local-storage.md) — `StoredAuth` and
  chat watermarks kept on the device
- [4.4.7 Log events](4.4.7-log-events.md) — every event the server writes, the
  field names the whole log uses, and the schema a test compares the code
  against

## The programme's documents

The processes, the tooling and Tile Lite Elite's records are in the
[programme repository](https://github.com/delphside/programme). The
`programme/` folder of this repository is a pinned copy of it, for the rules;
the records are read in the live checkout (`../programme`, or wherever
`PROGRAMME_DIR` says).

- [1.0 Programme](https://github.com/delphside/programme/blob/main/docs/1.0-programme.md)
  — how the work is organised: who decides, the workstreams, how a change is
  made and where things are recorded
- [1.1 Programme tooling](https://github.com/delphside/programme/blob/main/docs/1.1-programme-tooling.md)
  — the two kinds of tooling, and every script that acts on the programme's
  records
- [1.2 The change lifecycle](https://github.com/delphside/programme/blob/main/docs/1.2-change-lifecycle.md)
  — from an issue raised to production: triage, projects, branches, releases
  and deliveries, and the rules that govern each
- [1.3 Workstreams](https://github.com/delphside/programme/blob/main/docs/1.3-workstreams.md)
  — programme and application, and the generic workstreams: what each owns,
  and the boundaries between them
- [1.4 Programme activities](https://github.com/delphside/programme/blob/main/docs/1.4-programme-activities.md)
  — the recurring activities, their cadence and who does them
- [1.5 Writing documents](https://github.com/delphside/programme/blob/main/docs/1.5-writing-documents.md)
  — what each document holds, and how it is written
- [1.6 GitHub project board](https://github.com/delphside/programme/blob/main/docs/1.6-github-project-board.md)
  — the issue types, fields, board and accounts in GitHub, and the strings the
  tooling reads from them
- [1.7 Roles and responsibilities](https://github.com/delphside/programme/blob/main/docs/1.7-roles-and-responsibilities.md)
  — each role's purpose, decisions and reading list, and who decides what
- [1.8 Service desk](https://github.com/delphside/programme/blob/main/docs/1.8-service-desk.md)
  — how a player's request, incident or complaint arrives as a Ticket, is
  answered and is closed
- [1.9 Testing standards](https://github.com/delphside/programme/blob/main/docs/1.9-testing-standards.md)
  — the test policy and strategy, and the standards every test is held to
- [1.10 Development standards](https://github.com/delphside/programme/blob/main/docs/1.10-development-standards.md)
  — how code is built: settings, identifiers, exit statuses, comments and each
  language's standard
- [3.1.1 Delivery log](https://github.com/delphside/programme/blob/main/applications/tile-lite-elite/3.1.1-delivery-log.md)
  — one row per delivery: which planned pieces of work reached their users,
  and when
- [3.1.2 Artefacts](https://github.com/delphside/programme/blob/main/applications/tile-lite-elite/3.1.2-artefacts.md)
  — each artefact's route, and the register of things under change control
  that leave no trace in git
- [3.1.3 Capacity plan](https://github.com/delphside/programme/tree/main/applications/tile-lite-elite/3.1.3-capacity-plan),
  [3.1.4 Workstreams](https://github.com/delphside/programme/blob/main/applications/tile-lite-elite/3.1.4-workstreams.md)
  and [3.1.5 Roles](https://github.com/delphside/programme/blob/main/applications/tile-lite-elite/3.1.5-roles.md)
  — this application's capacity plans, its workstreams and who holds each role
  here
- [3.1.6 Profile](https://github.com/delphside/programme/blob/main/applications/tile-lite-elite/3.1.6-profile.md)
  — what the programme's processes need to know about this application
- [3.1.7 Change documents](https://github.com/delphside/programme/tree/main/applications/tile-lite-elite/3.1.7-changes)
  — the design and test documents for each change, kept after it ships
