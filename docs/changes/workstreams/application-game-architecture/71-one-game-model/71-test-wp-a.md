# 71 Tests: WP A, #268 Core Game Lifecycle

Fitted to [`71-test-approach.md`](71-test-approach.md), which holds the layers
and what each can answer; this file says what WP A uses of them. The scope is
in [`71-design.md`](71-design.md), *Work packages*.

## What it proves

The server half of #71: every change goes through one handler and moves the
version, a refused message changes nothing, the seat lifecycle holds, the wire
is an identity over what a viewer may see, and an engine is a client.

## Which layers it uses

- **Pure function tests** for `apply`, one arm at a time, and the round-trip
  property `game_from_dto(game_to_dto(s, v)) == s.view_for(v)` over generated
  games.
- **Scripted test clients**, two or more, on `game-wire`: one acts, the others
  must see it. This is the layer WP A is built against before WP B exists.
- **An engine run both ways** — in the server and as a client — on the same
  position, producing the same move.

## The journeys and rules it covers

*Set up a game and fill its seats*, *Take a turn*, *Leave a game in play* and
*Abort a game*, from [`71-functional.md`](71-functional.md): GAME-1 to GAME-4,
RATE-1 to RATE-3, TIME-3, DEL-2, DEL-3, and the tests the code review found
missing (`71-test-approach.md`).

## Its acceptance

- [ ] **Claude** — every `GameMessage` arm has a test that it moves `version`, and a refused one that it changes nothing
- [ ] **Claude** — the round-trip property passes over generated games and viewers, including a viewer holding two seats
- [ ] **Claude** — a scripted second client sees every change the first makes, invitations included, within one broadcast
- [ ] **Claude** — the same engine plays the same move in the server and as a client
