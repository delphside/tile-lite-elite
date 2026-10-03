<!-- markdownlint-disable-file MD013 -->
# Delivery flows: what is checked, when, and what it is for

For #383. Owner, 2026-09-16:

> I would like to see flow charts with information flows, checks and gates detailed. What conditions are we checking when? That would have a table of checks and get methods. **This becomes the interface between Claude and Steve for tooling changes.**

So this document is the contract. A tooling change that alters a gate, a check, or what one reads should show up here as a diff, and a proposal expressible here is one that has been thought through.

## How to read it

**A gate refuses and work stops. A check reports and a person decides.** That is CLAUDE.md's distinction and it is drawn in the diagrams: gates are the diamond shapes, checks are the rectangles hanging off the side.

**Purpose before criteria.** Owner, 2026-09-16: *"The requirements should specify what each action, check, decision or gate is trying to achieve and only then the criteria used."* Every row in the tables below names what it is for first. Where a criterion is wider than its purpose — checking on rehearsal what is really a statement about a mechanism — that is a defect, and #252 is a live instance.

**Latency is a property of the consumer.**

| class | tolerance | when the picture is stale |
| --- | --- | --- |
| **gate** | current, and re-read after any write | refuse |
| **verification** | minutes | warn, and print the age |
| **report** | hours | serve it, and print the age |

A stale board makes a report mildly wrong and makes a gate ship the wrong thing.

## The shapes, as examples

A delivery is `{ route, branches }`. The branches say where the change travels; an arrow is a merge into what follows.

**Examples, rather than a catalogue.** Other shapes are legitimate; these are the ones that have happened.

| route | branches | delivered by | pull request | milestone | delivery-log row |
| --- | --- | --- | --- | --- | --- |
| Repository | `None` | the push | — | `pre-approved` | — |
| Repository | `Project -> main` | the merge | one | previous semver plus a letter | one |
| Release | `Project -> main` | the release | one | semver | one |
| Release | `WP A -> main, WP B -> main` | the release | one each | one, shared | one each |
| Release | `WP A -> WP B -> main` | the release | one each | one, shared | one each |
| Release | `WP A -> Release, WP B -> Release` | the release | one each, plus the release | semver | one each |

**Every row is a delivery, and the release is part of it.** Owner, 2026-09-17:

> All of these rows are deliveries so there is no later release. For the release route this is all the changes reaching `main`, together or separately, and then being released together.

So a Release row describes the whole thing: the changes reach `main` — as one branch, as several, or built on each other — and that set is then released. One production deployment ends it.

**`Project -> main` means two different things, and the route is what separates them.** For a Repository change the merge *is* the delivery and nothing follows. For a Release change the merge is a step inside the delivery, which ends at the release. Same branches, different ending, which is why the route column comes first.

### Repository · `None`

Everything is live on push, so the gates are local. The commit is the record.

```mermaid
flowchart LR
  W[working tree] --> PC{{pre-commit}}
  PC -->|refuses| W
  PC --> M[(main)]
  M --> CI{{CI: fmt clippy test wasm docs, stamp}}
  CI --> LIVE[live on push]
  M -.-> CT[check-transitions.sh]
  M -.-> ST[status.sh / actions.py]

  classDef gate fill:#fde,stroke:#a36
  classDef check fill:#eef,stroke:#46a
  class PC,CI gate
  class CT,ST check
```

**`pre-commit` is the whole of this shape's protection**, and it carries three refusals:

| refuses | purpose |
| --- | --- |
| an image change committed on `main` | the image is what production runs, so it reaches main reviewed |
| a new artefact absent from `docs/3.0-tools.md` | a script nobody registered is a script nobody maintains |
| Rust that `rustfmt` would change | a red build and a refused release gate, moved to the cheapest moment |

It also runs `check-docs.sh` when markdown is staged, which is the one place the documents are gated rather than merely checked.

### Both routes share a branch and a pull request, and nothing after it

The two `Project -> main` shapes below use the same branch mechanics, so they are stated once here and not repeated.

```mermaid
flowchart LR
  B[(project branch)] --> CI1{{CI check + stamp, every push}}
  CI1 --> PR[pull request]
  PR --> E2E{{CI e2e, every PR}}
  PR --> REV{{owner review}}
  E2E --> MG{{merge: rebase and fast-forward}}
  REV --> MG
  MG --> M[(main)]

  classDef gate fill:#fde,stroke:#a36
  class CI1,E2E,REV,MG gate
```

**e2e runs on every pull request today, whatever it touches — #348.** For a repository change confined to documents and scripts, that is around seven minutes proving the game still works.

**After the merge the two routes have nothing in common**, which is why they are separate shapes rather than one shape with a branch in it. Owner, 2026-09-17:

> The Release route includes the change to main and the deployment. The Repository route is for docs and scripts which are delivered as soon as they hit `main`.

For a Repository change the merge **is** the delivery. For a Release change `main` is a waypoint and the change is inert there, however well tested.

### Repository · `Project -> main`

Documents and scripts. **The delivery ends at the merge** — there is nothing after it, and no deployment is involved.

```mermaid
flowchart LR
  MG{{merge}} --> M[(main)]
  M --> LIVE([live on origin/main])
  LIVE --> MS[letter milestone<br/>previous semver + a letter]
  M -.-> CT[check-transitions.sh]

  classDef gate fill:#fde,stroke:#a36
  classDef done fill:#eef3ea,stroke:#5c7a4a
  classDef check fill:#eef,stroke:#46a
  class MG gate
  class LIVE,MS done
  class CT check
```

| | |
| --- | --- |
| carries | documents and scripts |
| delivery ends | at the merge — live on `origin/main` |
| milestone | previous semver plus a letter, **at the merge**, because that is when it goes live |
| owes | a pull request and a delivery-log row; no deployment, no environments, no post-deployment check against a running service |

### Release · `Project -> main`

Anything built into the image, and anything deployed to the production host. **The delivery ends at the production deployment**, which the route includes.

```mermaid
flowchart LR
  B[(branch)] --> U[user testing<br/>preview]
  U --> T[technical testing<br/>rehearsal]
  T --> MG{{merge}} --> M[(main)]
  M --> RD[rehearsal deployment<br/>the whole release]
  RD --> DEP{{deploy.sh, 8 gates}}
  DEP --> P[production deployment]
  P --> MS[semver milestone] --> LIVE([live])
  P --> SET[settle: phases, milestones, comments]
  SET -.-> V[verify.sh]

  classDef gate fill:#fde,stroke:#a36
  classDef check fill:#eef,stroke:#46a
  classDef done fill:#eef3ea,stroke:#5c7a4a
  class MG,DEP gate
  class V check
  class LIVE,MS done
```

| | |
| --- | --- |
| carries | anything built into the image, and anything deployed to the production host |
| delivery ends | at the production deployment |
| milestone | semver, **at production**, because `main` is not live |
| owes | everything the Repository route owes, plus user testing, technical testing, two deployments, eight gates and a post-deployment check per requirement |

**Since D55 (#388) merging to `main` comes before the release, not with it.** A release-route change merges once user and technical testing pass, and `main` is the accumulating next release. The owner's reason:

> Releases are simpler if we have a next release branch that accumulates changes. Because of doc and tooling changes it is easier if that is `main`.

**What makes that safe lives in the emergency path.** `main` now carries tested-but-unshipped image changes, so an emergency release cut from `main` ships all of them. `docs/3.3` says to cut from the last released tag instead. That is a documented procedure today; #387 R2 asks for the report and R3 for the enforcement that would make it a gate.

**Documentation riding on a Release delivery is a pre-approved add-on.** Owner, 2026-09-17:

> The Release version may carry some documentation changes but these can be classed as pre-approved add-ons to the release and don't need any ceremony.

So a release that also touches documents stays one Release delivery with one semver milestone: no letter milestone, no second pull request, no delivery-log row of its own. They are on the project branch already, reviewed in the same diff, and live when the release is. **A document carried along does not make a second delivery** — which is what the *heaviest artefact* wording was reaching for, and reads better as an add-on than as a route calculation.

### Anything else spanning routes is split, not ranked

Owner, 2026-09-17:

> Different routes can be split into separate deliveries (apart from carry-on documentation changes). So a project might have script changes going first, then a configuration change in OCI, then an application change. Three deliveries by different routes.

So a project's deliveries may each take a different shape from the table above, in whatever order the work needs.

**Each delivery is a work package, and the parent carries no route.** Owner, 2026-09-17:

> So a project with Release and Other would have a sub-project work package for each delivery, so they can both be tracked. The parent project does not have route set (replacing the heaviest route rule).

The ranking was the parent's way of describing deliveries it did not itself make. Splitting removes the need: the route sits on the work package that delivers, and the parent has none to set. Every gate that asks *how does this reach users* is asking a work package, never a parent.

### Release · `WP A -> Release, WP B -> Release`

```mermaid
flowchart TD
  P1[(project A branch)] --> PRA[PR into release]
  P2[(project B branch)] --> PRB[PR into release]
  PRA --> MR1{{merge-to-release.sh}}
  PRB --> MR2{{merge-to-release.sh}}
  MR1 --> R[(release/X.Y.Z)]
  MR2 --> R
  R --> RT{{CI on the branch tip, e2e required}}
  RT --> FF{{fast-forward into main}}
  FF --> M[(main)]
  M --> DEP{{deploy.sh, 8 gates}}
  DEP --> PROD[production]

  classDef gate fill:#fde,stroke:#a36
  class MR1,MR2,RT,FF,DEP gate
```

**`merge-to-release.sh` asks two questions**: the incoming pull request's own run, and *the release branch tip's* run, both requiring a real `e2e` verdict. The second is why e2e runs on a release branch however little a merge touches — the next merge is judged against the tip this one creates.

### Release · `WP A -> main, WP B -> main`, one milestone

```mermaid
flowchart TD
  WPA[WP A: Del 1 of 2] --> BA[(branch A)] --> MA[(main)]
  WPB[WP B: Del 2 of 2] --> BB[(branch B)] --> MB[(main)]
  MA --> MS[shared milestone]
  MB --> MS
  MS --> DEP{{deploy.sh: settles every issue in the milestone}}
  DEP --> PROD[production]
  PROD --> PD[post-deployment checks, one per requirement per package]

  classDef gate fill:#fde,stroke:#a36
  classDef check fill:#eef,stroke:#46a
  class DEP gate
  class PD check
```

### Release · `WP A -> WP B -> main`

Sequential, and the arrow is doing more work here than a merge. **WP A is tested first; WP B is then developed and tested on top of it, in its own branch.** So B's branch carries A's work, B's testing exercises both, and main receives them together.

```mermaid
flowchart LR
  BA[(branch WP A)] --> TA[preview · user test · technical test]
  TA --> BB[(branch WP B, cut from A)]
  BB --> DEV[WP B developed on top]
  DEV --> TB[preview · user test · technical test<br/>exercising A and B together]
  TB --> M[(main)]

  classDef branch fill:#eef3ea,stroke:#5c7a4a
  classDef test fill:#eef,stroke:#46a
  class BA,BB,M branch
  class TA,TB,DEV test
```

Reach for it where B depends on A and A is unready to land alone. Where A can land by itself, the shape is `Project -> main` twice and main carries the sequencing.

## A release delivers once

**One Release delivery is one deployment to production**, whatever it carries, and the deployment is the end of that delivery rather than an event after it.

The testing divides along that line, and the two halves are easy to confuse because they use the same machine:

| | scope | when |
| --- | --- | --- |
| user testing and **technical testing** | one change | before that change merges to main |
| **rehearsal deployment** | the whole release | once, after main is assembled and before production |
| **production deployment** | the whole release | once |
| post-deployment checks | one per work package | after production |

**Technical testing happens to run on the rehearsal environment; the rehearsal deployment is a different act.** The first asks *does this change behave correctly on hardware like production's?* The second asks *does deploying this release work?* — and it can only be asked of the assembled thing, which is why it happens once and late.

```mermaid
flowchart TB
  subgraph PER["per change, before it merges"]
    P1[preview] --> U1[user testing] --> T1[technical testing<br/>on the rehearsal environment]
  end
  PER --> M[(main · accumulating)]
  M --> RD{{rehearsal deployment<br/>of the whole release}}
  RD --> PD{{production deployment<br/>once}}
  PD --> C[post-deployment checks<br/>one per work package]

  classDef gate fill:#fde,stroke:#a36
  classDef check fill:#eef,stroke:#46a
  class RD,PD gate
  class C check
```

Under D55 this is what main accumulating buys: each change is proven on its own, and the release pays for one rehearsal and one deployment rather than one of each per change.

**The milestone is the only thing identifying the group** — there is no issue for it. So *"move out what is not shipping before deploying"* is the whole control: the deploy settles everything in the milestone.

## The table of checks, and how each one gets its answer

Get methods matter because they are where the nine pictures come from. The right-hand column is what the model replaces.

### Gates — `deploy.sh`, in order

| gate | purpose | criteria | get method | latency |
| --- | --- | --- | --- | --- |
| `on-remote` | the build can fetch what it is told to build | sha present on `origin` | `git ls-remote` | current |
| `ci` | the exact tree shipping was tested | push run passed; `--require e2e` on a release | `gh run list --commit` | current |
| `pull-request` | the review's own run agreed | PR run passed; absence said aloud | `gh run list --commit`, filtered to `pull_request` | current |
| `schema` | the image can boot against the live database | target migrations ⊇ database's | `git show` + `/health` | current |
| `version` | what ships is the version claimed | semver agrees across tree, milestone, tag | `git` + `gh api milestones` | current |
| `milestone` | everything shipping was meant to | every open issue in it is built by a commit | `gh api milestones --paginate` + `git log --grep` | current |
| `preview` | the image ran somewhere first | preview answers on the target version | `curl /health` | current |
| `rehearsal` | the image ran under production's shape | rehearsal answers on the target version | `curl /health` | current |
| *settle* | the record matches what shipped | phases, milestones and comments written | `gh` mutations | **re-read after write** |

### Content obligations — `check-transitions.sh`, `verify.sh`, `actions.py`

Grouped by obligation rather than by grep, because the obligation is what the model owes and the greps are today's expression of it.

| obligation | purpose | asked by | get method |
| --- | --- | --- | --- |
| triage complete | a requirement can be scheduled | `check-transitions` | issue fields |
| on hold justified | a stall names something actionable | `check-transitions` | body text |
| scoped | effort known before queueing | `check-transitions` | issue fields |
| project shaped | the seven headings exist to be filled | `check-transitions` | body headings |
| provenance intact | folding a requirement keeps it findable | `check-transitions` | sub-issues + body table |
| route known | something can say whether this reaches users | `check-transitions` | issue fields |
| parent stays a parent | oversight is a design role | `check-transitions` | field + `is_parent` |
| testable | a test approach exists before building | `check-transitions`, `verify` | body headings + checkbox counts |
| built | a milestone's issues are backed by commits | `verify`, `deploy` | `git log --grep` + parentage |
| deliverable | deliveries and their checks are written down | `check-transitions` | body headings |
| closable | the lesson is captured before closing | `check-transitions` | body text + unticked boxes |
| whose turn | what needs the owner is brought to him | `actions.py` | decision state + `reviewDecision` |

**`testable`, `built` and `closable` are each asked by more than one script, in more than one way.** That is the issue in one line.

## What the model must therefore supply

Reading the tables rather than designing from scratch, the snapshot owes exactly:

| | because |
| --- | --- |
| `is_parent`, `is_work_package` | four gates and three checks branch on it, and two copies disagreed — #370 |
| fields resolved **by name** | every consumer matches option ids today |
| `commits` — naming it, and naming its parent, kept apart | the `built` obligation, and #375 |
| `owes` — the obligation list above, per issue | three scripts asking one question three ways |
| `waiting_on` | `actions.py`'s whole purpose |
| `age` on the snapshot itself | so a gate can refuse what a report may serve |

## Still open

| | |
| --- | --- |
| **partial failure** | what the snapshot says when GitHub answers and git stays silent. Today each script decides for itself, mostly by exiting 0 |
| **the obligation table per issue type** | the rows above are the union; the owner's *"each issue type has defined requirements for each lifecycle step"* means a grid, and closedown is its last row |
