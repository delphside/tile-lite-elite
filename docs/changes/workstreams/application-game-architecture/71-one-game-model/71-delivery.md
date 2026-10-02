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

**Pending:** the branch and milestone each delivery takes is
[Decision #464](https://github.com/delphside/tile-lite-elite/issues/464) (D64).
The recommendation is a branch and a milestone per delivery, #268 and #269
sharing one branch and `1.0.0`, and the later packages left without a milestone
until each is scheduled.

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
