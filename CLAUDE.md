# The process on one page

This page owns the rules. The numbered documents own the procedures and the
reasons, and issues own the arguments. If this page and a document disagree,
one of them has a defect: fix it, don't work around it.

## The work

- Something that should be true and is not becomes a Requirement issue. Raise
  it quickly. Discussion happens in the comments; the conclusions go in the
  body, which is edited to stay current. Where the project is already clear,
  raise the project instead and skip the requirement.
- **Raise quickly, but into an existing requirement where one covers the area.**
  Look first; a new row in a table beats a new number. Seventy-five issues were
  raised in the fourteen days to 2026-09-17 and ten of them were facets of one
  thing — the board tooling — which is what #383 then exists to unify. A new
  issue is right when the subject is genuinely separate, or when the existing
  one has been scoped and widening it would reopen that. Owner, 2026-09-17:
  *"It is more efficient to have one requirement covering an area we are
  revising."*
- **A decision belongs on what it decides.** Its own issue only where it spans
  several, or where the argument is long enough to bury the requirement. Either
  way it is a `Decision` issue, and the board indexes them by type.
- **A decision is only worth an issue while there is a choice to discuss.**
  Owner, 2026-09-21: *"Decisions are only useful when there is a choice to be
  discussed. A settled decision lives in the permanent documents and claude
  files."* So an answer that is already settled goes straight to its owning
  document and to this page, with the argument in the commit message — no
  issue, no `D` number, nothing to close later. The test is whether anybody
  still has to be convinced.
- **A settled decision is never maintained; the document carrying it is** —
  the general rule under *Documentation*, applied to decisions.
- **Options live in the body, numbered, each saying what it constrains**, so one
  issue can be read and settled rather than assembled from a thread. Owner:
  *"being able to focus on one with options clearly presented in the body would
  help a lot."*
- Make a tooling change when something first needs it, not when it occurs to
  you. The requirement is still raised; the doing waits for the need.
- Claude sweeps, the owner reacts. Claude looks across every open item and
  identifies what can be progressed; the owner should not have to scan the
  board to find work waiting on him. So anything genuinely needing him is
  brought to him, and everything else is Claude's to find and move.
- Triage is done jointly with the owner, never alone, and Claude leads it:
  bring the reading and the proposal, then agree it. **Except in Delivery
  Tooling and Process Definition, and for type `tooling` or `documentation` in
  any workstream, where Claude triages alone** — D54, 2026-09-17. Anything
  reaching production, the product and game rules, and anything irreversible
  outside git still come to the owner whatever their workstream. Minimum: clear short
  description, workstream, priority, type of change. Then scope (options,
  dependencies, effort), then project planning. Outcomes: solo project,
  grouped project, straight to main, on hold, cancelled.
- **Related change goes in one project, so it is designed once.** Owner,
  2026-09-21: *"I am keen we keep related changes in the same project so they
  can be designed together. I want to minimise having to coordinate design
  across projects."* A different route is not a reason to split a project — it
  is a reason to split a delivery, which is what a work package already is. Two
  projects are right where deciding one does not constrain the other, and then
  a link under *Dependencies and related work* is enough.
- **The exception is a shared mechanism**, which is owned by one workstream and
  designed to by the others — owner, 2026-09-21. It gets a delivery project of
  its own, treating every use case as a customer feeding requirements for the
  generic thing; each workstream then builds its own functionality on top. The
  test is whether it would exist for only one caller. If it would, it belongs
  to that caller's project. docs/3.7 says which workstream owns which
  mechanism.
- **A mechanism ships in the same release as its first customers**, so it is
  tested against a real requirement rather than only against its own tests —
  owner, 2026-09-21. Scoped and designed independently, scheduled jointly: its
  milestone is the one its first callers carry.
- A project owns its requirements: sources are folded and closed. Its issue
  carries eight headings: requirements, design, impacted artefacts,
  **non-functional design**, test approach, dependencies and related work,
  deliveries, post-deployment checks against requirements. Under each heading is
  the content or a link to the design document that holds it, never both.
- **Non-functional design is four questions and *none, because…* answers any of
  them**: capacity, failure, limits and timeouts, secrets and access. Added
  2026-09-22. #402 and #291 are both projects because nothing asked those
  questions per change, and a project is the expensive way to answer what was
  cheap at the time. A limit's answer says **where its number came from**.
- **A dependency is declared from both ends.** `waits on` has an inverse,
  `is needed by`, so a relation lives in both bodies rather than in whichever was
  written second. #400's eight customers were found by going looking, not by
  each having said so.
- A project moves through the Phase field. The wording is the field's own
  stage descriptions:

  | phase | done when |
  | --- | --- |
  | Scope | What the project does. Technical option chosen where it affects dependencies. |
  | Q3, Q2, Q1 | The queue. Q1 is next off the blocks. |
  | Design and Test Approach | Design option chosen. Design completed. Test Approach defined. |
  | Development | Being built on its project delivery branch |
  | User testing | On Preview for user functional testing. On Rehearsal for technical testing. |
  | Deployment | Image: Prev->Reh->Prod. Repo-only: merge. Non-repo: by hand. |
  | Post-deployment | Check it is working and giving the benefit expected. |
  | Project Closedown | Lessons learnt completed. |

  The post-deployment check has one row per requirement.

## Changes

- A Production Release always takes a branch, a pull request, a semver
  milestone and a row in the delivery log. The pull request is what gives the
  review its mechanics, and a release commit that reaches main *unproven*
  cannot be guaranteed to work and blocks every other release until it does,
  because main is what gets deployed.
- **Proven and unshipped is different, and is the normal state.** A release
  change merges to main once preview, user testing and rehearsal have passed
  against its branch tip; shipping may follow immediately or later. So main is
  the accumulating next release, and a release branch is for a release that
  must stabilise while main moves on, not for one delivery. D55. The condition
  that makes this safe lives in the emergency path: cut an emergency from the
  last released tag, never from main.
- Otherwise a branch exists to hold a change back. Branch only when the old
  version is needed while the work is in progress; otherwise commit straight
  to main, which is what pre-approved means. A document-only change never takes a
  branch: they live too long, main moves, and the review does not happen. Approval is
  the `pre-approved` milestone; anything else, including none, means not pre-approved. One branch per project, and everything
  the project touches goes on it, documentation included.
- A pull request is what gives a review mechanics: a diff, a place to comment,
  a recorded approval, a merge that waits for a tick. Pre-approved does not mean
  unreviewed — it means the discussion was the review, which is enough where a
  change is cheap to reverse and is not, for the image.
- The pull request body is the review surface. **It says which part of the
  project's scope is being requested, and what is deliberately left out** —
  owner, 2026-09-17. It does not duplicate the project body or the documents:
  the argument, the measurements and the design live on the issue, and a body
  that restates them makes the reviewer read the same thing twice to find the
  one paragraph that is new. Add the owner as reviewer at creation. He ticks and
  approves, Claude merges by rebase and fast-forward.
- A review comes back two ways and they return differently. **Approved with
  comments** stays approved: make the changes and merge. **Changes requested**
  does not: make the changes, then re-request the review, which is what puts it
  back to awaiting review rather than leaving it sitting as answered. The board
  reads both from `reviewDecision`, so skipping the re-request leaves it in the
  wrong column and waiting on nobody.
- Commits say `Refs #N`, or `Closes #N` only when the change never leaves the
  repository. Every subject starts `app X.Y.Z api M.N:` and a space.
- Push immediately after committing. Until pushed, a change does not exist.
  Run an unpushed script to test it, never to use it.

## Deliveries and releases

- A **delivery** is a change reaching its users — any update to a programme
  asset, documents included. **Every change has one**, because it has to reach
  main. A **release** is a new version of the application, delivered to
  production with a new semver.
- **Not every delivery has a milestone.** A change applied straight to main is
  not assumed to be a single point in time, so it has no place in the sequence
  the milestones are: no branch, no pull request, no milestone, no
  delivery-log row. Its record is the commit, which references the requirement
  or project it serves — possibly more than one.
- **A milestone marks a delivery made at one point in time**, and places it in
  the sequence: the release semver where it includes a release, otherwise
  **production's current version** with a letter appended. Production's, not
  the development version, because the development version is intent and can
  change — 0.7.3 became 0.8.0 on 2026-09-09, and a letter pinned to it would
  have named a release that never existed.
- `Route` belongs to the **artefact**, and **a delivery has one route**. Work
  touching artefacts with different routes is split into a delivery per route,
  each taking the shape its own route needs. A project might deliver its script
  changes first, then a configuration change applied in the console, then the
  application — three deliveries, three routes, one project.
- **Each of those deliveries is a work package, so each is tracked**, and the
  parent carries no `Route`. That is what replaces the old ranking: rather than
  the parent summarising its deliveries with the heaviest route they touch, the
  route lives where the delivery does. A project with a Release and an Other has
  a work package for each, and the parent has no route to set.
- **Documentation riding on a release is a pre-approved add-on.** A release that
  also touches documents stays one delivery with one semver milestone: the
  documents need no letter milestone, no second pull request and no row of their
  own. They are on the project branch already, reviewed in the same diff, and
  live when the release is. A document carried along does not make a second
  delivery.
- So there are two shapes: straight to main, recorded by its commits; or held
  back on a branch, which then owes a pull request, a milestone and a row in
  the delivery log. The branch is what makes a delivery a point in time; the
  milestone is what places that point in the sequence.
- **A Requirement never carries a milestone except `pre-approved`** — owner,
  2026-09-19: *"that is the only way they can deliver change apart from folding
  into a project."* A requirement is a statement that something should be true;
  it delivers either by folding into a project, and then the project's work
  package carries the milestone, or straight to `main` as pre-approved. Any
  other milestone on a requirement means a delivery happened with no work
  package to own it. `deploy.sh` already warns about this, and it was right when
  #380 and #379 were put in 0.8.1 on 2026-09-19 and shipped through the warning.
- **A routine update owes what its route owes, and nothing more.** A
  `Production Release` bump — a base image, a crate — lands on `main` as
  pre-approved, waits for the next release and is proved by that release's own
  regression testing; it never justifies a release of its own. An `Other` one —
  a host package, a kernel, a reboot — has no release to ride, so it supplies
  its own vehicle: work package, letter milestone, delivery-log row.
  `docs/3.6` §2.2.1 is the table.
- **Who drove the change decides the ceremony, not how big the diff is.** A
  routine dependency bump raised by tooling takes none: a Dependabot pull
  request has no project, no milestone and no delivery-log row, and its commit
  message is the record. Owner: *"I don't want to introduce ceremony for bau
  updates, especially when they are driven by tooling."* A host or dependency
  change **we** decide on and carry out is the other case — the kernel and
  package work of 2026-09-19 — and it takes the branch, the project, the letter
  milestone and the row.
- **A change to one of our own assets takes a new semver**, not a letter. The
  `Caddyfile`, `docker-compose.yml` and the `Dockerfile` are ours and reach the
  image, so changing one is a Production Release and gets a release version. The
  letter form is for a delivery that ships **no** application code at all — a
  host change, a console change, a drill.
- **Every delivery is a work package.** Work packages sharing a milestone are
  delivered together, and that grouping has no issue of its own — the milestone
  is what identifies it. A parent lists what it delivers, each row naming the
  work packages that share a milestone or saying straight to main. The four
  cases are in docs/3.6.
- **The sub-project issue can be saved, and only where nothing needs it.** A
  project with **one delivery** needs none: the parent is the work package and
  carries the milestone. Two deliveries need two, even where one goes straight
  to main carrying no milestone — a delivery with no milestone still has a
  phase, and one `Phase` cannot say delivered and not built at once. D53.
- A work package is titled `#N WP A Del 1 of 2: what it delivers`, a parent
  `#N MAIN PROJECT: what it is`. `pt P of Q` is added only where a delivery
  carries more than one package. The counts go stale and are kept anyway: a
  title saying `Del 1 of 2` is wrong loudly where `Del 1` is silently
  incomplete, and board-check.py derives all of them from the milestones.
- The parent owns the requirements, the design and the documents; a work
  package links to them and carries its own artefacts, test approach and
  post-deployment checks, because a check is answered per delivery. The parent
  needs no milestone and no Route: it has no delivery role, and both answer how
  a change reaches its users. One could be derived from the packages, but it
  would be information rather than a fact about the parent. Either may still be
  set — a target release, say — and is then ignored: a deploy settles the
  milestone's packages and skips the parent.
- The parent runs Scope, the queue, and Design and Test Approach, then stops —
  oversight is a design role. It may reach Post-deployment for a requirement no
  single delivery satisfies, and Project Closedown to close. A work package may
  delegate lessons learnt to the parent, and says so.
- A release milestone is a shipping list. The deploy settles everything in
  it, so move out what is not shipping before deploying.
- `no-release` is provisional. Resolve it to `pre-approved` or a letter
  milestone before the issue closes, or the record of how the change reached
  main is lost. `pre-approved` is closed by hand; no deploy settles it.
- A requirement carries no milestone, unless the change is made directly
  without raising a project, when it carries `pre-approved`. Any other change
  needs a project, and the project carries the milestone.
- Deploys build a fresh worktree at the target commit, never the working
  tree. The image goes Preview, then Rehearsal, then Production.
- After deploying, run verify.sh and trust exit status, not read output.
- Bump dev to the next patch straight after each production deploy; dev leads
  production by one.
- Rehearsal is closed. scripts/rehearsal-access.sh grants access by QR code.
- **Production access is the owner's to run**, reads included. An admin CLI
  listing, a database query, a log dump: ask him for it, he runs it, Claude
  works from what comes back. Owner, 2026-09-21: *"It makes sense if I do the
  production access unless there is a specific reason."* The exception is the
  scripted checks the tooling already makes — `verify.sh`, `check-hosts.sh`,
  the `/health` reads — which are bounded, reviewed and unchanged by this.

## Tests, checks and decisions

- Test conditions derive from stated rules, not from the code. The game rules
  are docs/1.0.
- A gate refuses and work stops; a check reports and a person decides. A new
  check is shown to fail before it ships.
- **Every checkbox names whose move it is**: `- [ ] **owner** — run the six
  browser tests`, or `- [ ] **Claude** — write the regression tests`. The label
  is on the box, not inferred from its heading, so a box keeps its owner when
  it moves and a reader sees whose it is without scrolling up. An unlabelled
  box is waiting on nobody, and `board-check.py` reports it.
- A decision is applied in the same commit that marks it answered, or an
  issue is raised and named in the decision.
- A decision is not a change vehicle. It routes work: raise a requirement, add
  one to a project, update a project or the documents, or close something. It
  may make a pre-approved change only where no suitable requirement or project
  exists. So it takes no semver and no letter milestone, and no delivery-log
  row.

## Documentation

- **Look up the industry's word before inventing one, and look inside the
  standard you have already adopted.** Owner, 2026-09-21: *"Refer to ITIL, none
  of this is new to us. We should be reusing the industry standard terminology
  and process."* And 2026-09-22: *"we are too quick to invent our own thing
  rather than adopt industry standards."* Take the term and the shape of the
  practice, leave the ceremony that needs more people than this has, and say
  which practice an answer came from. docs/3.6 has the mapping tables.
- **The first rule did not stop it, so here is the test.** On 2026-09-22, in the
  commit adopting C4, I invented a view called *Runtime* that C4 already has as
  *Dynamic*, and labelled a Deployment diagram as a Container one. Before naming
  anything: **read the standard's own list, including its supplementary parts**,
  then look at one neighbouring standard. A name only this repository knows is a
  cost paid by every future reader, and *we named it ourselves* is never the
  reason to keep one.
- One fact, one home. The rule lives in its owning document, the argument in
  the issue, and every other mention is a link.
- **The documents live; the issues expire.** Owner, 2026-09-21: *"The project
  documents are living documents, the issues are only relevant while they are
  open."* A `docs/N.N` file answers what is true now and is edited whenever that
  changes. An issue answers what was argued and when, and once it closes that is
  all it answers. So when something changes, change the document — do not edit a
  closed issue to agree with it, and do not cite one as the authority for a
  rule. A line added to a closed issue at the moment it is superseded is a
  record; editing one to keep it true is the thing to avoid.
- At a process step, consult the owning document. A process question with a
  choice still open is a **`Decision` issue** — the GitHub issue type, carrying
  `Decision State` and an `Agreed Decision` heading that `board-check.py`
  reads — and is applied to the one place that part of the process is
  documented, then closed. A process answer that is already settled skips the
  issue and goes straight to that document and this page. The
  process-definition glossary holds D1 to D38 and is history: it predates the
  issue type and is not added to.
- docs/N.N numbering: 1.x product, 2.x design, 3.x lifecycle, 4.x reference.
  A change document lives in its issue's folder under docs/changes/, named
  for the parent project — a work package has no folder of its own.
- **A report the programme produces on a cadence goes in `docs/reports/<name>/`,
  one file per period, named `TLE_<CODE>_<period>.md`.** Owner, 2026-09-22 —
  the name has to mean something once it has left the folder. It is neither a numbered document
  nor a change document: it records what was true at a moment, is never edited
  afterwards, and is not superseded by the next one — the series is what carries
  the meaning. `docs/reports/capacity_plan/` is the first.
- **Templates live together in `docs/templates/`, and the numbered document that
  owns the rule links to them.** Owner, 2026-09-22: *"Templates fit into
  numbered programme docs but it seems convenient to keep them together and
  reference from the numbered docs."* The document owns the rule and carries the
  reasoning; the template carries the form and no argument. A new template owes
  that link, or nobody finds it at the moment they need it. The four GitHub
  fills in for you stay in `.github/`, because it will not read them anywhere
  else.

## Where the detail is

| for | read |
| --- | --- |
| what to type: release, rollback, emergency | docs/3.3 |
| the lifecycle in full, and why | docs/3.6 |
| workstreams and what each owns | docs/3.7 |
| artefacts, their routes, and the strings tooling matches | docs/4.8 |
| daily state | scripts/board-inbox.py, scripts/board-status.py, scripts/board-actions.py |
| where a fact belongs, before writing it | docs/1.6, and the change-a-document skill |
