# 71 Functional views

**Draft, under [Decision #472](https://github.com/delphside/tile-lite-elite/issues/472)
(D71), option 1.** This file is the functional set for #71: who uses the
service, what each may do, and the journeys and lifecycles that follow from
that. It comes before [`71-design.md`](71-design.md) and
[`71-data-model.md`](71-data-model.md), and the requirements it surfaces are
raised on #71 before any technical decision they touch.

It is the **to-be**: the service as #71 leaves it. The views follow
[docs/diagrams/README.md](../../../../diagrams/README.md). Rule ids are
[docs/1.0](../../../../1.0-rules.md)'s.

## Use case

One diagram for the service. Each line is a permission: auth (2.5) and seats
and invitations (2.7) enforce it. A game's creator is a role one player holds
in one game, so it is drawn as a kind of player. A bot is an account, and plays
through the same use cases a player does. Time stands for what nobody asks for.

```mermaid
flowchart LR
  player["👤 Player"]
  creator["👤 Game creator"]
  bot["👤 Bot"]
  admin["👤 System administrator"]
  time["⏱ Time"]

  creator -. "is a" .-> player
  bot -. "is a" .-> player

  subgraph service["Tile Lite Elite"]
    register(["Register and sign in"])
    details(["Change my details"])
    reset(["Reset my password"])
    create(["Create a game"])
    roster(["Arrange the seats: add, remove, swap, invite"])
    start(["Start a game"])
    abort(["Abort a game"])
    forceresign(["Force-resign a seat"])
    answer(["Accept or decline an invitation"])
    open(["Take an open seat"])
    turn(["Take a turn: place, pass or exchange"])
    suggest(["Ask for a suggested move"])
    resign(["Resign"])
    chat(["Chat in a game"])
    hide(["Remove a game from my list"])
    history(["See my games, ratings and history"])
    forceend(["Force-end a game"])
    delete(["Delete an account"])
    retire(["Retire a seat past its time limit"])
    remind(["Remind the player on turn"])
    expire(["Remove expired games"])
  end

  player --- register
  player --- details
  player --- reset
  player --- create
  player --- answer
  player --- open
  player --- turn
  player --- suggest
  player --- resign
  player --- chat
  player --- hide
  player --- history
  creator --- roster
  creator --- start
  creator --- abort
  creator --- forceresign
  admin --- forceresign
  admin --- forceend
  admin --- delete
  time --- retire
  time --- remind
  time --- expire
```

## Journeys

One activity diagram per use case. Each step either causes a transition in a
lifecycle below or only reads state, and cites the rules it exercises, so the
end-to-end scenarios come from the journeys and coverage is read against them.
A step's swimlane is its actor; *service* is the server acting on a request.
Four are drawn; the rest are listed after them.

### Set up a game and fill its seats

```mermaid
flowchart TD
  s0((start)) --> c1["Creator: chooses edition, time limit and seats<br/>GAME-3, TIME-1, TIME-2"]
  c1 --> v1{"service: at least two seats,<br/>every named seat a registered player?"}
  v1 -- no --> r1["refused, nothing created"]
  v1 -- yes --> t1["service: game Not Started<br/>own and bot seats Claimed, invited seats Unsent"]
  t1 --> c2["Creator: sends the invitations<br/>Unsent → Invited"]
  c2 --> i1["Invitee: sees the invitation (reads)"]
  i1 --> d1{"Invitee: accepts?"}
  d1 -- yes --> t2["Invited → Claimed"]
  d1 -- no --> t3["Invited → Declined<br/>DEL-3"]
  t2 --> c3["Creator: starts the game"]
  t3 --> c3
  c3 --> v2{"service: no seat Unsent or Invited,<br/>two or more left once spent seats drop?<br/>GAME-3"}
  v2 -- no --> r2["refused, nothing changes"]
  v2 -- yes --> t4["service: spent seats dropped, seats renumbered<br/>Claimed → Playing, racks dealt, game Active"]
  t4 --> e0((end))
```

### Take a turn

```mermaid
flowchart TD
  s0((start)) --> p1["Player or bot: told it is their turn (reads)"]
  p1 --> p2["Player: composes a word, which survives other turns<br/>until a tile lands in its cells (client only)"]
  p2 --> p3["Player or bot: places, passes or exchanges"]
  p3 --> v1{"service: this seat's turn, and the move legal?"}
  v1 -- no --> r1["refused, nothing changes"]
  v1 -- yes --> t1["service: applied, version and turn move,<br/>tiles drawn, every client told"]
  t1 --> v2{"service: does the game end?<br/>GAME-2, the scoreless limit, out of tiles"}
  v2 -- no --> p4["next seat told it is their turn"]
  v2 -- yes --> t2["service: game Finished, ratings settled<br/>RATE-2, RATE-3"]
  p4 --> e0((end))
  t2 --> e0
```

### Leave a game in play

```mermaid
flowchart TD
  s0((start)) --> d0{"how"}
  d0 -- "player resigns" --> a1["Playing → Departed, resigned<br/>RATE-2"]
  d0 -- "creator or administrator force-resigns" --> a2["Playing → Departed, force-resigned<br/>RATE-3"]
  d0 -- "time: the move limit passes" --> a3["Playing → Departed, timed out,<br/>tiles back to the bag<br/>TIME-3, RATE-3"]
  a1 --> b1["tiles back to the bag"]
  a2 --> b1
  b1 --> v1{"service: at most one seat still playing?<br/>GAME-2"}
  a3 --> v1
  v1 -- yes --> t1["game Finished, ratings settled"]
  v1 -- no --> t2["if it was their turn, the next seat is told;<br/>a bot's turn runs"]
  t1 --> e0((end))
  t2 --> e0
```

### Abort a game

```mermaid
flowchart TD
  s0((start)) --> c1["Creator: aborts, before or after the start<br/>GAME-1"]
  c1 --> t1["service: pending invitations cancelled"]
  t1 --> t2["service: game Aborted, seats frozen as they stand<br/>pending D68"]
  t2 --> t3["no rating changes"]
  t3 --> e0((end))
```

### Still to draw

| use case | actor | rules it exercises |
| --- | --- | --- |
| Register and sign in | player | ACC-1, ACC-2, LIMIT-1 to LIMIT-5 |
| Change my details | player | the lookup rule in `71-design.md` |
| Reset my password | player | ACC-1 |
| Arrange the seats: add, remove, swap | creator | GAME-3, GAME-4 |
| Take an open seat | player | GAME-4 |
| Ask for a suggested move | player | |
| Chat in a game | player | |
| Remove a game from my list | player | DEL-5 |
| See my games, ratings and history | player | ACC-3, DEL-10, RET-2, CLOCK-4 |
| Force-end a game | administrator | RATE-1 |
| Delete an account | administrator | DEL-1 to DEL-10 |
| Remind the player on turn | time | TIME-4 |
| Remove expired games | time | RET-1, RET-3, RET-4 |

### Questions the journeys raise

Functional, so answered before the technical decisions:

1. **Aborting changes nobody's rating**, which is what the code does, but
   docs/1.0 does not say so. RATE-1 covers only an administrator's force-end.
   Proposed: a rule beside GAME-1.
2. **Who may force-resign a seat.** Both the creator and an administrator can
   today, and RATE-3 says how it is rated but not who may do it. Proposed: a
   rule naming both, since the use case diagram draws both.
3. **A departing seat's tiles go back to the bag.** The code does this for
   every departure (`finish_via_resignation`, `apply_move_timeout`), but
   docs/1.0 states it only for a timeout (TIME-3). Proposed: one rule for
   every departure.

## Lifecycles

The state machines for the game, the seat and the invitation are in
[`71-design.md`](71-design.md), *Seat state belongs to the seat*, and move here
when D71 is agreed. Each journey step is checked against them: a step that
changes something with no matching transition is a missing transition, and a
transition no step reaches is internal, like a sweep, or not needed.
