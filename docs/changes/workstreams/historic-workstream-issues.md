# Historic workstream issues

The ten GitHub issues that used to carry the workstreams and the programme
index, **deleted 2026-09-10**. Their bodies are kept here and nowhere else.

**Why they went.** A workstream is defined by
[3.7](../../3.7-workstreams.md) and by the `Workstream` field, and these issues
held a second copy of the same thing. Owner, 2026-09-10: *"the workstreams are
defined by the docs and the issue field. The workstream issues are historic and
should no longer be used."*

**Why this file exists rather than nothing.** The decision on 2026-09-02 went
the other way, and `docs/4.8` recorded two reasons. One of them was wrong: it
counted **101 citations** across `docs/` and `CLAUDE.md`, but most were markdown
anchors — `3.3-testing-ci-and-release.md#211-rolling-back` is a link to a
section, not to issue #211. Re-measured on 2026-09-10, excluding those, the real
figure was **42**, and 22 of them were in `3.7` and have been rewritten to name
the workstream instead.

The other reason was right. These bodies hold **35,128 characters**, and only
the workstreams' boundaries were carried into `3.7` by #232 — the argued
reasoning was not. That is what this file preserves, so the deletion costs
nothing that was not already a duplicate.

<!-- markdownlint-disable MD001 MD024 MD036 -->

**Not a live document.** Nothing here is current, nothing links to it, and it is
not maintained. Read `3.7` for what a workstream is and owns.

| was | is |
| --- | --- |
| #188 | process definition |
| #189 | operations & infrastructure |
| #203 | the programme index |
| #204 | delivery tooling |
| #208 | application & game architecture |
| #209 | client UI |
| #210 | authentication & authorisation |
| #211 | client management |
| #212 | capacity planning |
| #213 | engine player |

---

## #188 Process Definition Workstream

**The process capability**, and the parent of every project that changes how we
work: how a change is raised, classified, agreed, built, tested, delivered and
reviewed, and the documents that state it.

#### What this workstream owns, and how it delivers

*Owner, 2026-08-24. Written on #179 and moved here, because #179 is a project
with an end and this is a standing policy that must outlive it.*

It owns the **rules, the documents that state them, and the tooling that manages
the process** — `docs.yml`'s review workflow, `actions.py`, `pipeline.py`,
`roadmap.sh`, `status.sh`.

**Narrowed 2026-08-24.** This said *"documentation and tooling related to
processes… prod and non-prod tooling both"*, which was written before #204
existed and took the delivery machinery. The split is by **what the tooling is
for**: tooling that *manages* the process is here, tooling that *delivers* a
change — `deploy.sh`, `deploy-preview.sh`, CI, the build model, the release
gates — is #204. Both names stay accurate that way, and neither workstream ends
up owning a thing its title does not describe.

| | |
| --- | --- |
| documents | read from the **`origin/main`** branch |
| scripts | run from the **local `main`** branch in dev |
| the delivery process | updating `main` and pushing to `origin`. That is the whole of it |

**There is a general pre-approval** to make ad-hoc changes to the process
following discussion, without requiring a project, a branch or a separate
review. Pre-approved changes are made directly in `main` and pushed. **If issues
have been raised, they are closed manually** — nothing else will close them.

**Projects are still possible here**, where significant changes need design and
testing documentation.

**A branch is only needed if the changes cannot be put into `main` until the
work is completed** — which would be if the old versions of the documents and
tooling are required in the interim.

##### Risk does not change the route, it changes what is owed

*Owner, 2026-08-24: "I think it covers prod and non-prod tooling. There is
clearly different risk for changes to `deploy.sh`, so it is more likely to
require a project."*

The pre-approval settles **authorisation** — no separate review. It says nothing
about **rigour**. A change to `deploy.sh` is pre-approved and still likely to
need a design and a test approach agreed before it is built, because a defect
there breaks a deploy rather than a sentence.

The two obligations are independent, and conflating them is what made the old
`lane` idea unusable.

A **workstream** is unbounded — it has no end date and no scope to complete.
Projects under it do. This one exists because process is something we maintain
rather than something we finish, and because `docs/3.x` is meant to be portable
to a second project, which means the rule and this project's answer to it have to
stay separable.

Created 2026-08-21, splitting what #179 had been doing under one number: #179 has
a fixed scope and an end, which by our own definition of the levels makes it a
**project**. This is the level above it.

##### The boundary with #189, and the cut inside this one

*Owner, 2026-08-24: "The clear division would be up to release, and then
production operations after release."* — and *"separating the process from the
tooling also works. That is right."*

**Two cuts, and they are compatible.**

| cut | separates |
| --- | --- |
| **lifecycle stage** | this workstream from #189. Everything up to and including the release is here — how a change is raised, agreed, built, tested and **deployed**. After it is live, it is operations |
| **definition from tooling** | the projects *inside* here. Writing the process down is one project; building the tooling that implements it is another |

So `deploy.sh`, `deploy-preview.sh`, the build model and the release gates are
**process**, not operations — a deploy *is* the release. #189 said it owned
"deploys"; that was corrected on 2026-08-24.

And #179 (the process documents) does not swallow the deployment tooling. They
are separate projects under the same workstream, because one produces documents
and the other produces scripts, and they are agreed, tested and delivered
differently.

#### Projects

| project | what it delivers |
| --- | --- |
| #179 | the change process agreed and written into `docs/3.x` |

#### Open actions

*Read by `./scripts/actions.py`: one `- [ ]` per action, prefixed `(Steve)` or
`(Claude)`.*

---

## #189 Operations & Infrastructure Workstream

**The production operations capability**, and the parent of every project that
changes how the live service is run, watched and recovered — the host,
monitoring, alerting, logging, backups and disaster recovery.

##### The boundary with #188

*Owner, 2026-08-24: "The clear division would be up to release, and then
production operations after release."*

| | |
| --- | --- |
| **#188 process definition** | the rules, and the documents that state them |
| **#204 delivery tooling** | the machinery that carries a change to a running environment — `deploy.sh`, `deploy-preview.sh`, the build model, CI, the release gates |
| **#189 operations** (this one) | everything after the release — the service is live, and this is keeping it running, watched and recoverable |

##### Infrastructure is here too, until it earns its own workstream

Owner, 2026-08-24: *"the infrastructure may cross over with operations. But it needs to be covered."*

**The classical split is real**: infrastructure is *what exists* — the instance, the network, the storage, the environments — and operations is *keeping it healthy*. They are kept together here because separating them now would create a boundary with almost nothing on one side, and the cost of that is issues falling between two owners rather than sitting in one.

So this workstream owns both, and the list is written out so nothing is homeless:

| | |
| --- | --- |
| the OCI instance, its shape and its Always Free limits | |
| the Docker stack — `docker-compose.yml`, `docker-compose.preview.yml`, volumes | |
| **networking, layers 1–6** — TLS, certificates, the reverse proxy, ports, DNS | |
| the preview and rehearsal environments, and their exposure | #40 lives here |
| the host's own packages and users | `sqlite3`, `systemd-journal` membership |
| monitoring, alerting, logging, backups, disaster recovery | |

**When to split it**: when infrastructure projects start waiting on operations ones, or a project needs both and cannot say which it is. Not before — a boundary drawn early is a boundary defended rather than used.

**Networking, layers 1–6.** TLS and certificates, the reverse proxy, ports, DNS
— `Caddyfile`, `Caddyfile.preview`, the `caddy-data` / `caddy-config` volumes.
Owner, 2026-08-24: *"there is a technical side to do with the network
configuration, layers 1–6."* **Layer 7 — the application's own message flows —
is not here**: the WebSocket carrying game state belongs to #208, and
authentication's flows to #210. The test is whether the change is about *that a
connection exists and is private*, or about *what is said over it*.

**All three environments, not just production.** Owner, 2026-08-24: *"Delivery
tooling and operations should cover prod and non-prod, as we want to keep these
similar."* Preview and rehearsal are run and watched here too. Splitting their
ownership from production's is the first thing that would make them drift.

So the `prod-tooling` / `non-prod-tooling` labels do **not** divide ownership.
They say how much risk a change carries and what it therefore owes. #40
(rehearsal holding production user data on a public IP) is operations.

**This used to say it owned "deploys". It does not.** A deploy *is* the release,
so deployment tooling sits on the process side of the line. Corrected 2026-08-24.

The test is *what is it for*, not *how it shipped*: #174's logging shipped as a
release and is operational work, because what it changes is how the running
service is watched.

A **workstream** is unbounded: no end date, no scope to complete. Projects under
it do end. This is the second workstream to be made explicit, after #188.

#### Projects

| project | what it delivers |
| --- | --- |
| #174 | logs that survive a deploy, and a database copy that survives the VM |

#### Open actions

*Read by `./scripts/actions.py`: one `- [ ]` per action, prefixed `(Steve)` or
`(Claude)`.*

Typed by Claude

---

## #203 Programme index — start here

**Start here.** This is the index to the programme's workstreams. Everything else is reachable from one of them without knowing a number.

#### The workstreams

**Nine workstreams**, in two groups. Owner, 2026-08-24: *"it also helps if they map to artefacts"* — each names the files it owns, which is what makes allocating an issue checkable rather than a matter of taste.

**The product** — what the service is:

| | what it owns |
| --- | --- |
| **#208 · Game lifecycle** | creating a game, adding players, playing, finishing — the rules, the engine interface, a game's life on the server |
| **#213 · Engine player** | the bot as a participant: how it chooses a move, how strong, how fast |
| **#209 · Client UI** | what a player sees and touches |
| **#211 · Client management** | getting a client into a player's hands and keeping it current |
| **#210 · Authentication and authorisation** | accounts and people: who someone is and what they may do |
| **#212 · Capacity planning** | whether the service still fits — memory, storage, growth over time |

**What keeps it running** — the supporting capabilities:

| | what it owns | ends at |
| --- | --- | --- |
| **#188 · Process definition** | the rules of how we work, the documents that state them, and the tooling that manages the process | it says what should happen |
| **#204 · Delivery tooling** | the machinery that carries a change to a running environment | the release |
| **#189 · Operations** | the service once it is live — the host, monitoring, backups | never |

**Open each one to find its projects.** GitHub renders the sub-issue list live, so it is never out of date. This index lists only the workstreams — the layer that changes least — and derives nothing else.

**The last two of the supporting three cover every environment**, preview and rehearsal as well as production. They are kept deliberately alike, and splitting their ownership is the first thing that would make them drift.

**`prod-tooling` and `non-prod-tooling` do not divide ownership.** They say how much risk a change carries and what it therefore owes. Both appear under both.

**Open each one to find its projects.** GitHub renders the sub-issue list live, so it is never out of date. This index deliberately lists only the workstreams — the layer that changes least — and derives nothing else.

#### The levels, and how to tell which you are looking at

| level | how to recognise it | ends? |
| --- | --- | --- |
| **workstream** | listed above; it is a parent with nothing above it | never — it is a capability we maintain |
| **project** | a sub-issue of a workstream. Carries requirements, a design, impacted artefacts, dependencies, a test approach, deliveries | yes |
| **requirement** | an ordinary issue. Raised in five seconds, folded into a project when one takes it | closed, or folded |
| **delivery** | not an issue — a *part* of a project that reaches production as one act. Recorded in `docs/4.9-delivery-log.md` | — |

A requirement that is not under a workstream is **backlog**: raised and not yet grouped. That is most of the open list, and it is the normal state.

#### When you have a number and want the context

- **GitHub** shows the parent on a sub-issue and the children on a parent, both live.
- **`./scripts/actions.py`** — everything outstanding, in workstream order, with the level derived from the sub-issue graph rather than remembered.
- **`./scripts/roadmap.sh`** — the same backlog grouped by release instead of by workstream.
- **`./scripts/inbox.sh`** — what has changed on GitHub recently.

#### Where the rules are

`docs/3.6-change-lifecycle.md` — the flow, the levels, triage, and what a project's issue carries. `docs/3.3-testing-ci-and-release.md` — the machinery underneath it.

---

*Pinned so the Issues tab opens on it. Kept short on purpose: an index that repeats what GitHub already renders is an index that goes stale.*

Typed by Claude

---

## #204 Delivery Tooling Workstream

**The delivery tooling capability**, and the parent of every project that changes the machinery carrying a change from a commit to a running environment — building, testing, gating and deploying.

A **workstream** is unbounded: no end date, no scope to complete. Projects under it do end.

Created 2026-08-24. Owner: *"We now have three areas: process definition, delivery tooling, operations."*

#### The three areas, and where the lines fall

| | owns | ends at |
| --- | --- | --- |
| **#188 · process definition** | the rules, and the documents that state them — how a change is raised, classified, agreed, reviewed | it says what should happen |
| **this one · delivery tooling** | the machinery that makes it happen — `deploy.sh`, `deploy-preview.sh`, the build model, CI, the release gates, test tooling | the release |
| **#189 · production operations** | the service once it is live — the host, monitoring, alerting, logging, backups, disaster recovery | never; it is a running concern |

**Two cuts produced this.** *"The clear division would be up to release, and then production operations after release"* separates operations from the rest. *"Separating the process from the tooling also works"* separates the first two. A deploy **is** the release, so deployment sits on this side of the operations line, not #189's — which is why #189 no longer claims "deploys".

##### Both cover production and non-production

*Owner, 2026-08-24: "Delivery tooling and operations should cover prod and non-prod, as we want to keep these similar."*

Neither of the last two areas is a production-only concern. Delivery tooling deploys to **preview, rehearsal and production**; operations runs and watches all three. The environments are deliberately kept alike, and splitting their ownership would be the first thing to make them drift — which is exactly how `deploy.sh` and `deploy-preview.sh` came to be two implementations of one principle (#134).

**A consequence worth noticing.** The `prod-tooling` / `non-prod-tooling` labels look like they divide ownership. They do not, and must not be read that way. They say how much **risk** a change carries and therefore what it owes — a design, a test approach, a rehearsal — not which workstream owns it. Both labels appear under both of these workstreams.

So #40 (rehearsal holding production user data on a public IP) is operations, despite being a non-production environment. It is about how a running environment is exposed.

**The test is what a change is *for*, not how it shipped.** #174's logging shipped as a release and is operations work, because what it changes is how the running service is watched.

#### Why this is its own workstream rather than a project under #188

The process documents and the tooling that implements them are agreed, tested and delivered differently. A document is discussed and merged; `deploy.sh` earns a design, a test approach, and a rehearsal. Keeping them apart stops the heavier obligation being applied to a paragraph, or the lighter one to a release gate.

It also matches how they fail. A wrong sentence is read and corrected. A wrong gate ships something untested, or refuses to ship something that is fine — which is #194, live today.

#### Projects

*To be assigned in the triage pass. The candidates, from the sequencing agreed on 2026-08-23:*

| likely project | requirements |
| --- | --- |
| deploy.sh's issue bookkeeping | #194, #195, #150 |
| one deployment path, three environments, one build | #134, #193 |
| release branch assembly | #135, #144 |
| test tooling cleans up after itself | #148, #128 |

Nothing is assigned yet — grouping is a triage decision, and this issue exists so the grouping has somewhere to land.

Typed by Claude

---

## #208 Application & Game Architecture Workstream

**Application architecture** — renamed 2026-08-28 from *game lifecycle and client-server architecture*, which described the two things it started as rather than the one thing it is. Owner: *"then it naturally owns the data models, message flows, and interfaces to clients."*

| it owns | which here means |
| --- | --- |
| **the data models** | what a game *is* — the snapshot, the DTOs, the schema the two sides agree on |
| **the message flows** | what is said, when, to whom, and what happens if it arrives late or twice |
| **the interfaces to clients** | `crates/api` and the version pair that says whether the two sides still agree |

**The game lifecycle capability** is what those exist for: creating a game, adding players, playing it, and finishing it — and everything that happens to a game after that.

**And the client-server architecture that carries it.** Owner, 2026-08-24: *"game lifecycle should go with client-server architecture — asynchronous interactions between client and server."* The two are one capability because the hard part of a game's life is that **two sides have to agree about it while neither is waiting**: a move made in one place has to reach the other, out of order, after a disconnection, or to a client that was closed at the time. Splitting them would put the state in one workstream and the means of agreeing about it in another.

A **workstream** is unbounded: no end date, no scope to complete. Projects under it do end.

Created 2026-08-24, when triaging the backlog found that the three existing workstreams — process definition (#188), delivery tooling (#204) and operations (#189) — covered the supporting capabilities and not the product.

#### The artefacts it owns

Owner, 2026-08-24: *"it also helps if they map to artefacts."* That is what makes allocation checkable rather than a matter of taste — an issue belongs here if it changes one of these.

| artefact | |
| --- | --- |
| `crates/engine-core`, `crates/rules-shared` | the rules and the engine |
| `crates/server-game/src/app/` — `games.rs`, `roster.rs`, `events.rs`, `sweeps.rs`, `ratings.rs` | a game's life on the server |
| `docs/2.1`, `2.2`, `2.3` | the rules engine, its implementation, and the engine interface |
| `docs/4.4-snapshot-json-schema.md` | what a game's state is |
| `crates/server-game/src/app/events.rs`, `game_state.rs`, `app.rs` | the WebSocket transport, broadcasts, and reconnection |
| `crates/api` and `docs/4.3-api-schema.md` | the shapes the two sides exchange, and the version pair that says whether they still agree |

##### Networking: layer 7 here, layers 1–6 in operations

Owner, 2026-08-24: *"the actual message flows (layer 7) is part of the functionality of the application and belongs with game lifecycle (mainly). But there is a technical side to do with the network configuration, layers 1–6."*

| | | owner |
| --- | --- | --- |
| **layer 7** | what is said, when, to whom, and what happens if it arrives late or twice — the WebSocket message flows, broadcasts, reconnection and re-fetch, the DTOs | **here** |
| **layers 1–6** | that a connection exists and is private — TLS, certificates, the reverse proxy, ports, DNS. `Caddyfile`, `caddy-data` / `caddy-config`, `docs/3.4` | **operations (#189)** |

That is a sharper test than "which crate is it in", because both sides touch the same running system. **The WebSocket is here because it carries game state; the transport it runs over is not.** A change to what a `GameUpdate` contains is this workstream. A change to how the certificate is obtained is not, and neither is a port mapping.

*"Mainly"* is doing real work in that sentence: authentication also has layer-7 message flows, and they belong to #210. The layer is what separates application from infrastructure — it does not, on its own, say **which** application concern.

###### The general messaging mechanism is owned here, and shared

Owner, 2026-08-28: *"we need a workstream to own the general messaging mechanism, which is shared between the functions. Game defines most of the actual messages and data types, so it best fits there."*

| | owner |
| --- | --- |
| **the mechanism** — the socket, framing, broadcast, reconnection, ordering, the version pair that says whether two sides still agree | **here**, and it is shared |
| **the messages** each function sends through it | **that function** — an authentication flow's messages are #210's, a client-update signal's are #211's |

**Ownership follows where the content is defined, not where the plumbing runs.** By the test in `docs/3.6` the mechanism *could* be a workstream of its own: it is self-contained and has mechanisms of its own. It is not one, because the game defines most of what flows through it — and separating the mechanism from the messages that dominate it would put the DTOs in one workstream and the thing that carries them in another. That is the same objection that joined game lifecycle to client-server architecture in the first place.

**What that means in practice**: a change to the *shape* of what is delivered — a new common header field, a change to how messages are dispatched, a DTO convention — is this workstream, whoever it is delivered for. A change to *what* is said is the workstream of whatever is saying it. A change to *whether the connection exists at all* is operations.

##### The line with the engine player (#213): validation and scoring

Owner, 2026-08-24: *"everything up to validation and scoring is owned by #208. This includes data derived from static data which can be used by an engine, such as the trie dictionary structure. #213 builds a search algorithm on top."*

| | | owner |
| --- | --- | --- |
| is this a word; is this placement legal; what does it score | `board.rs`, `model.rs`, `score.rs`, `format.rs` | **here** |
| **structures derived from static data** — the tiered/trie dictionary, cross-check caches | `dictionary.rs`, `cache.rs` | **here** |
| choosing which legal move to play, and how fast | `crates/engine-core`, move search | **#213** |

**The derived structures are here, not there**, which is the part that is easy to get wrong. A trie built from a word list is not part of the engine — it is a faster way of answering *is this a word*, which is validation. The engine is a **consumer** of it, and so is the client, which does its own lookups for the move preview.

##### The line with authentication (#210): invitation state versus accepting one

Owner, 2026-08-24: *"the invitation state is owned by the game, some mechanics about accepting an email invitation belongs to #210, since it involves registering or authenticating."*

**The state is here.** Who has been invited to a game, whether they accepted, declined, or were re-invited, and what that means for the game's roster — that is a game's life.

**Accepting an emailed invitation is #210's**, because following the link means registering or authenticating first. The identity has to exist before the seat can be filled.

`invitations.rs` and `docs/2.7` therefore have two owners by design rather than by accident.

#### Projects

*To be raised as the backlog is triaged.*

Typed by Claude

---

## #209 Client UI Workstream

**The client UI capability**: what a player sees and touches — the board, the rack, the controls, the lists, and how the client keeps itself current.

A **workstream** is unbounded: no end date, no scope to complete. Projects under it do end.

Created 2026-08-24, alongside game lifecycle, authentication and capacity planning, when triaging the backlog found the existing three workstreams covered the supporting capabilities and not the product.

#### The artefacts it owns

| artefact | |
| --- | --- |
| `crates/ui` | the whole client |
| `docs/4.6-client-local-storage.md` | what the client keeps |
| `docs/4.3-api-schema.md`'s client-facing shapes | what the UI is rendering |

##### This workstream overlaps everything, and that is what it is

Owner, 2026-08-24: *"there will be some overlap between #209 and other functionality since #209 is a layer providing access to other functionality."*

**The client UI is a layer over every other capability**, so a requirement here almost always touches one of them too. That is not a boundary failure and §2.11's test does not apply to it: a game's rules, an account's state and a client's version all have to be *shown*, and showing them is one capability with one set of conventions.

**The test is which half of the pair the change is.** A move is legal or not — #208; how it is displayed — here. A client is out of date — #211; where that is said on screen — here. Owner: *"#211 tells the client the version, #209 tells the client where to display it."*

When a requirement genuinely needs both, it is a project with two workstreams' artefacts in it, not an argument about which one owns it.

**The boundary with client management (#211)**: the code often sits in the same crate, so the test is what the change is *for*. A control that reads better, a list that shows the right thing, a board that clears when it should — UI. A client that notices a newer version exists and reloads — management. They fail differently: a UI defect is visible, a distribution defect means somebody is looking at last month's client and nothing says so.

#### Projects

*To be raised as the backlog is triaged.*

Typed by Claude

---

## #210 Authentication & Authorisation Workstream

**The authentication and authorisation capability**: accounts and people — who someone is, what they may do, and how they stop being able to do it.

A **workstream** is unbounded: no end date, no scope to complete. Projects under it do end.

Created 2026-08-24. Owner: *"Authentication and Authorisation = accounts and people."*

#### The artefacts it owns

| artefact | |
| --- | --- |
| `crates/server-game/src/app/` — `auth.rs`, `admin.rs`, `invitations.rs` | registering, signing in, sessions, invitations, administrative action on an account |
| `crates/admin-cli` | what an operator can do to an account |
| `docs/2.5`, `2.6`, `2.7` | authentication, its worked examples, and authentication with invitations |
| the rate limits on the open routes | who may knock, and how often |

##### Invitations: the state is the game's, accepting one is here

Owner, 2026-08-24: *"the invitation state is owned by the game, some mechanics about accepting an email invitation belongs to #210, since it involves registering or authenticating."*

| | owner |
| --- | --- |
| who has been invited, whether they accepted or declined, what that does to the roster | **#208** — it is a game's life |
| **following an emailed invitation**: registering or signing in first, then binding that identity to the seat | **here** |

The identity has to exist before the seat can be filled, which is why the link lands here and the state does not. `invitations.rs` and `docs/2.7` therefore have two owners by design rather than by accident.

#### Projects

*To be raised as the backlog is triaged.*

Typed by Claude

---

## #211 Client Management Workstream

**The client management capability**: getting a client into a player's hands and keeping it current — builds, distribution, versions, and how a running client learns that a newer one exists.

A **workstream** is unbounded: no end date, no scope to complete. Projects under it do end.

Created 2026-08-24. It is deliberately **separate from client UI (#209)**: what a player sees is one capability, how they come to be running this version of it is another. They fail differently — a UI defect is visible, a distribution defect means somebody is looking at last month's client and nothing says so.

#### The artefacts it owns

| artefact | |
| --- | --- |
| the desktop build and its distribution | how a client reaches a player at all |
| version skew handling in `crates/ui` | what a client does when the server has moved on |
| `/version.txt` and the bundle hash | how a running client notices a new one |
| `docs/4.3-api-schema.md`'s version pair | what "too old" means |

**The boundary with delivery tooling (#204)**: #204 gets a build to an *environment*; this gets it to a *person*. A web client is delivered by the deploy and then has to be picked up by a browser that may not reload for days — that second half is here.

**The boundary with client UI (#209)**: the code often sits in the same crate. The test is what the change is *for* — a control that reads better is UI; a client that reloads when it should is management.

#### Projects

*To be raised as the backlog is triaged.*

Typed by Claude

---

## #212 Capacity Planning Workstream

**The capacity planning capability**: whether the service still fits — memory, storage, startup, growth over time, and what happens as data accumulates.

A **workstream** is unbounded: no end date, no scope to complete. Projects under it do end.

Created 2026-08-24.

#### The artefacts it owns

| artefact | |
| --- | --- |
| `docs/2.4-persistence.md` | what is stored and how much of it |
| `crates/server-game/src/app/sweeps.rs` | what is removed, and when |
| the in-memory game model's growth | startup time and resident size |
| the 1 GB VM's headroom, and the 20 GB Always Free allowance | the ceiling everything is measured against |

**The boundary with operations (#189)**: operations *notices* — alarms, monitoring, disk. Capacity planning *changes what is consumed*, or decides what is acceptable. An alarm on the disk filling is operations; a design that stops it filling is here.

##### Why it is separate from operations, when it could be part of it

Owner, 2026-08-24: *"#212 could be a function of #189. It is a well defined function and it needs its own process."*

**It could sit inside operations and infrastructure**, and nothing about the artefacts forbids it. It is separate because it is a **well-defined function with a process of its own**: measure what is consumed, compare it against the ceiling, decide whether the trend is acceptable, and act before it is not. That recurs on its own schedule and produces its own kind of answer.

Folded into #189 it would be one concern among monitoring, backups, TLS and the host — and the first thing to be dropped, because nothing is broken today.

**It is also never finished.** Growth is continuous, and *does this still fit* changes without anybody changing the code, which is the definition of a workstream rather than a project.

**The boundary with #189, sharpened 2026-08-24.** Owner, allocating *notice unusual growth in registrations* (#89) here rather than to operations: *"capacity planning — which looks across all application and technical metrics."*

| | |
| --- | --- |
| **operations (#189)** | is it healthy **now**? An alarm fires, someone acts today. Disk full, service down, backup missing |
| **capacity planning (here)** | is the **trend** acceptable? Looking across every metric there is — application and technical alike — and deciding whether what is coming still fits |

So an alarm on the disk filling is operations; noticing that registrations are growing in a way nobody expected is here, even though both are *noticing*. The difference is whether the answer is *act now* or *decide whether this is sustainable*.

**And it explains the two that look like test tooling.** Stress testing (#91) is here rather than with delivery tooling, because its question is *how big can the data get and where does the service break* — a capacity question that happens to need a harness. Owner: *"independent of other test tooling so no conflict."*

#### Projects

*To be raised as the backlog is triaged.*

Typed by Claude

---

## #213 Engine Player Workstream

**The engine player capability**: the bot as a participant — how it chooses a move, how strong it is, how fast, and how it is driven.

A **workstream** is unbounded: no end date, no scope to complete. Projects under it do end.

Created 2026-08-24.

#### The artefacts it owns

| artefact | |
| --- | --- |
| `crates/engine-core` | `choose_action` — the player, as distinct from the rules |
| `crates/rules-shared/src/generate.rs` | move generation — the search itself |
| `crates/server-game/src/app.rs` — `run_engine_turns` | how and when the engine is asked to move |
| `crates/server-game/examples/engine_timing_bench.rs` and its CSV | how strength and speed are measured over time |

#### The boundary with game lifecycle (#208)

Owner, 2026-08-24: *"everything up to validation and scoring is owned by #208… #213 builds a search algorithm on top."*

**Everything up to and including validation and scoring is #208** — is this a word, is this placement legal, what does it score. **And so are the structures derived from static data**: the tiered/trie dictionary and the cross-check caches. A trie built from a word list is a faster way of answering *is this a word*; it is validation, not search. This workstream is a **consumer** of it, and so is the client.

**What is here is the algorithm on top**: which of the legal moves to play, how the search is ordered and pruned, how long it takes, and how good the result is.

**The standing goal is stronger bots**, which is why the timing benchmark exists and is kept: a change that makes the engine faster is only interesting because it buys search. A change that makes it *play differently* is a new bot with a new name, not a change to Greedy Bot — the owner's boundary, 2026-07-30.

#### This boundary anticipates the architecture, and does not describe it yet

Owner, 2026-08-24: *"when I wrote the original version, in `old-crates/first-try`, it was a single application with client, game management and engine player all tightly bound together in a single executable, all actions triggered synchronously by actions on the client. In the current version we have split the client out and created an asynchronous interaction with the game manager. But the engine player is still tightly bound. So the distinction today is not as clear as it will be."*

| | then — `first-try` | now | where it is going |
| --- | --- | --- | --- |
| **client** | in the executable, synchronous | **split out**, asynchronous | — |
| **game manager** | in the executable | the server | — |
| **engine player** | in the executable | **still tightly bound** — `run_engine_turns` computes replies inside the request that triggered them | a client like any other |

**So this workstream is drawn where the seam will be, not where it is.** An engine change today lands in the same code as a game-manager change, and some requirements will honestly belong to both this and #208 until the seam exists.

**The work that makes it real** is #71 — *one game model: version, seats, DTOs and **the engine as a client*** — and #10, the bot client harness that runs an engine over the public API rather than in-process. Once those land, the boundary stops being a statement of intent and starts being a fact about the code.

**Recording it because the alternative is worse.** Drawing the workstream only when the code allows it would leave every engine requirement homeless in the meantime, and would lose the reason the separation is wanted at all. See §2.11: *where the shape was chosen because of other work, say which work* — so that if #71 is dropped, this shape becomes reviewable rather than mysterious.

#### Projects

*To be raised as the backlog is triaged.*

Typed by Claude
