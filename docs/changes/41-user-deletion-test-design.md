# Test design specification — deleting a user, validating against orphaning games

This plan was written as the user test for issue #41. It is incorporated into
the regression tests for the Admin CLI delete-user function, covering the
whole chain of events that function depends on — including game retention,
since a user only becomes deletable once their games have aged out.

## Approach

### What runs

Tests build their own world. Nothing is installed or running first — no
server, no database, no Docker. Each test creates a throwaway SQLite file,
applies migrations, and builds the server in-process — `build_router` gives
the endpoints and the handlers behind them. That is why `cargo test` passes on
a bare CI runner.

```text
  cargo test
      │
      ├── builds ─► target/debug/tile-lite-elite-admin
      │
      └── builds ─► test executable
                        │
                        ├── all but S18  test code ◄─── Request/Response ───► server
                        │                               in-process, no networking
                        │
                        └── S18          test code
                                             │
                                             ├── starts ─► server, listening on 127.0.0.1:PORT
                                             │                     ▲
                                             │                     │ TCP over loopback
                                             └── spawns ─► tile-lite-elite-admin (child process)
```

**Every scenario but S18 hands a `Request` to the server** with `tower`'s
`oneshot`. Routing,
middleware, extractors, handlers and status codes all run. No networking
protocols below HTTP are involved.

**S18 crosses a real process boundary.** The test hosts the server; the CLI is
a separate executable, spawned as a child, dialling over TCP.

Deleting a user is an admin CLI action, and the CLI is the only route to it
for a user in production.
They enter at the endpoint, covering what the server does. S18 covers what
the CLI adds: name resolution, the exit code, the message.

S18 also covers a piece of Axum wiring the other tests cannot reach. Admin
routes are guarded by `require_loopback`, which reads the caller's address
from `ConnectInfo` to check the connection is local to the machine.
`ConnectInfo` is an extractor Axum fills in only when the server is started
with `into_make_service_with_connect_info::<SocketAddr>()`, as `main.rs` does.

`oneshot` never starts a server, so nothing fills it in and the tests insert
an address themselves. That exercises the guard's logic against a value they
chose. S18 starts a real server and lets the kernel report the address, so it
also proves the wiring is still there — remove that line from `main.rs` and
every in-process test still passes while admin breaks in production.

### Manipulating time

`sqlx` writes the timestamp, from inside the test. Two clocks are moved, and
they live in different places:

```sql
update games set ended_at = ?1 where id = ?2

update games set snapshot_json = json_set(snapshot_json,
                                          '$.turn_started_at', ?1)
where id = ?2
```

`ended_at` is a column; `turn_started_at` is a field inside the snapshot, so
backdating a turn is a JSON edit. Reload the game afterwards — the in-memory
copy is the one the sweep reads.

Both sweeps are lazy: they run when a signed-in player lists their games, so a
test triggers either with `GET /games`.

### Where the tests live

These are regression tests which are run by GitHub Actions as part of CI on
every push to GitHub.

| # | test scenario |
| --- | --- |
| S1 | `cannot_delete_a_creator_until_their_unstarted_game_is_swept` |
| S2 | `cannot_delete_a_creator_while_an_invitation_is_outstanding` |
| S3 | `cannot_delete_a_creator_after_an_invitation_is_declined` |
| S4 | `cannot_delete_a_creator_of_a_game_ready_to_start` |
| S5 | `cannot_delete_a_player_seated_in_a_game_in_play` |
| S6 | `cannot_delete_a_player_until_their_finished_game_is_swept` |
| S7 | `cannot_delete_a_creator_who_took_no_seat` |
| S8 | `cannot_delete_a_player_who_resigned_while_the_game_continued` |
| S9 | `cannot_delete_either_player_of_an_aborted_game` |
| S10 | `cannot_delete_a_player_with_an_unanswered_invitation` |
| S11 | `hiding_a_game_does_not_make_its_players_deletable` |
| S12 | `deleting_a_user_removes_their_ratings_and_sessions` |
| S13 | `deleting_an_unknown_account_is_not_found` |
| S14 | `declining_an_invitation_releases_the_account` |
| S15 | `retention_sweeps_games_past_the_window_and_keeps_the_rest` |
| S16 | `retention_keeps_rating_history_when_it_sweeps_a_game` |
| S17 | `every_attachment_blocks_until_its_game_is_swept` |
| S18 | `deleting_a_user_through_the_cli` |
| S19 | `a_game_in_play_ends_itself_when_the_clock_runs_out` |
| S20 | `a_timed_out_seat_leaves_the_others_playing` |

Every scenario but S18 goes in a new module,
`crates/server-game/src/app/tests_user_deletion.rs`.
It must be in-module: backdating needs `state.db`.

S18 goes in `crates/admin-cli/tests/user_deletion.rs`. It must be there:
`cargo test` builds the package's binaries and supplies their paths as
`CARGO_BIN_EXE_<name>`, which is set only for tests in the package that
defines the binary. The binary is always freshly built, with no install step.
`admin-cli` gains a dev-dependency on `server-game` so the test can host a
server.

Payloads are the `api` crate's own request types, so a wire change breaks the
tests at compile time. Shared setup goes in helpers: `register_player` exists;
`create_waiting_game`, `finish_game_by_resigning` and `backdate_game` to add.

Everything runs with one command:

```bash
cargo test --workspace
```

## The rules being tested

Everything below is derived from these. They are statements of intent, not
descriptions of the current code — check them first, because an error here
becomes an error in every test that follows.

- **R1** A user cannot be deleted while any game refers to them, whether as its
  creator or as the holder of a seat, whatever state that game is in and
  whether or not they have left their seat.
- **R2** A refusal names the games responsible, so the admin knows what to
  deal with.
- **R3** Deleting a user removes everything personal to them — sessions,
  invitations, current rating, rating history — and touches nobody else's.
- **R4** Rating history outlives the game that produced it. It is personal to
  the player, so it goes when they do, but not when their games do.
- **R5** A game is deleted 7 days after it finishes or is aborted. One that
  never started is deleted 30 days after its creator last asked to keep it,
  asked at 7 days — not built, so O14 asserts the gap rather than the rule.
- **R6** An invitation the player has not answered refers to them, so R1
  refuses. Declining answers it. This holds because every game goes eventually
  and takes its invitations with it — an unanswered one lives only on a game
  that never started, which R5 covers once it is built.
- **R7** Removing a game from your own list hides it from you. The game still
  exists and still refers to you, so R1 still refuses.
- **R8** Deleting an account that never existed is reported differently from
  refusing to delete one that does.
- **R9** The CLI accepts a display name or an account id, and reports a
  refusal with a non-zero exit and a message saying what to do.

R1 is the one to challenge. It is deliberately blunt: the alternative is
deciding, per game state, whose history may be half-owned by an account that
no longer exists.

## Conditions

### Simple

*One fact each, grouped by what they vary.*

A group marked **complete** is a partition: its values exclude each other and
between them cover every possibility, so every scenario takes exactly one.
That is what makes covering the group mean something — a value nobody uses is
a real gap rather than a wording choice.

**Did the player create the game?** Complete.

| # | condition |
| --- | --- |
| C1 | created it |
| C2 | did not create it |

**What seat does the player hold?** Complete.

| # | condition |
| --- | --- |
| C3 | one they still hold |
| C4 | one they have given up |
| C5 | none |

**What invitation does the player hold?** Complete.

| # | condition |
| --- | --- |
| C6 | none |
| C7 | one they have not answered |
| C8 | one they declined |

**What situation is the game in?** Complete, taking the first that applies —
a roster can carry a declined invitation and an outstanding one at once, so
they are ordered by how far the game has got rather than left to overlap.

| # | condition |
| --- | --- |
| C9 | unstarted, every seat claimed and ready to start |
| C10 | unstarted, an invitation outstanding |
| C11 | unstarted, an invitation declined and none outstanding |
| C12 | unstarted, no invitation ever sent |
| C13 | in play |
| C14 | finished |
| C15 | aborted |
| C16 | swept, and no longer exists |

**How long since the game ended?** Complete where C14 or C15 holds, and not
applicable otherwise.

| # | condition |
| --- | --- |
| C17 | more than seven days |
| C18 | less than seven days |

**Has the seat on turn run out of time?** Complete where C13 holds, and not
applicable otherwise.

| # | condition |
| --- | --- |
| C26 | it has exceeded the move time limit |
| C27 | it is within the move time limit |

**How is the delete invoked?** Complete.

| # | condition |
| --- | --- |
| C19 | by display name |
| C20 | by account id |

**On their own**, each true or absent rather than one of a set:

| # | condition |
| --- | --- |
| C21 | player has removed the game from their own list |
| C22 | game carries rating history for the player |
| C23 | player has no game of any kind |
| C24 | the player id does not exist |
| C25 | a second, unrelated player exists with their own data |

### Complex

*Every way a player can still be attached to a game. R1 says each one refuses.*
*∅ marks a combination that cannot arise.*

| player's relationship | unstarted | in play | finished | aborted | swept |
| --- | --- | --- | --- | --- | --- |
| created it, holds a seat | X1 | X2 | X3 | ∅ | ∅ |
| created it, gave up its seat | ∅ | X4 | X5 | X6 | ∅ |
| created it, never took a seat | X7 | X8 | X9 | X10 | ∅ |
| joined it, holds a seat | X11 | X12 | X13 | ∅ | ∅ |
| joined it, gave up its seat | ∅ | X14 | X15 | X16 | ∅ |
| invited to it, has not answered | X17 | ∅ | ∅ | X18 | ∅ |
| neither created nor joined it | ∅ | ∅ | ∅ | ∅ | ∅ |

A seat can only be given up once play has begun, which empties the `Waiting`
column for both rows that need one. Aborting gives up every seat at once, so
the two rows that hold one are empty under `Aborted`. Sweeping deletes the
game, so the last column is empty however the player was attached — which is
what eventually makes them deletable, and what S11 walks through.

C11 cuts across the whole table: a hidden game occupies the same cell as a
visible one, because hiding changes nothing about the attachment.

The unstarted column stands for all four of C9 to C12. They differ in who is
waiting for whom, not in who is attached, so a creator occupies the same cell
whether nobody was invited or everybody has accepted — which is why S1 to S4
share one and are told apart by their conditions.

An unanswered invitation keeps its game unstarted, because no game can start
with a seat unfilled, so that row is empty under *in play* and *finished*. It
survives an abort, which needs no seats filled, so *aborted* is not.

## Outcomes

*What must be observable afterwards.*

| # | outcome |
| --- | --- |
| O1 | delete is refused with 400 |
| O2 | the refusal names the games blocking it |
| O3 | delete succeeds with 204 |
| O4 | 404, distinguishable from a refusal |
| O5 | the user's sessions are gone and their tokens rejected |
| O6 | the user's invitations, sent and received, are gone |
| O7 | the user's `player_ratings` row is gone |
| O8 | the user's `rating_history` rows are gone |
| O9 | the unrelated user's data is unchanged |
| O10 | a finished game is deleted from the database |
| O11 | a finished game is retained |
| O12 | a swept game stops appearing to the players who were in it |
| O13 | rating history survives the sweep of its game |
| O14 | a waiting game is retained — no rule covers it yet |
| O15 | the CLI exits non-zero with a message saying what to do |
| O16 | display name and id resolve to the same account |
| O17 | the game survives, and its creator is unaffected |
| O18 | the overdue seat is retired and its tiles are back in the bag |
| O19 | the game finishes once one seat is left playing |
| O20 | the game carries on while two or more seats are still playing |

## Scenarios

### Refused, then swept, then deleted

Every row here walks the same path: build the attachment, **delete** and watch
it refused, bring the game to an end if it has not reached one, backdate it
past the window, trigger the sweep with `GET /games`, then **delete** again and
watch it succeed.

So C14 or C15 applies to every row by the end, along with C17 and C16, and
every row asserts O1 and O2, then O10 and O3. The columns carry only what
distinguishes one row from another.

| # | who is deleted, and what attaches them | how the game reaches an end | conditions |
| --- | --- | --- | --- |
| S1 | Alice, who created a `Waiting` game, holds a seat, and has invited nobody | she aborts it | X1, C12 |
| S2 | Alice, the same but with Bob invited and yet to answer | she aborts it | X1, C10 |
| S3 | Alice, the same but with Bob invited and having declined | she aborts it | X1, C11 |
| S4 | Alice, the same but with every seat claimed and the game ready to start | she aborts it | X1, C9 |
| S5 | Bob, who joined Alice's game and holds a seat in play | Alice force-ends it | X12 |
| S6 | Alice, who created a game and holds a seat in it; it finished yesterday | already ended | X3, C18 |
| S7 | Alice, who created a bot-versus-bot game and took no seat | the bots play it out | X8 |
| S8 | Bob, who joined a three-player game and resigned while the others played on | the others play it out | X14 |
| S19 | Alice, seated in a two-player game whose turn clock has run out | it times out on its own | X3, C26 |
| S20 | Bob, who joined a three-player game and whose turn clock ran out while the others played on | the others play it out | X14, C26 |
| S9 | Alice, then Bob, whose seats were both given up when Alice aborted the game | already ended | X6, X16 |
| S10 | Bob, invited to Alice's `Waiting` game and yet to answer | Alice aborts it | X17, C7 |
| S11 | Alice, then Bob, who have both removed a finished game from their lists | already ended | X3, X13, C21 |

S19 and S20 are the pair that proves a game in play resolves itself: nobody
resigns, nobody aborts, and the game reaches an end anyway. S19 adds O18 and
O19, S20 adds O18 and O20 — and S20 lands in the same cell as S8, reached by
the clock rather than by choice.

S1 to S4 take C12, C10, C11 and C9 — the four situations an unstarted game
can be in. The
refusal is the same in all four, which is the point: it does not care how far
the game got.

### Deleting when no game is in the way

| # | scenario | conditions | outcomes |
| --- | --- | --- | --- |
| S12 | Carol has never created or joined a game; **delete Carol** | C23, C25 | O3, O5, O6, O7, O8, O9 |
| S13 | **Delete an account id that has never existed** | C24 | O4 |
| S14 | Alice invites Bob, who declines; **delete Bob** with the game still there | C8, C11 | O3, O17 |

### The sweep on its own

| # | scenario | conditions | outcomes |
| --- | --- | --- | --- |
| S15 | Three games — finished 8 days ago, finished 6 days ago, still unstarted; **trigger the sweep** | C14, C17, C18, C12 | O10, O11, O12, O14 |
| S16 | Alice and Bob finish a rated game, backdated 8 days; **sweep**, then read Alice's rating history | C14, C17, C22 | O10, O13 |

### Everything, and the real binary

| # | scenario | conditions | outcomes |
| --- | --- | --- | --- |
| S17 | For each cell of the complex-conditions table in turn, walk the whole path: attach, **delete** refused, end the game, backdate, sweep, **delete** succeeds | X1–X18 | O1, O2, O10, O3 |
| S18 | Through the real CLI binary: **delete Alice by display name** while she is the creator of a unstarted game (refused), delete the game, **delete Alice by account id** | X1, C23, C19, C20 | O1, O3, O15, O16 |

Every scenario but S18 is an integration test; S18 is the script.

## Coverage

**Simple**: C1 S1–S4, S6, S7, S9, S11, S18 · C2 S5, S8–S11, S14 · C3 S1–S6,
S11 · C4 S8, S9 · C5 S7 · C6 S1, S4–S9, S11 · C7 S10 · C8 S14 · C9 S4 · C10 S2
· C11 S3, S14 · C12 S1, S15 · C13 S5, S7, S8 · C14 S6, S11, S15, S16 · C15
S1–S4, S9, S10 · C16 S1–S11, S17 · C17 S1–S11, S15–S17 · C18 S6, S15 · C19 S18
· C20 S18 · C21 S11 · C22 S16 · C23 S12, S18 · C24 S13 · C25 S12 · C26 S19,
S20 · C27 S5, S7, S8 — all 27 covered, and every complete group has every
value used.

**Complex**: S17 covers all eighteen, each through the full walk. Named
scenarios cover ten individually — X1 S1–S4, S18 · X3 S6, S11 · X6 S9 · X8 S7
· X12 S5 · X13 S11 · X14 S8 · X16 S9 · X17 S10 — and earn their place by
asserting more than the refusal: an unrelated account left alone, the wording
of the message, the CLI's own behaviour, a hidden game still counting, the
four situations an unstarted game can be in.

**Outcomes**: O1 S1–S11, S17–S20 · O2 S1–S11, S17, S19, S20 · O3 S1–S12, S14,
S17–S20
· O4 S13 · O5 S12 · O6 S12 · O7 S12 · O8 S12 · O9 S12 · O10 S1–S11, S15–S17, S19, S20 ·
O11 S15 · O12 S15 · O13 S16 · O14 S15 · O15 S18 · O16 S18 · O17 S14 · O18 S19, S20 · O19 S19 · O20 S20 — all 20
covered.

## Notes

**Every refusal is followed by a success.** A test that only proves deletion is
refused would pass just as well against a guard that refuses everything. Each
walk ends by removing the reason and showing the delete goes through, so the
refusal is pinned to the attachment rather than to the account.

**That puts the sweep under test too.** The middle of every walk is a real
sweep removing a real game, so a retention bug fails these tests rather than
waiting to be noticed in production.

**S1 to S4 exist because the four situations look different to a user.** A
game nobody was invited to and a game everyone has accepted are not the same
thing to the person who built the roster. The rule treats them alike, which is
worth asserting rather than assuming.

**S11 is the one a user would trip over.** Removing every game from your list
empties it, so the account looks unattached from the outside while still being
refused. Nothing else would notice if hiding started detaching.

**S14 is the only delete that succeeds with a game still standing.** It is the
pair to S10: same two players, same game, differing only in whether Bob
answered. Asserting the game survives matters because a deletion that took it
along would still return 204.

**O14 asserts an absence, not a rule.** R5's unstarted-game countdown is
decided but not built, so S15 holds the current behaviour in place until it
is. It fails the day the keep prompt lands, which is the reminder to come back
here — and S1 to S4 will need their aborts replaced by the countdown.

**S19 and S20 close an assumption.** Leaving a game in play out of retention
rests entirely on the move timeout firing — the argument in 2.4 is that every
game carries a limit, so an active game becomes a finished one within weeks
and the seven-day rule takes it from there. Nothing tested that the timeout
fires at all.

**O9 is the one most easily lost.** Deleting one account must not touch
another's data, and nothing else would notice if it did.

**O13 is a regression guard.** Retention deleted rating history until
2026-08-03, silently, for weeks.

**O2 is separate from O1 deliberately.** Eleven walks expect the same 400.
Without asserting the message names the games, all of them pass on a refusal
that tells the operator nothing.

## Test procedures

Written when the plan was run, and kept because they are what a rerun by
hand follows. One per scenario, in plain steps.

---

### S1 — Alice creates a game that stays `Waiting`; delete Alice, its creator

1. Register Alice. Register Carol, who is unrelated and must be untouched.
2. As Carol, note her session token works and record her account row.
3. As Alice, create a game seating herself and one open seat. It stays
   `Waiting`.
4. As admin, over loopback, `DELETE /admin/users/{alice}`.
5. Expect **400**, and the body to contain the game's id.
6. Confirm Alice still exists and her session token still works.
7. Confirm Carol's account and session are unchanged.

### S2 — Alice and Bob play an `Active` game; delete Bob, seated in it

1. Register Alice, Bob and Carol.
2. As Alice, create a game seating herself and inviting Bob by name.
3. As Bob, accept the invitation.
4. As Alice, start the game. Confirm it is `Active`.
5. As admin, `DELETE /admin/users/{bob}`.
6. Expect **400** naming the game.
7. Confirm Carol is unchanged.

### S3 — a game finished yesterday; delete Alice, seated in it

1. Register Alice.
2. As Alice, create a two-seat game against an engine and start it.
3. As Alice, resign. With one seat left the game becomes `Finished`.
4. Backdate `games.ended_at` to 24 hours ago — inside the 7-day window, so
   the sweep leaves it.
5. As admin, `DELETE /admin/users/{alice}`. Expect **400** naming the game.

### S4 — Alice creates and seats Bob; delete Bob, seated but not creator

1. Register Alice and Bob.
2. As Alice, create a game seating herself and inviting Bob by name.
3. As Bob, accept. Leave the game `Waiting`.
4. As admin, `DELETE /admin/users/{bob}`. Expect **400** naming the game.

### S5 — Alice creates a bot-vs-bot game, taking no seat; delete Alice

1. Register Alice.
2. As Alice, create a game with two engine seats and none for herself — the
   Bot Showdown shape. Confirm no participant carries Alice's id.
3. As admin, `DELETE /admin/users/{alice}`.
4. Expect **400**: she is the creator even though she holds no seat.

### S6 — Carol played a game which has since been swept; delete Carol

1. Register Carol and Dave, who is unrelated.
2. As Carol, play a game against an engine through to a finish.
3. Confirm Carol now has a `player_ratings` row and `rating_history` rows.
4. Backdate `games.ended_at` to 8 days ago.
5. Trigger the sweep with `GET /games` as Dave. Confirm the game is gone and
   Carol's rating history survives it.
6. As admin, `DELETE /admin/users/{carol}`. Expect **204**.
7. Confirm: Carol's session token is now rejected; her `player_ratings` row
   is gone; her `rating_history` rows are gone.
8. Confirm Dave's account, session and ratings are unchanged.

### S7 — delete an account id that has never existed

1. As admin, `DELETE /admin/users/00000000-0000-0000-0000-000000000000`.
2. Expect **404**, distinct from the 400 a refusal gives.

### S8 — the retention boundary

1. Register Alice.
2. Create three games: one finished, one finished, one left `Waiting`.
3. Backdate the first to 8 days ago and the second to 6 days ago.
4. Trigger the sweep with `GET /games`.
5. Confirm the 8-day game is gone from the database **and** from the
   in-memory map; the 6-day game remains; the waiting game remains.

### S9 — an aborted game ages out

1. Register Alice. Create a game and abort it.
2. Backdate `ended_at` to 8 days ago.
3. Trigger the sweep. Confirm it is gone — aborted games age out like
   finished ones.

### S10 — rating history survives its game

1. Register Alice and Bob. Play a rated game to a finish.
2. Record Alice's rating history — expect at least one point.
3. Backdate `ended_at` to 8 days ago and trigger the sweep.
4. Confirm the game is gone and Alice's rating history is **unchanged**.

### S11 — refusal, then the same delete succeeds

1. Register Alice. Play a game against an engine to a finish.
2. As admin, `DELETE /admin/users/{alice}`. Expect **400**.
3. Backdate `ended_at` to 8 days ago; trigger the sweep.
4. As admin, `DELETE /admin/users/{alice}` again. Expect **204**.

Proves the refusal reflects current state.

### S12 — the operator's run-through, through the real CLI

1. Bind the server to `127.0.0.1:0` and note the port.
2. Register Alice over HTTP. As Alice, create a game.
3. Run `tile-lite-elite-admin --server http://127.0.0.1:PORT users delete Alice`.
4. Expect a non-zero exit, and a message naming the game and saying what to do.
5. Run `... admin games delete {game_id}`.
6. Run `... users delete {alice_account_id}` — by id this time.
7. Expect success, and `users list` no longer showing Alice.

Covers what the endpoint tests cannot: the CLI resolving a display name and
an id, its exit code, and its message.

---

## Findings from running it

**O6 — "the user's invitations are gone" — is unreachable.** `delete_game`
runs `delete from game_invitations where game_id = ?`, so once a user has no
games, which deletion requires, their invitations are already gone. The
invitation-deleting statement in `delete_player` can never fire. Drop the
outcome, and decide whether that statement stays as defence.

**S6 needs Carol to have played.** A `player_ratings` row only appears when a
rated game finishes, so a user who never played cannot demonstrate its
removal. Carol plays, the game is swept, then she is deleted — which is also
the realistic path, since deleting a user is part of clearing old data.

**Retention keeps a player's rating history; deleting the player removes it.**
Both are right — the history belongs to the player, not the game — and S10
and S6 assert opposite halves. Easy to "tidy" one to match the other and
break it.
