# 71 Delivery

**How #71 reaches production.** The design is in [`71-design.md`](71-design.md)
and how it is proved is in [`71-test-approach.md`](71-test-approach.md). Agreed
with the owner on 2026-08-28.

## Two work packages, one delivery

Owner: *"it is one release because they have to agree on the API."*

| work package | what it is | requirements |
| --- | --- | --- |
| **1 · end to end** | the game state model, and a centralised message handler — what is said, when, and what a client may assume | #142, #80, #106 |
| **2 · client** | the UI reworked onto that model: events reach one handler, which updates local state, and the screen follows the state | #105, #152, #88 |

**A work package is a branch and a pull request of its own**, so these are
reviewed and merged separately. The **delivery** is one, because a server ahead
of its client moves the version pair and breaks the contract that exists to
prevent exactly that.

**The first generates the detail of the second**, so it goes first. The project
is not delivered until both are merged.

## Testable separately, deliverable together

Work package 1 can be exercised in full on its own — the test client is the
second observer — while still not being shippable alone. That gives the project
an honest test gate in the middle rather than only at the end, without
pretending the halves can ship apart.

## Expect `crates/ui` to change in work package 1

`crates/ui` is in the same workspace, so the moment work package 1 touches
`crates/api` the real client stops compiling. WP1's branch will carry mechanical
changes to it — renamed fields, adapted call sites — purely to keep the
workspace green.

**That is not work package 2 starting early**, and it is worth saying because it
will look like it in a diff.

## What is deliberately not in it

| | why |
| --- | --- |
| **#73** undo | a capability built *on* the model rather than evidence of it, and the largest item in the workstream. The design says the same: *"Undo is not in this change, but this change is what it waits for."* |
| **#157** staged tile survives removal | the design settles it as *"a work package, not a prerequisite"* — client-only, no API move, shippable before or after |

## Migration, and what it costs

The design records that **existing games are deleted rather than migrated**;
users, ratings and rating history are kept. That makes the delivery a schema
change with a data loss that has already been agreed, so the release owes a
rehearsal against production's data shape and a plainly worded note about what
players lose.

## Workstream

It spans two — the model is Application & Game Architecture's, the client rework
touches Client UI's artefacts. A project may span workstreams where it
simplifies delivery, and it carries **Application & Game Architecture**, where
its content is defined.
