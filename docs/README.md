# Tile Lite Elite Docs

The documentation for Tile Lite Elite, in five numbered groups, each covering
one scope ([3.9](3.9-writing-documents.md)):

| group | section | covers |
| --- | --- | --- |
| 1.x | [Overview](#1x-overview) | overviews: the rules, architecture, design and technologies, programme organisation, the roadmap, current work, and the documentation |
| 2.x | [Functional design](#2x-functional-design) | the end-to-end design of each functional area |
| 3.x | [Programme](#3x-programme) | the programme in detail: its organisation, processes and assets |
| 4.x | [Reference](#4x-reference) | reference: every current value |
| 5.x | [Programme definition and processes](#5x-programme-definition-and-processes) | how the programme is run: its processes, its tooling and the board |

## I need to

| task | read |
| --- | --- |
| set up a development machine | [3.1 Setup](3.1-setup.md) |
| build a production or rehearsal host | [3.4 Building a host](3.4-production-environment.md#building-a-host) |
| run it locally | [3.2 Development](3.2-development.md) |
| test, release or roll back | [3.3 Testing, CI & Release](3.3-testing-ci-and-release.md) |
| operate production | [3.4 Production Environment](3.4-production-environment.md) |
| raise, plan or ship a change | [3.6 The Change Lifecycle](3.6-change-lifecycle.md), and the one-page rules in [`CLAUDE.md`](../CLAUDE.md) |
| find a script | [3.0 Tools](3.0-tools.md) for the application's, [5.0 Programme tooling](5.0-programme-tooling.md) for the programme's |
| find where a fact lives, before writing it | [1.6 Document map](1.6-document-map.md) |
| write or change a document | [3.9 Writing documents](3.9-writing-documents.md) |
| see what is in flight | [1.5 Work in progress](1.5-work-in-progress.md) |

**Two rules for every document**: one fact has one home, and every other
mention links to it; and a numbered document says what is true now, with the
history in the issue or the commit.

## 1.x Overview

- [1.0 Rules](1.0-rules.md) — the decisions about how the service behaves, cited by id from tests and commits
- [1.1 Architecture](1.1-architecture.md) — system overview, deployment topology, guiding principles and roles
- [1.2 Components and Interactions](1.2-components-and-interactions.md) — component diagram, move/turn sequence diagrams
- [1.3 Technology Decisions](1.3-technology-decisions.md) — why Axum/SQLite/Dioxus/etc.
- [1.4 Roadmap](1.4-roadmap.md) — CLI prototype → UI direction → MVP → v1 → Later
- [1.5 Work in progress](1.5-work-in-progress.md) — what is in flight, drawn from the issues and regenerated, never typed
- [1.6 Document map](1.6-document-map.md) — every heading in `docs/`, generated, for finding where a fact belongs
- [1.7 Programme](1.7-programme.md) — how the work is organised: who decides, the workstreams, how a change is made, and where things are recorded

## 2.x Functional design

- [2.1 Rules Engine](2.1-rules-engine.md)
- [2.2 Rules Engine Implementation](2.2-rules-engine-implementation.md)
- [2.3 Engine Interface](2.3-engine-interface.md) — the trait an engine implements, and how the server runs one
- [2.4 Persistence](2.4-persistence.md) — what is persisted and where, and how long games are kept (the tables are [4.2](4.2-database-schema.md))
- [2.5 Authentication](2.5-authentication.md) — players, sessions, passwords and email
- [2.6 Authentication Examples](2.6-authentication-examples.md) — worked request/response walkthroughs
- [2.7 Seats and Invitations](2.7-authentication-and-invitations.md) — how seats are claimed and a waiting game's roster is managed
- [2.8 Engine Performance](2.8-engine-performance.md) — what the engine's search costs, and where in a game the work falls

## 3.x Programme

- [3.0 Tools](3.0-tools.md) — what the owner runs by task, and every script that acts on the application
- [3.1 Setup](3.1-setup.md) — one-time: the development machine, and troubleshooting its build
- [3.2 Development](3.2-development.md) — running services locally, building, resetting local state
- [3.3 Testing, CI & Release](3.3-testing-ci-and-release.md) — `cargo test`, GitHub Actions CI, the local preview environment, the end-to-end release runbook, and how `deploy.sh` ships an image
- [3.4 Production Environment & Operations](3.4-production-environment.md) — building a host, and the running system: container topology, secrets, admin CLI, inspecting the database, logging, backups, wiping production
- [3.5 Word Lists & Dictionaries](3.5-word-lists-and-dictionaries.md) — how a published word list becomes the trie the engine searches: sourcing, normalising, generating the denylist and greylist, and the runbooks for changing either
- [3.6 The Change Lifecycle](3.6-change-lifecycle.md) — from an issue raised to production: triage, projects, branches, releases and deliveries, and the rules that govern each. Its sibling 3.3 holds the machinery those rules run on
- [3.7 Workstreams](3.7-workstreams.md) — the ten workstreams work is filed against, what each owns, and the boundaries between them
- [3.8 Programme activities](3.8-programme-activities.md) — the recurring activities, their cadence and who does them
- [3.9 Writing documents](3.9-writing-documents.md) — what each document holds, and how it is written
- [3.10 Benchmarking](3.10-benchmarking.md) — measuring the engine's performance, and reading a run

## 4.x Reference

- [4.1 Configuration](4.1-configuration.md) — environments, environment variables, versioning scheme
- [4.2 Database Schema](4.2-database-schema.md)
- [4.3 API Schema](4.3-api-schema.md) — every HTTP/WebSocket endpoint and DTO
- [4.4 snapshot_json Schema](4.4-snapshot-json-schema.md) — the authoritative game-state JSON blob's shape
- [4.5 Data Dictionary](4.5-data-dictionary.md) — where each game field lives across snapshot/DB/DTO, and its kind
- [4.6 Client-Local Storage](4.6-client-local-storage.md) — StoredAuth / chat watermarks kept on the device
- [4.7 Log Events](4.7-log-events.md) — every event the server writes, the twenty-five field names the whole log uses, and the schema a test compares the code against
- [4.8 Artefacts](4.8-artefacts.md) — the register of things under change control that leave no trace in git: host files and cloud resources. Also the answer to *what else was on that box?*
- [4.9 Delivery log](4.9-delivery-log.md) — one row per delivery: what changed in production and when. Starts at #174; earlier deliveries are recoverable from the `prod-*` tags.

## 5.x Programme definition and processes

- [5.0 Programme tooling](5.0-programme-tooling.md) — the two kinds of tooling, and every script that acts on the programme's records
- [5.5 GitHub Project Board](5.5-github-project-board.md) — the issue types, fields, board and accounts in GitHub, and the strings the tooling reads from them

## Outside the numbered set

- [changes/](changes/) — the design and test documents for each change, kept after it ships
- [reports/](reports/) — reports the programme produces on a cadence
- [templates/](templates/) — the forms the numbered documents link to
