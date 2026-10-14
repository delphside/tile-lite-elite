# 71 Functional views

**The first stage of #71's design**, as
[Decision #472](https://github.com/delphside/tile-lite-elite/issues/472) (D71)
settled it on 2026-10-02: one file per stage, functional views before the
technical design. This file is the functional set for #71: who uses the
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
  t1 --> t2["service: game Aborted, seats frozen as they stand<br/>D68"]
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

The state machines for the game and its seats, and for an address and its
invitations. Each journey step above is
checked against them: a step that changes something with no matching
transition is a missing transition, and a transition no step reaches is
internal, like a sweep, or not needed. The types behind the states are in
[`71-design.md`](71-design.md), *Seat state belongs to the seat*, and in
[`71-data-model.md`](71-data-model.md) §1.

### The game and its seats

Seat states are not free of the game's. Each one belongs inside a particular
game state, which is why they are drawn nested rather than side by side.

```mermaid
stateDiagram-v2
    direction LR
    [*] --> NotStarted: create

    state "Game: Not Started" as NotStarted {
        [*] --> Claimed: the creator's seat, or a bot
        [*] --> Unsent: a seat with an invitation
        Unsent --> Invited: send
        Invited --> Invited: send the link again, or pass it<br/>to a claimant or a verifier (INV-2, INV-4)
        Invited --> Claimed: accept
        Invited --> Declined: decline
        Claimed --> Withdrawn: withdraw
    }

    state "Game: Active" as Active {
        Playing --> Departed: resign, force-resign, time out
    }

    state "Game: Finished or Aborted<br/>seats frozen as they stand" as Over

    Claimed --> Playing: start, deal racks
    NotStarted --> Over: creator aborts
    Active --> Over: a seat goes out, or creator aborts
    NotStarted --> [*]: RET-3, 30 days
    Over --> [*]: RET-1, 7 days
```

Two simplifications, both deliberate. **Finished and Aborted share a box**
because they do not differ in seat terms — either way the seats stop where
they are, and this diagram is about seats. Where they differ is rating, which
`71-design.md` covers. And **seats leaving the roster are not drawn** — removed by the
creator, or dropped as spent when the game starts. They cease to exist rather
than reaching a state.

Aborting gives up every seat (GAME-1) by making the game `Aborted`, not by
moving any seat: every seat freezes as it stands, whether `Playing`,
`Departed`, `Claimed`, `Unsent` or `Invited`, and no seat can act in an aborted
game.[^d68] An aborted game settles nothing, so nothing is lost by leaving its
seats where they were. Aborting also cancels every invitation still pending, so
nobody can accept a seat in a game that is over. A game also finishes when only
one seat is left `Playing`.

Three things are worth reading off it.

**One arrow crosses the boundary.** Starting refuses while any seat is still
pending and drops the spent ones, so at the moment a game begins every seat
left is `Claimed` and there is nothing else to carry across. Starting deals
the racks, which is the same event as `Claimed → Playing`, and that is why the
two are one arrow rather than two facts that have to agree.

**The invitation states exist only before the start**, and `Playing` and
`Departed` only after it. A seat cannot be invited into a game in progress:
adding a player mid-game is not a small extension of this model but a
different one, and the diagram is where that shows up. So the handler refuses
any seat message — inviting, accepting, claiming — once the game has left
`Waiting`, with `ApplyError::GameNotWaiting`, and `Start` refuses a game that
has already started rather than doing nothing.

**Finished and Aborted freeze the seats** rather than giving them states of
their own. Which seats are `Playing` and which are `Departed` when the game
ends is exactly what RATE-2 and RATE-3 turn on — who played to the end, and
who left early — so the final seat states are the game's result, not
bookkeeping to be cleared away.

### An address and its invitations

An email address has two uses that change independently, so they are drawn as
two parallel regions.[^d72f] **Its use by an account** has one state at a time;
the states and their rules are #439's (R3, R7). **Its use by emailed
invitations** has one state per invitation, and there may be several. A
`Passed` invitation is the seat's `Invited` with an addressee
([`71-design.md`](71-design.md), *Who may accept*).

```mermaid
stateDiagram-v2
    state "An email address" as EA {
        state "Use by an account" as AU {
            [*] --> None
            None: None, never seen, released or lapsed
            Pending: Pending, one account, at most a day
            Live: Live, verified by one active account
            None --> Pending: register, or change to it
            Pending --> None: a day lapses, or the account picks another
            Pending --> Live: verified
            Live --> None: changed away, or account closed
        }
        --
        state "Each emailed invitation to it" as IU {
            [*] --> Open: invited, account use not Live
            Open: Open, the link is the credential
            Passed: Passed, waiting for its addressee
            Open --> Passed: link claimed, or address verified
            Open --> Closed: withdrawn, or the game goes
            Passed --> Closed: accepted, declined, withdrawn, or the game goes
            Closed --> [*]
        }
    }
```

An invitation to a Live address never enters the second region: it is made
in-game for the holder with an addressee from the start (INV-1).

**What each invitation event does, by the address's account use.** No
invitation event ever changes the account use.

| invitation event | account use None | account use Pending | account use Live |
| --- | --- | --- | --- |
| creator invites the address | an Open invitation, emailed with a link (INV-2) | the same: a pending address passes nothing (INV-4) | an in-game invitation to the holder, notified with no link (INV-1) |
| link claimed | Passed to the account that signs in or activates (INV-2, INV-3) | the same, even when that account is not the pending one (INV-4) | cannot happen: no invitation is Open once the address is Live |
| withdrawn, or the game goes | Closed, seat removed, link dead (INV-7) | the same | the same |
| a Passed invitation accepted or declined | nothing for the address; the seat moves on | the same | the same |

**What each account event does, by the invitation's state.** Verification is
the only account event that reaches an invitation.

| account event | invitation Open | invitation Passed | invitation Closed |
| --- | --- | --- | --- |
| registered, or changed to (None to Pending) | stays Open | unchanged | nothing |
| registering or changing to a Pending or Live address | refused (#439 R7, R3), so no event | | |
| verified (Pending to Live) | Passed to the verifier, link dead (INV-4) | unchanged: a claimed link won | nothing |
| a day lapses, or the account picks another (Pending to None) | stays Open | unchanged | nothing |
| changed away, or account closed (Live to None) | cannot exist while Live | unchanged: the addressee keeps it | nothing |

Two consequences. Open invitations and a Live address never coexist, because
going Live passes every Open one. And an address lapsing or being released
never touches an invitation: only a claimed link, a verification, a withdrawal
or the game going does.

[^d72f]: Decision #479 (D72), the owner's design of 2026-10-04 and 2026-10-11.

### Do the arrows match the messages?

No, and it is worth being precise about how they fail to, because two of the
four mismatches are the reason this note exists.

**One command, several arrows.** Creating a game sets up every seat at once,
and each may land in a different state depending on its invitation. Starting
moves every `Claimed` seat to `Playing`. A
command is not an arrow; it is a set of them.

**Several commands, one arrow.** Resigning through `/actions`, being
force-resigned through its own route, and timing out through no command at all
are one arrow, `Playing → Departed`. They differ only in `how`, which is
exactly why `Departure` is a field rather than three states.

**Commands with no arrow at all.** Placing, passing, exchanging, reordering
seats, chatting. These change the game — the board, the racks, the scores —
without moving any seat between states. **This is the class of change that was
invisible to clients**, because change was tied to writing a seat or
invitation row. It is the defect the whole note is about, and the diagram is
where it becomes obvious: most of what happens in a game is not on it.

**Arrows with no command.** Timing out and being swept away are the clock, not
a caller. Any design built on "state changes because somebody asked" gets
these wrong — which is why the sweeps and the scheduler's jobs have to bump the
version and broadcast through the same path a request does, rather than quietly
writing a row.

So the alignment worth having is not arrow-to-message. It is one level up, and
it is the only invariant that covers all four cases:

> Everything that changes a game — command, sweep, scheduled job or clock —
> bumps the one version and publishes the result.

**One arrow does align exactly, and it is the one to watch.** `Invited →
Claimed` is a single command changing a single seat, and it is the case that
has been wrong in production twice: the seat changed, the game's version did
not, and nobody heard.

**State is derived from what is there, never from the history.** The log
exists for undo and audit; behaviour reads the current state. This is the rule
that keeps the seat enum honest: a seat's state is a field, not a fold over
rows.

It also disposes of a habit worth naming, because two documents currently
encode it. Both this note's predecessor in 2.4 and the user-deletion test plan
classify an unstarted game into one of four roster situations, ordered so that
exactly one applies. That was a convenience for arguing about retention and
for making a test partition clean. It is not a description of the system, and
nothing should be written against it.
[^d68]: Decision #468 (D68): aborting freezes the seats as they stand.
