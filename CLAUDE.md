# The process on one page

This page owns the rules. The numbered documents own the procedures and the
reasons, and issues own the arguments. If this page and a document disagree,
one of them has a defect: fix it, don't work around it.

## The work

- Something that should be true and is not becomes a Requirement issue. Raise
  it quickly. Discussion happens in the comments; the conclusions go in the
  body, which is edited to stay current. Where the project is already clear,
  raise the project instead and skip the requirement.
- Make a tooling change when something first needs it, not when it occurs to
  you. The requirement is still raised; the doing waits for the need.
- Claude sweeps, the owner reacts. Claude looks across every open item and
  identifies what can be progressed; the owner should not have to scan the
  board to find work waiting on him. So anything genuinely needing him is
  brought to him, and everything else is Claude's to find and move.
- Triage is done jointly with the owner, never alone, and Claude leads it:
  bring the reading and the proposal, then agree it. Minimum: clear short
  description, workstream, priority, type of change. Then scope (options,
  dependencies, effort), then project planning. Outcomes: solo project,
  grouped project, straight to main, on hold, cancelled.
- A project owns its requirements: sources are folded and closed. Its issue
  carries seven headings: requirements, design, impacted artefacts, test
  approach, dependencies and related work, deliveries, post-deployment
  checks against requirements. Under each heading is the content or a link
  to the design document that holds it, never both.
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
  review its mechanics, and a release committed straight to main cannot be
  guaranteed to work and blocks every other release until it does, because
  main is what gets deployed.
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
- The pull request body is the review surface. It defines the scope of this
  delivery given the project context, and does not duplicate the project
  body or documents. Add the owner as reviewer at creation. He ticks and
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
- `Route` belongs to the **artefact**, not to the change. A delivery combines
  artefacts with different routes, and the issue field is a summary of them —
  the heaviest one. What shape the change needs follows from that combination
  and not from the summary alone.
- So there are two shapes: straight to main, recorded by its commits; or held
  back on a branch, which then owes a pull request, a milestone and a row in
  the delivery log. The branch is what makes a delivery a point in time; the
  milestone is what places that point in the sequence.
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
  incomplete, and check-transitions.sh derives all of them from the milestones.
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

## Tests, checks and decisions

- Test conditions derive from stated rules, not from the code. The game rules
  are docs/1.0.
- A gate refuses and work stops; a check reports and a person decides. A new
  check is shown to fail before it ships.
- A decision is applied in the same commit that marks it answered, or an
  issue is raised and named in the decision.
- A decision is not a change vehicle. It routes work: raise a requirement, add
  one to a project, update a project or the documents, or close something. It
  may make a pre-approved change only where no suitable requirement or project
  exists. So it takes no semver and no letter milestone, and no delivery-log
  row.

## Documentation

- One fact, one home. The rule lives in its owning document, the argument in
  the issue, and every other mention is a link.
- At a process step, consult the owning document. A decision about process
  goes in the decision log (the process-definition glossary), then in the
  one place where that part of the process is documented.
- docs/N.N numbering: 1.x product, 2.x design, 3.x lifecycle, 4.x reference.
  A change document lives in its issue's folder under docs/changes/, named
  for the parent project — a work package has no folder of its own.

## Where the detail is

| for | read |
| --- | --- |
| what to type: release, rollback, emergency | docs/3.3 |
| the lifecycle in full, and why | docs/3.6 |
| workstreams and what each owns | docs/3.7 |
| artefacts, their routes, and the strings tooling matches | docs/4.8 |
| daily state | scripts/inbox.sh, scripts/status.sh, scripts/actions.py |
| where a fact belongs, before writing it | docs/1.6, and the change-a-document skill |
