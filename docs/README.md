# Tile Lite Elite Docs

The documentation for Tile Lite Elite, in four numbered groups, each covering
one scope ([1.5](https://github.com/delphside/programme/blob/main/docs/1.5-writing-documents.md)).
The numbers are Tile Lite Elite's range, `4.x.y`, in the programme's one
numbering; the processes, the tooling and this application's records are the
programme's, and [the last section](#the-programmes-documents) says where.

| group | section | covers |
| --- | --- | --- |
| 4.1 | [Overview](#41-overview) | overviews: the rules, architecture, design and technologies, the roadmap, current work, and the documentation |
| 4.2 | [Functional design](#42-functional-design) | the end-to-end design of each functional area |
| 4.3 | [Development and operation](#43-development-and-operation) | the application in detail: setting it up, developing, testing, releasing, operating and measuring it |
| 4.4 | [Reference](#44-reference) | reference: every current value |

## I need to

| task | read |
| --- | --- |
| set up a development machine | [4.3.1 Setup](4.3.1-setup.md) |
| build a production or rehearsal host | [4.3.4 Building a host](4.3.4-production-environment.md#building-a-host) |
| run it locally | [4.3.2 Development](4.3.2-development.md) |
| test, release or roll back | [4.3.3 Testing, CI & Release](4.3.3-testing-ci-and-release.md) |
| operate production | [4.3.4 Production Environment](4.3.4-production-environment.md) |
| raise, plan or ship a change | [1.2 The Change Lifecycle](https://github.com/delphside/programme/blob/main/docs/1.2-change-lifecycle.md), and the one-page rules in [`CLAUDE.md`](../CLAUDE.md) |
| find a script | [4.3.0 Tools](4.3.0-tools.md) for the application's, [1.1 Programme tooling](https://github.com/delphside/programme/blob/main/docs/1.1-programme-tooling.md) for the programme's |
| find where a fact lives, before writing it | [4.1.6 Document map](4.1.6-document-map.md) |
| write or change a document | [1.5 Writing documents](https://github.com/delphside/programme/blob/main/docs/1.5-writing-documents.md) |
| see what is in flight | [4.1.5 Work in progress](4.1.5-work-in-progress.md) |

**Two rules for every document**: one fact has one home, and every other
mention links to it; and a numbered document says what is true now, with the
history in the issue or the commit.

## 4.1 Overview

- [4.1.0 Rules](4.1.0-rules.md) — the decisions about how the service behaves, cited by id from tests and commits
- [4.1.1 Architecture](4.1.1-architecture.md) — system overview, deployment topology, guiding principles and roles
- [4.1.2 Components and Interactions](4.1.2-components-and-interactions.md) — component diagram, move/turn sequence diagrams
- [4.1.3 Technology Decisions](4.1.3-technology-decisions.md) — why Axum/SQLite/Dioxus/etc.
- [4.1.4 Roadmap](4.1.4-roadmap.md) — CLI prototype → UI direction → MVP → v1 → Later
- [4.1.5 Work in progress](4.1.5-work-in-progress.md) — what is in flight, drawn from the issues and regenerated, never typed
- [4.1.6 Document map](4.1.6-document-map.md) — every heading in `docs/`, generated, for finding where a fact belongs

## 4.2 Functional design

- [4.2.1 Rules Engine](4.2.1-rules-engine.md)
- [4.2.2 Rules Engine Implementation](4.2.2-rules-engine-implementation.md)
- [4.2.3 Engine Interface](4.2.3-engine-interface.md) — the trait an engine implements, and how the server runs one
- [4.2.4 Persistence](4.2.4-persistence.md) — what is persisted and where, and how long games are kept (the tables are [4.4.2](4.4.2-database-schema.md))
- [4.2.5 Authentication](4.2.5-authentication.md) — players, sessions, passwords and email
- [4.2.6 Authentication Examples](4.2.6-authentication-examples.md) — worked request/response walkthroughs
- [4.2.7 Seats and Invitations](4.2.7-authentication-and-invitations.md) — how seats are claimed and a waiting game's roster is managed
- [4.2.8 Engine Performance](4.2.8-engine-performance.md) — what the engine's search costs, and where in a game the work falls

## 4.3 Development and operation

- [4.3.0 Tools](4.3.0-tools.md) — what the owner runs by task, and every script that acts on the application
- [4.3.1 Setup](4.3.1-setup.md) — one-time: the development machine, and troubleshooting its build
- [4.3.2 Development](4.3.2-development.md) — running services locally, building, resetting local state
- [4.3.3 Testing, CI & Release](4.3.3-testing-ci-and-release.md) — `cargo test`, GitHub Actions CI, the local preview environment, the end-to-end release runbook, and how `deploy.sh` ships an image
- [4.3.4 Production Environment & Operations](4.3.4-production-environment.md) — building a host, and the running system: container topology, secrets, admin CLI, inspecting the database, logging, backups, wiping production
- [4.3.5 Word Lists & Dictionaries](4.3.5-word-lists-and-dictionaries.md) — how a published word list becomes the trie the engine searches: sourcing, normalising, generating the denylist and greylist, and the runbooks for changing either
- [4.3.10 Benchmarking](4.3.10-benchmarking.md) — measuring the engine's performance, and reading a run

## 4.4 Reference

- [4.4.1 Configuration](4.4.1-configuration.md) — environments, environment variables, versioning scheme
- [4.4.2 Database Schema](4.4.2-database-schema.md)
- [4.4.3 API Schema](4.4.3-api-schema.md) — every HTTP/WebSocket endpoint and DTO
- [4.4.4 snapshot_json Schema](4.4.4-snapshot-json-schema.md) — the authoritative game-state JSON blob's shape
- [4.4.5 Data Dictionary](4.4.5-data-dictionary.md) — where each game field lives across snapshot/DB/DTO, and its kind
- [4.4.6 Client-Local Storage](4.4.6-client-local-storage.md) — StoredAuth / chat watermarks kept on the device
- [4.4.7 Log Events](4.4.7-log-events.md) — every event the server writes, the twenty-five field names the whole log uses, and the schema a test compares the code against

## The programme's documents

The processes, the tooling and Tile Lite Elite's records are in the
[programme repository](https://github.com/delphside/programme), which is also
the `programme/` folder of this one:

- [1.0 Programme](https://github.com/delphside/programme/blob/main/docs/1.0-programme.md) — how the work is organised: who decides, the workstreams, how a change is made, and where things are recorded
- [1.1 Programme tooling](https://github.com/delphside/programme/blob/main/docs/1.1-programme-tooling.md) — the two kinds of tooling, and every script that acts on the programme's records
- [1.2 The Change Lifecycle](https://github.com/delphside/programme/blob/main/docs/1.2-change-lifecycle.md) — from an issue raised to production: triage, projects, branches, releases and deliveries, and the rules that govern each. Its sibling [4.3.3](4.3.3-testing-ci-and-release.md) holds the machinery those rules run on
- [1.3 Workstreams](https://github.com/delphside/programme/blob/main/docs/1.3-workstreams.md) — programme and application, and the generic workstreams: what each owns, and the boundaries between them
- [1.4 Programme activities](https://github.com/delphside/programme/blob/main/docs/1.4-programme-activities.md) — the recurring activities, their cadence and who does them
- [1.5 Writing documents](https://github.com/delphside/programme/blob/main/docs/1.5-writing-documents.md) — what each document holds, and how it is written
- [1.6 GitHub Project Board](https://github.com/delphside/programme/blob/main/docs/1.6-github-project-board.md) — the issue types, fields, board and accounts in GitHub, and the strings the tooling reads from them
- [1.7 Roles and responsibilities](https://github.com/delphside/programme/blob/main/docs/1.7-roles-and-responsibilities.md) — each role's purpose, decisions and reading list, and who decides what
- [3.1.1 Delivery log](https://github.com/delphside/programme/blob/main/applications/tile-lite-elite/3.1.1-delivery-log.md) — one row per delivery: what changed in production and when. Starts at #174; earlier deliveries are recoverable from the `prod-*` tags.
- [3.1.2 Artefacts](https://github.com/delphside/programme/blob/main/applications/tile-lite-elite/3.1.2-artefacts.md) — the register of things under change control that leave no trace in git: host files and cloud resources. Also the answer to *what else was on that box?*
- [3.1.3 Capacity plan](https://github.com/delphside/programme/tree/main/applications/tile-lite-elite/3.1.3-capacity-plan), [3.1.4 Workstreams](https://github.com/delphside/programme/blob/main/applications/tile-lite-elite/3.1.4-workstreams.md) and [3.1.5 Roles](https://github.com/delphside/programme/blob/main/applications/tile-lite-elite/3.1.5-roles.md) — this application's capacity plans, its eleven workstreams, and who holds each role here
- [3.1.7 Change documents](https://github.com/delphside/programme/tree/main/applications/tile-lite-elite/3.1.7-changes) — the design and test documents for each change, kept after it ships
