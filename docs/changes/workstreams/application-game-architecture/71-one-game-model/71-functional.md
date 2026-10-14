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
All seventeen are drawn. A step that changes something no lifecycle
covers, such as a session or a version, is marked *(no transition)*.

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
  v1 -- yes --> t1["service: applied (no transition), version and turn move,<br/>tiles drawn, every client told"]
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

### Register and sign in

A new account is active once its address is verified, and every address is
unique (D72, #439). Registering and signing in share the end of the journey.

```mermaid
flowchart TD
  s0((start)) --> d0{"Player: has an active account?"}
  d0 -- no --> p1["Player: gives a User ID, an email address and a password"]
  p1 --> v1{"service: within the caller's allowance?<br/>LIMIT-1, LIMIT-2, LIMIT-5"}
  v1 -- no --> r1["refused, not queued"]
  v1 -- yes --> v2{"service: User ID free, and the address neither<br/>Pending nor Live for another account?<br/>#439 R2, R3, R7, questions 5 and 6"}
  v2 -- "address Pending on another account" --> r4["told a verification was already sent, and offered a resend<br/>#439 R7"]
  v2 -- "otherwise no" --> r2["refused, nothing created"]
  v2 -- yes --> t1["service: account created, not yet active<br/>address None → Pending, verification email sent<br/>#439 R3"]
  t1 --> d1{"Player: verifies the address within a day?<br/>question 5"}
  d1 -- no --> t2["time: the day lapses<br/>address Pending → None, the account is never active<br/>#439 R3, question 5"]
  d1 -- yes --> t3["service: address Pending → Live, account active<br/>open invitations to it Open → Passed, including one<br/>whose link was followed before registering<br/>INV-2, INV-4"]
  t2 --> e1((end))
  r4 --> e1
  d0 -- yes --> p2["Player: signs in with User ID and password,<br/>and chooses whether the device stays logged in<br/>ACC-2"]
  t3 --> p2
  p2 --> v3{"service: within the allowance, and the credentials right?<br/>LIMIT-1, LIMIT-2, question 7"}
  v3 -- no --> r3["refused, with one answer for an unknown User ID<br/>and a wrong password"]
  v3 -- yes --> t4["service: session starts, to end at 10 days<br/>or after 48 hours unused (no transition)<br/>ACC-1"]
  t4 --> d2{"Player: an existing account, arrived by an invitation link?"}
  d2 -- yes --> t5["service: invitation Open → Passed to this account<br/>INV-2, INV-3"]
  d2 -- no --> e0((end))
  t5 --> e0
```

### Change my details

```mermaid
flowchart TD
  s0((start)) --> p1["Player: signed in, changes the User ID, the email address or both<br/>ACC-1"]
  p1 --> d0{"service: which?"}
  d0 -- "User ID" --> v1{"service: not blank, and not another account's<br/>ignoring case?<br/>question 6"}
  v1 -- no --> r1["refused, nothing changes"]
  v1 -- yes --> t1["service: User ID changed (no transition)<br/>each game the player is in bumps its version<br/>and is announced; the game holds no copy of the name<br/>71-design.md, the lookup rule"]
  d0 -- "email address" --> v2{"service: not blank, and neither Pending nor Live<br/>for another account?<br/>#439 R3, R7"}
  v2 -- no --> r2["refused, nothing changes"]
  v2 -- yes --> t2["service: new address None → Pending,<br/>verification email sent<br/>#439 R3"]
  t2 --> d1{"Player: verifies the new address within a day?<br/>question 5"}
  d1 -- no --> t3["time: the day lapses<br/>new address Pending → None, the old one stays<br/>#439 R3, question 5"]
  d1 -- yes --> t4["service: new address Pending → Live,<br/>old address Live → None<br/>open invitations to the new one Open → Passed<br/>#439 R3, INV-4"]
  t1 --> e0((end))
  t3 --> e0
  t4 --> e0
  r1 --> e0
  r2 --> e0
```

### Reset my password

```mermaid
flowchart TD
  s0((start)) --> p1["Player: gives the email address of the account"]
  p1 --> v1{"service: within the caller's allowance?<br/>LIMIT-1, LIMIT-2"}
  v1 -- no --> r1["refused, not queued"]
  v1 -- yes --> v2{"service: a Live address of an account? (reads)<br/>#439 R3"}
  v2 -- no --> a1["the same answer is given, and nothing is sent<br/>question 7"]
  v2 -- yes --> t1["service: earlier links stop working, a new link is emailed<br/>(no transition)<br/>question 7"]
  a1 --> e0((end))
  t1 --> p2["Player: follows the link and gives a new password"]
  p2 --> v3{"service: link unused and within its hour?<br/>question 7"}
  v3 -- no --> r2["refused, one answer for unknown, used and expired"]
  v3 -- yes --> t2["service: password changed, link used,<br/>every session ended (no transition)<br/>ACC-1, question 7"]
  t2 --> p3["Player: signs in again, as in Register and sign in<br/>ACC-1"]
  r1 --> e0
  r2 --> e0
  p3 --> e0
```

### Arrange the seats

Sending the invitations is drawn in *Set up a game and fill its seats*.

```mermaid
flowchart TD
  s0((start)) --> c1["Creator: chooses add, remove or swap"]
  c1 --> v1{"service: the creator's game, still Not Started?"}
  v1 -- no --> r1["refused, nothing changes"]
  v1 -- yes --> d0{"which?"}
  d0 -- add --> c2["Creator: names a bot, a player, an email address or an open seat<br/>GAME-4"]
  c2 --> v2{"service: a named player exists?"}
  v2 -- no --> r2["refused, nothing changes"]
  v2 -- yes --> t1["service: seat appended and numbered<br/>a bot's seat Claimed, any other Unsent<br/>the same player or bot may hold several seats<br/>GAME-4"]
  d0 -- remove --> c3["Creator: removes a seat<br/>Unsent, Invited, Declined, Claimed or Withdrawn"]
  c3 --> v3{"service: not the creator's own seat?<br/>question 9"}
  v3 -- no --> r3["refused, nothing changes"]
  v3 -- yes --> t2["service: pending invitation cancelled, seat removed,<br/>later seats renumbered, the seat ceases to exist<br/>INV-7"]
  d0 -- swap --> c4["Creator: swaps two seats"]
  c4 --> v4{"service: every human seat Claimed?<br/>question 9"}
  v4 -- no --> r4["refused, nothing changes"]
  v4 -- yes --> t3["service: the two seats exchange places, and with them turn order<br/>(no transition)"]
  t1 --> t4["service: version bumps, everyone watching is told<br/>(no transition)"]
  t2 --> t4
  t3 --> t4
  t4 --> n0["a game left below two seats waits: it is checked again at the start<br/>GAME-3"]
  n0 --> e0((end))
  r1 --> e0
  r2 --> e0
  r3 --> e0
  r4 --> e0
```

### Take an open seat

```mermaid
flowchart TD
  s0((start)) --> p1["Player: sees games with a seat open to anyone (reads)<br/>question 10"]
  p1 --> p2["Player: accepts the seat, whether or not already seated in that game<br/>GAME-4"]
  p2 --> v1{"service: the game still Not Started,<br/>and the seat still unclaimed?<br/>INV-3, INV-7"}
  v1 -- no --> r1["refused: no longer available, nothing changes"]
  v1 -- yes --> t1["service: seat Invited → Claimed, named for the claimant<br/>version bumps, everyone watching is told<br/>of two at once, one wins<br/>INV-3"]
  t1 --> e0((end))
  r1 --> e0
```

### Ask for a suggested move

```mermaid
flowchart TD
  s0((start)) --> p1["Player: asks for a suggestion on their turn"]
  p1 --> v1{"service: the game Active, and this human seat on turn?"}
  v1 -- no --> r1["refused, nothing changes"]
  v1 -- yes --> v2["service: finds the best-scoring legal move for the rack,<br/>or a pass when there is none (reads)"]
  v2 --> t1["service: plays it as the seat's own move (no transition)<br/>version and turn move, tiles drawn, every client told<br/>question 4"]
  t1 --> v3{"service: does the game end?<br/>GAME-2, as in Take a turn"}
  v3 -- no --> p2["next seat told it is their turn; a bot's turn runs"]
  v3 -- yes --> t2["service: game Finished, ratings settled<br/>RATE-2, RATE-3"]
  p2 --> e0((end))
  t2 --> e0
  r1 --> e0
```

### Chat in a game

```mermaid
flowchart TD
  s0((start)) --> p1["Player: writes a message"]
  p1 --> v1{"service: the caller holds a seat in the game,<br/>and the message is not blank or too long?<br/>question 13"}
  v1 -- no --> r1["refused, nothing changes"]
  v1 -- yes --> t1["service: message recorded, on or off turn, in any game state<br/>version bumps, every client told (no transition)<br/>RET-1"]
  t1 --> e0((end))
  r1 --> e0
```

### Remove a game from my list

```mermaid
flowchart TD
  s0((start)) --> p1["Player: removes a game from their list<br/>DEL-5"]
  p1 --> v1{"service: the game Finished or Aborted,<br/>and the player seated in it or its creator?"}
  v1 -- no --> r1["refused, nothing changes"]
  v1 -- yes --> t1["service: the game is marked hidden for this player alone<br/>(no transition); the game, its seats and every other<br/>player's list are untouched, and it still refers to the player<br/>DEL-5, DEL-2, question 13"]
  t1 --> e0((end))
  r1 --> e0
```

### See my games, ratings and history

```mermaid
flowchart TD
  s0((start)) --> p1["Player: opens their list"]
  p1 --> v1{"service: signed in?<br/>ACC-1"}
  v1 -- no --> r1["refused, asked to sign in"]
  v1 -- yes --> t1["service: finished and aborted games over 7 days old<br/>Over → removed, with their invitations<br/>RET-1, RET-4"]
  t1 --> v2["service: lists the games the player is seated in, was invited to<br/>or created, less those they hid, newest activity first (reads)<br/>DEL-5"]
  v2 --> p2["Player: opens a rating or a rating history, their own or another's (reads)<br/>ACC-3, DEL-10, RET-2, question 14"]
  p2 --> p3["Player: reads times in local time (reads)<br/>CLOCK-4"]
  p3 --> e0((end))
  r1 --> e0
```

### Force-end a game

```mermaid
flowchart TD
  s0((start)) --> a1["Administrator: names a game, on the machine hosting the service<br/>question 11"]
  a1 --> v1{"service: the game exists, and is not already<br/>Finished or Aborted?"}
  v1 -- no --> r1["refused, nothing changes"]
  v1 -- yes --> t1["service: game Not Started or Active → Finished<br/>seats frozen as they stand, a record of the force-end kept<br/>question 11"]
  t1 --> t2["service: no rating changes<br/>RATE-1"]
  t2 --> t3["service: version bumps, every client told (no transition)"]
  t3 --> e0((end))
  r1 --> e0
```

### Delete an account

```mermaid
flowchart TD
  s0((start)) --> a1["Administrator: names an account or gives its id, in the admin CLI<br/>on the machine hosting the service<br/>DEL-1, DEL-9"]
  a1 --> v1{"service: the account exists? (reads)<br/>DEL-8"}
  v1 -- no --> r1["reported as not found"]
  v1 -- yes --> v2{"service: does any game refer to it: created, seated or invited,<br/>in any state, hidden by the player or not? (reads)<br/>DEL-2, DEL-3, DEL-5"}
  v2 -- yes --> r2["refused, naming the games<br/>DEL-6"]
  r2 --> d3{"Administrator: waits, or deletes the blocking games?"}
  d3 -- waits --> w1["Administrator: waits, because every game goes eventually<br/>DEL-4, RET-1, RET-3, TIME-2"]
  d3 -- deletes --> g1["service: each blocking game removed, with its chat,<br/>moves and invitations<br/>any state → removed, question 12"]
  g1 --> a1
  w1 --> a1
  v2 -- no --> v3{"service: a live session? (reads)<br/>question 12"}
  v3 -- yes --> r3["refused until the session ends or the administrator signs it out"]
  r3 --> w1
  v3 -- no --> t1["service: sessions, invitations sent and received,<br/>rating and rating history removed, nothing of anyone else's<br/>address Live → None, account closed<br/>DEL-7, ACC-3, DEL-10"]
  t1 --> e0((end))
  r1 --> e0
```

### Remind the player on turn

```mermaid
flowchart TD
  s0((start)) --> t0["time: the hourly pass looks at each Active game (reads)"]
  t0 --> v1{"service: limit longer than a day, a third of it or less remaining,<br/>and the seat on turn a claimed player not yet reminded this turn?<br/>TIME-4"}
  v1 -- no --> e0((end))
  v1 -- yes --> t1["service: records that this turn was reminded (no transition)<br/>question 13"]
  t1 --> t2["service: emails the player on turn, once, at their Live address<br/>TIME-4"]
  t2 --> e0
```

### Remove expired games

```mermaid
flowchart TD
  s0((start)) --> d0{"time: which game?"}
  d0 -- "ended over 7 days ago" --> t1["service: Over → removed: game, seats, chat, moves and invitations go,<br/>found while the service is in use; rating history stays<br/>RET-1, RET-2, RET-4, ACC-3, DEL-10"]
  d0 -- "not started, idle 7 days" --> t2["time: the creator is asked what to do (not built)<br/>RET-3, question 15"]
  t2 --> c1["Creator: answers delete, keep or nothing<br/>RET-3"]
  c1 --> d1{"answer"}
  d1 -- delete --> t3["service: Not Started → removed, the game goes at once<br/>RET-3"]
  d1 -- keep --> t4["service: counts as activity, thirty days start again (no transition)<br/>RET-3"]
  d1 -- nothing --> t5["time: the countdown carries on, and thirty days after the last activity<br/>Not Started → removed<br/>RET-3"]
  t1 --> e0((end))
  t3 --> e0
  t4 --> e0
  t5 --> e0
```

### Questions the journeys raise

Functional, so answered before the technical decisions:

1. **Aborting changes nobody's rating**, which is what the code does, but
   docs/1.0 does not say so. RATE-1 covers only an administrator's force-end.
   Proposed: a rule beside GAME-1.
2. **Who may force-resign a seat.** Only the creator can today:
   `force_resign_seat` (roster.rs) tests `caller_may_manage_game` (common.rs),
   and no administrator route force-resigns (the admin routes are force-end,
   delete a game, delete an account, sign out and reset a password). For a game
   with no creator the test admits any holder of a claimed seat, or any
   signed-in caller when no seat is claimed, as in an all-engine game. RATE-3
   says how a forced resignation is rated but not who may do it. Options: the
   creator alone, as the code does, or the creator and an administrator, which
   is new work. Proposed: a rule naming whoever is chosen. The use case diagram
   and *Leave a game in play* draw the administrator force-resigning, and change
   to match the answer.
3. **A departing seat's tiles go back to the bag.** The code does this for
   every departure (`finish_via_resignation`, `apply_move_timeout`), but
   docs/1.0 states it only for a timeout (TIME-3). Proposed: one rule for
   every departure.
4. **A suggested move is played, not suggested.** `suggest_move` (games.rs)
   enumerates the legal moves, applies the best-scoring one with
   `apply_place_move` (or `apply_pass` when there is none), runs any bot turns
   and returns the new state. docs/1.0 has no rule for it, and `preview_move`,
   which only reports a candidate's legality and score, has no use case.
   Proposed: decide whether the use case is "play the best move for me" or
   "show me a suggestion". If it plays, a rule says the move is the seat's own
   for scoring and rating; if it only shows, the code changes.
5. **The address rules are not in docs/1.0.** Uniqueness (#439 R2),
   verification, a pending address and its lapse, and activating an account are
   #439's (R3, R7); INV-1 to INV-8 are on `origin/claude/project-thread-hlyj4i`
   and not yet on main. The code differs: `register_player` (auth.rs) creates an
   active account and a session at once and takes any address;
   `update_player_details` (auth.rs:301-303) and `get_player_by_email`
   (persistence.rs:856) say duplicates are allowed, and the former changes the
   address with no check. Unsettled: whether an address is verified by a link or
   a short code (R3 says a short code, and the journeys say only "verifies");
   what becomes of an account whose address lapses unverified; when a
   changed-from address is released, at the change or when the new one is
   verified; and whether sign-in is by User ID or by address, which is open on
   #439. Proposed: address rules in docs/1.0 when #439 lands, settling all four.
6. **A User ID is unique, ignoring case.** `register_player` and
   `update_player_details` refuse a name another account holds, through
   `get_player_by_name` on the folded name. docs/1.0 does not say so. Proposed:
   a rule beside ACC-1.
7. **Sign-in and reset reveal nothing about who has an account, and a reset
   ends every session.** `login_player` gives one answer for an unknown User ID
   and a wrong password; `request_password_reset` answers the same for an
   unknown address; the link works once, within an hour
   (`PASSWORD_RESET_TOKEN_TTL_SECS`), a new request voids older links, and
   `reset_password` and `change_password` end every session. ACC-1 says only
   that signing in starts a new one, and changing a password is in no use case.
   Proposed: rules beside ACC-1, and "Change my password" added to the use
   cases.
8. **Withdrawing from a seat has a lifecycle arrow and no use case.**
   `withdraw_from_seat` (roster.rs) lets the holder of a claimed seat other than
   the creator's give it up before the start. The lifecycle makes `Withdrawn`
   terminal, but the code unclaims the seat and sets its invitation to
   `rejected`, so the creator can send it again. Proposed: a use case, "Withdraw
   from a seat", with its own journey, and the code made to match the spent
   seat.
9. **Roster limits that only the code states.** The creator's own seat cannot
   be removed, withdrawn or force-resigned (`remove_seat`, `withdraw_seat`,
   `force_resign`, game_state.rs); seats can be swapped only once every human
   seat is claimed (`swap_seats`); a named seat for an unknown player is refused
   (`add_seat_to_game`). GAME-3 and GAME-4 are silent. Proposed: one rule for
   the three limits.
10. **A seat open to anyone.** `create_game` and `add_seat_to_game` accept an
    open claim, an invitation with neither a name nor an address has no invitee,
    `list_games` shows every such invitation to every signed-in player
    (`get_open_invitations`, relationship `InvitedOpen`), and
    `claim_invitation` lets the first accepter win. docs/1.0 has INV-2 for a
    link and INV-3 for it working once, and nothing for a seat open to every
    player. Proposed: decide whether the open seat survives D72. If it does, a
    rule says who sees it and that the first to accept wins; if not, the journey
    goes.
11. **An administrator's force-end has no arrow, and only DEL-1 says admin
    actions need the host.** `admin_force_finish` (game_state.rs) takes a game
    `Waiting` or `Active` to `Finished`, so a game never started can finish
    with no racks dealt. The game lifecycle has no arrow for a force-end.
    `require_loopback` (admin.rs) restricts every admin route, while DEL-1 says
    it for deletion alone. Proposed: an arrow from Not Started and Active for
    the force-end, or the code refusing a game not started, and a rule beside
    DEL-1 for the host restriction.
12. **Administrator actions with no use case.** The admin CLI deletes a game
    (`admin_delete_game`, admin.rs:379, `DELETE /admin/games/{id}`), resets a
    player's password (`admin_reset_password`, admin.rs:266) and signs a player
    out (`admin_sign_out_user`). `admin_delete_user` refuses while the account
    has a live session (`has_live_session`) and names signing out as the remedy,
    and for games its refusal says only to wait (admin.rs:159-162), though its
    comment names deleting them first as the alternative (admin.rs:94-96).
    `admin_delete_game` removes a game in any state, Active included, and the
    game lifecycle has no arrow for it, as question 11 finds for a force-end.
    DEL-1 to DEL-10 mention none of this. Proposed: use cases "Delete a game",
    "Reset a player's password" and "Sign a player out" for the administrator,
    a rule beside DEL-2 for the live session, and either an arrow from every
    game state for an administrator's deletion or a refusal to delete a game
    still in play.
13. **Some steps change a game's record and move no seat, and the invariant
    does not treat them alike.** Chat and hiding a game bump the version
    (`mark_changed`), hiding without a broadcast on purpose; the reminder
    (`send_move_time_reminders`, sweeps_game.rs) sets `reminder_sent_turn` and
    saves without bumping it. Only seated players may chat (`post_chat_message`,
    game_state.rs) and the unseated creator may not; the length limit is 1000
    characters. docs/1.0 states neither. Proposed: say beside the "everything
    that changes a game bumps the one version" invariant that per-viewer flags
    and the record of a reminder sent are exempt, and a rule for who may chat.
14. **Who may read a rating.** `get_player_stats` and
    `get_player_rating_history`, and for a bot `get_engine_stats` and
    `get_engine_rating_history` (ratings.rs), require only a signed-in caller.
    ACC-3 says the history belongs to the player and not who may see it.
    Proposed: a rule that any signed-in player may read any player's or bot's
    rating and history.
15. **RET-3 has no definition of "last activity" for a game not started, and
    nothing implements it.** `expire_old_terminal_games` (sweeps_capacity.rs)
    removes only Finished and Aborted games, seven days after `ended_at`;
    `last_activity_by_game` is the latest move, or the creation time when there
    is none, so editing the roster is not activity. RET-3 says it is not built.
    Proposed: define last activity as any change to the game, including roster
    edits, when RET-3 is built.

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
