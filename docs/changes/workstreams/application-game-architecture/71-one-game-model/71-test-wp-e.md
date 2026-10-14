# 71 Tests: WP E, #272 Undo and Redo

Fitted to [`71-test-approach.md`](71-test-approach.md), which holds the layers
and what each can answer; this file says what WP E uses of them. The scope is
in [`71-design.md`](71-design.md), *Work packages*.

## What it proves

That undo followed by redo is the identity, and that undo is a new, higher
version.

## Which layers it uses

- **Pure function tests**, exhaustive on small games: undo then redo returns
  the game exactly, bag and racks included.

## The journeys and rules it covers

Undo has no journey yet; it is drawn with the package. The scoreless rule must
still end a game after an undo crosses its boundary.

## Its acceptance

- [ ] **Claude** — undo then redo is the identity over generated small games
- [ ] **Claude** — `version` only ever increases across undo and redo
