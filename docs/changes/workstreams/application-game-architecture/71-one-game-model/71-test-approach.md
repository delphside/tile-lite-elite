# 71 Test approach

**How #71 is built and tested.** The design is in
[`71-design.md`](71-design.md); this says how it is proved. Agreed with the
owner on 2026-08-28.

**Server first, tested by a stub client; then the real client.** Owner: *"maybe
we do the server first, and stub the client for testing. Then develop the real
client."*

## A test client, as its own crate

Owner, 2026-08-28: *"I would think we could have a test client as a separate
crate. When it ran it could connect in the same way as the real client. It is
the client that initiates everything."*

**Two instances of it cover the whole fault class.** Everything the server does
is either a response to a client, or a broadcast provoked by another one — so
nothing needs a server-side harness to make it happen, only a second client
doing something. That is exactly the *"second client watching"* without which,
as #71 says, none of its three faults would have been caught.

**It compiles against `crates/api`**, like both real sides, so it asserts on the
**DTOs it receives** rather than on rendered output. That is the right level for
work package 1: what the server *sent* is the question, and a browser can only
show what a client chose to draw.

**A stub is not needed for the contract**, and would be harmful. The DTOs are a
shared crate both sides compile against, so a disagreement is a build failure
rather than a runtime surprise. A hand-maintained fake would replace that
guarantee with a fiction.

**It is #10 minus an engine.** A binary that logs in over the public API,
subscribes, and records what arrives is the bot harness's skeleton — so building
it here makes #10 *"attach `engine-core` and submit moves"* rather than *"build
a client"*.

## Three layers, and what only each one can answer

Owner, 2026-08-28: *"testing the server can be done by scripting the test
clients. The playwright to test client and server together."*

| layer | answers | cannot answer |
| --- | --- | --- |
| **pure handler tests** — a list of events, an expected state | did the client do the right thing with what it got | whether it would ever get it |
| **scripted test clients** — client A acts, client B observes | did the server say the right thing, to the right people, in the right order | whether any of it reaches a screen |
| **Playwright** — a real browser against a real server | do the two work together, and does it render | anything about ordering or timing, cheaply |

**A server test is a script**: *client A joins, client B joins, A moves, B must
receive the move; B disconnects, A moves twice, B reconnects and must end up
level.* That is #142 in one sentence, with no browser — and it is expressible
because the client initiates everything.

**The client handler should be a pure function** — `(state, event) → state` — so
work package 2 is testable as a list of events and an expected state. No server,
no browser, no timing. *Reconnected and missed three events* becomes an array.
It costs nothing at runtime; it is only where the mutation lives, and it is
expensive to retrofit once the rework is underway.

**So Playwright shrinks to what it is good at.** With the layers below carrying
ordering, delivery and state, the browser suite needs only enough to show the
wiring is real — not a case per fault. Browser tests are the slowest and
flakiest thing this project owns, and a fault like *"the phone did not see the
laptop's move"* begs to be written there, where it would be slow, intermittent,
and silent about which side was wrong.

## What already exists

`e2e/tests/ui-state.spec.ts`, on this branch: eight cases written against the
**intended** behaviour rather than the current one, six passing and two failing
on purpose. It was mutation-tested — deleting `game.set(None)` from
`on_remove_game` turns a passing case red — so it holds something up rather than
passing vacuously.

The three layers do not replace it. They keep it small.
