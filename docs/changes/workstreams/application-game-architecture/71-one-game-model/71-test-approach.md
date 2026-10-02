# 71 Test approach

**How #71 is built and tested.** The design is in
[`71-design.md`](71-design.md); this says how it is proved. Agreed with the
owner on 2026-08-28.

**Server first, tested by a test client; then the real client.** Owner: *"maybe
we do the server first, and stub the client for testing. Then develop the real
client."* What stands in for the client is the real **test client** below, not
a stub, and this project uses that term throughout.

**Testing is organised by work package**, the six in #71's body.[^d56]

## A test client, as its own crate

Owner, 2026-08-28: *"I would think we could have a test client as a separate
crate. When it ran it could connect in the same way as the real client. It is
the client that initiates everything."*

**Two instances of it cover the whole fault class.** Everything the server does
is either a response to a client, or a broadcast provoked by another one — so
nothing needs a server-side harness to make it happen, only a second client
doing something. That is exactly the *"second client watching"* without which,
as #71 says, none of its three faults would have been caught.

**It compiles against `crates/game-wire`**, like both real sides
(`71-data-model.md` §3), so it rebuilds the same domain objects they do and
asserts on the **state it receives** rather than on rendered output. That is the right level for
Core Game Lifecycle (#268): what the server *sent* is the question, and a browser can only
show what a client chose to draw.

**A stub is not needed for the contract**, and would be harmful. The DTOs are a
shared crate both sides compile against, so a disagreement is a build failure
rather than a runtime surprise. A hand-maintained fake would replace that
guarantee with a fiction.

**It is #10 minus an engine.** A binary that logs in over the public API,
subscribes, and records what arrives is the bot harness's skeleton — so building
it here makes #10 *"attach `engine-core` and submit moves"* rather than *"build
a client"*.

## One test file per work package

This file is the overall approach; each package has a test file written to the
same headings, so the set reads as one plan.[^d71]

| package | test file |
| --- | --- |
| WP A, #268 Core Game Lifecycle | [`71-test-wp-a.md`](71-test-wp-a.md) |
| WP B, #269 Core Client UI | [`71-test-wp-b.md`](71-test-wp-b.md) |
| WP C, #270 Additional Game Lifecycle | [`71-test-wp-c.md`](71-test-wp-c.md) |
| WP D, #271 Additional Client UI | [`71-test-wp-d.md`](71-test-wp-d.md) |
| WP E, #272 Undo and Redo | [`71-test-wp-e.md`](71-test-wp-e.md) |
| WP F, #290 dioxus 0.7 | [`71-test-wp-f.md`](71-test-wp-f.md) |

Each has four headings: **what it proves**, **which layers it uses** (from the
table below), **the journeys and rules it covers** (from
[`71-functional.md`](71-functional.md)), and **its acceptance**.

## Three layers, and what only each one can answer

Owner, 2026-08-28: *"testing the server can be done by scripting the test
clients. The playwright to test client and server together."*

| layer | answers | cannot answer |
| --- | --- | --- |
| **pure function tests** — a state and an incoming update, an expected answer | did the client do the right thing with what it got | whether it would ever get it |
| **scripted test clients** — client A acts, client B observes | did the server say the right thing, to the right people, in the right order | whether any of it reaches a screen |
| **Playwright** — a real browser against a real server | do the two work together, and does it render | anything about ordering or timing, cheaply |

**A server test is a script**: *client A joins, client B joins, A moves, B must
receive the move; B disconnects, A moves twice, B reconnects and must end up
level.* That is #142 in one sentence, with no browser — and it is expressible
because the client initiates everything.

**The client's decisions are pure functions**, so Core Client UI (#269) is
testable without a server, a browser or timing. The client is not a reducer
(the note's *Stop clearing; start matching*): it has one writer of the server
cache and matches everything else on read. What that leaves to test is three
functions of plain values — `should_apply` (is this update newer than what I
hold), `current_key` (which composition belongs to this selection) and
`live_composition` (is the staged word still placeable) — and each is a table
of inputs and expected answers. *Reconnected and missed three updates* becomes
a row.

**So Playwright shrinks to what it is good at.** With the layers below carrying
ordering, delivery and state, the browser suite needs only enough to show the
wiring is real — not a case per fault. Browser tests are the slowest and
flakiest thing this project owns, and a fault like *"the phone did not see the
laptop's move"* begs to be written there, where it would be slow, intermittent,
and silent about which side was wrong.

## What already exists

`e2e/tests/ui-state.spec.ts`, on `main`: eight cases written against the
**intended** behaviour rather than the current one, six passing and two failing
on purpose. It was mutation-tested — deleting `game.set(None)` from
`on_remove_game` turns a passing case red — so it holds something up rather than
passing vacuously.

The three layers do not replace it. They keep it small.

**The two failing cases are #269's acceptance.** They are the `test.fixme` cases
for a staged tile surviving Remove and Abort, and they turn on when the
composition key lands in Core Client UI.[^d57]

## Tests the code review found missing

The whole-repository code review of 2026-10-02 (#460) found these untested
where this project changes the code, so they are written here rather than
there:

- an engine search that errors, panics or runs past `ENGINE_TURN_TIMEOUT`
  leaves its seat on turn and the game playable;
- a refused message — an illegal exchange, a placement out of turn — leaves the
  game exactly as it was, racks and bag included;
- a player holding two seats (GAME-4) sees both racks and is told which seat is
  on turn;
- a bot comes on turn after a timeout or a force-resign, not only after a move;
- no seat message is accepted once a game has left `Waiting`, and aborting
  leaves no invitation pending.

[^d71]: Decision #472 (D71): one file per stage, and a test file per package
    fitted to this one.
[^d56]: Decision #442 (D56): six work packages, deliveries decided per package.
[^d57]: Decision #443 (D57): the staged-tile fault is fixed in #269 by the
    composition key, not by a separate client release.
