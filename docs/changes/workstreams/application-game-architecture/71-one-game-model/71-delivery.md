# 71 Delivery

**What #71's body does not say about how it reaches production.** The packages,
their requirements and their deliveries are in #71's body, which the board
reads; the design is in [`71-design.md`](71-design.md) and how it is proved is
in [`71-test-approach.md`](71-test-approach.md).

## Core ships as one release

Core Game Lifecycle (#268) and Core Client UI (#269) are two packages and one
delivery, because the server and client must agree on the API: a server ahead of
its client moves the version pair and breaks the contract that exists to prevent
exactly that.[^d56] The other packages decide their own deliveries.

**Core ships from a release branch, `release/1.0.0`** [^d64]. #268 and #269
each have a work-package branch off `main`, merged into `release/1.0.0` once
tested, as docs/5.1 §1 describes. The project is too wide to sit on `main`
unshipped: once there, a smaller unrelated project could only release from a
branch of its own. So `main` stays releasable for everybody else, and `main` is
merged into `release/1.0.0` after every release (docs/5.1 §1.2), so the project
does not drift. 1.0.0 ships as soon as Core and Core Client UI are proven, and
`main` then fast-forwards to it.

**Every schema change the project needs goes in 1.0.0**, including those the
later packages need, so the migration that deletes games and rewrites tables
runs once, and #270, #271, #272 and #290 ship as ordinary releases with no
schema change of their own. Each later package's design names its schema needs
before #268's migration is written.

**The later packages carry no milestone until each is scheduled**, and then take
the normal route: a work-package branch off `main`, merged once tested.

**#268 can be exercised in full on its own**, with the test client as the second
observer, while still not being shippable alone. That gives the project a test
gate in the middle rather than only at the end.

## Expect `crates/ui` to change in #268

`crates/ui` is in the same workspace, so the moment #268 touches `crates/api`
the real client stops compiling. #268's branch will carry mechanical changes to
it, such as renamed fields and adapted call sites, purely to keep the workspace
green.

**That is not #269 starting early**, and it is worth saying because it will look
like it in a diff.

## Migration, and what it costs

Existing games are deleted rather than migrated; users, ratings and rating
history are kept. That makes the delivery a schema change with a data loss that
has already been agreed, so the release owes a rehearsal against production's
data shape and a plainly worded note about what players lose.

## Workstream

It spans two: the model is Application & Game Architecture's, and the client
rework touches Client UI's artefacts. A project may span workstreams where it
simplifies delivery, and it carries **Application & Game Architecture**, where
its content is defined.

[^d56]: Decision #442 (D56): six work packages, deliveries decided per package.
[^d64]: Decision #464 (D64): a 1.0.0 release branch for Core, shipped as soon as
    Core and Core Client UI are proven, with every schema change in it (owner,
    2026-10-14).
