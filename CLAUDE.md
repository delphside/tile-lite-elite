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
- Triage is done jointly with the owner, never alone. Minimum: clear short
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
- Commits say `Refs #N`, or `Closes #N` only when the change never leaves the
  repository. Every subject starts `app X.Y.Z api M.N:` and a space.
- Push immediately after committing. Until pushed, a change does not exist.
  Run an unpushed script to test it, never to use it.

## Deliveries and releases

- A delivery is any update to a programme asset delivered to its users,
  including document updates. A release is a new version of the application,
  delivered to production with a new semver. Projects define their
  deliveries with the updated assets and the route.
- A pre-approved change makes no delivery, so it takes no letter milestone
  and no row in the delivery log; its record is the closed issue and the
  commits. The two shapes are exclusive: either straight to main with none of
  them, or a branch, a pull request, a delivery, a letter milestone and a row.
- Every project delivery has a milestone, recorded in the delivery log: the
  release semver if it includes a release, otherwise the previous semver with
  a letter appended. The project issue sits in its last delivery's milestone.
  An earlier delivery gets a Project Delivery issue if it is a release, so it
  can be planned and show in the release view, or if its pre-approved answer
  differs from its project's, so that answer has somewhere to live. Other
  earlier deliveries get none.
- A release milestone is a shipping list. The deploy settles everything in
  it, so move out what is not shipping before deploying.
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

## Documentation

- One fact, one home. The rule lives in its owning document, the argument in
  the issue, and every other mention is a link.
- At a process step, consult the owning document. A decision about process
  goes in the decision log (the process-definition glossary), then in the
  one place where that part of the process is documented.
- docs/N.N numbering: 1.x product, 2.x design, 3.x lifecycle, 4.x reference.
  A change document lives in its issue's folder under docs/changes/.

## Where the detail is

| for | read |
| --- | --- |
| what to type: release, rollback, emergency | docs/3.3 |
| the lifecycle in full, and why | docs/3.6 |
| workstreams and what each owns | docs/3.7 |
| artefacts, and the strings tooling matches | docs/4.8 |
| daily state | scripts/inbox.sh, scripts/status.sh, scripts/actions.py |
| where a fact belongs, before writing it | docs/1.6, and the change-a-document skill |
