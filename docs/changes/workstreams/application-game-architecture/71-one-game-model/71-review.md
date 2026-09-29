# 71 Review before the owner's read

Claude's review of the five documents in this folder, 2026-09-28, against the
code at `6020e41`, #71's body, and the process as it now stands. The documents
were last changed on 2026-09-02; since then the scheduler (#400), the database
error work (#380, #399), user names (#301), rate limiting and ratings by
edition have landed or been decided.

**The argument of the design holds.** Nothing found here undoes its central
decisions: one version moved by one handler, seat state on the seat, DTOs as an
identity with redaction in the model, the engine as a client, deletion with a
schema version. What has shifted is around it: requirements added to #71 that
the documents do not know about, facts about the code that have moved, and one
document overtaken by the body.

## 1. Requirements #71 has taken that the documents do not cover

None of these appears in `71-design.md` or `71-data-model.md`.

| requirement | #71 allocates it to | what the documents lack |
| --- | --- | --- |
| #253 the schema has no foreign keys | #268 Core | `71-data-model.md` §5 lists the schema changes without `references` clauses; 4.1 notes SQLite needs each table rebuilt to add them, which this migration already does |
| #66 a rating point can link to a swept game | #268 Core | the rating DTO's nullability |
| ratings by edition (owner, 2026-09-26) | #268 Core | `player_ratings` and `rating_history` keyed by edition; bots split the same way. The design separately makes bots accounts and drops `subject_kind`: the two key changes should be designed as one |
| #302 the snapshot has no schema version | #268 Core | argued in the design (*So that this is the last deletion*), absent from the data model's §5 and the snapshot shape |
| #429 the engine concurrency setting is unused | to be allocated | the impact note says `engine_limit` "bounds how many searches run at once"; it bounds nothing, because nothing acquires it. The engine-as-client work decides whether it is used or removed |
| an invitation outlives its game (from #433, 2026-09-28) | to be allocated | aborting leaves invitations pending and accepting one then succeeds. The design's `Abort` message departs every seat but says nothing of pending invitations |

**#439 (Player interactions) overlaps the design.** Its R2 makes an email
address unique and usable for login. The design's *The address invited need
not be the address the account uses* argues an emailed invitation cannot be
resolved to an account by address. Unique addresses change that premise, and
which project decides it, and in what order, is not settled.

## 2. The code has moved under the documents

| document says | now |
| --- | --- |
| `app/sweeps.rs` (268 lines) carries timeouts and retention (data model §6, impact) | split into `sweeps_game.rs` and `sweeps_capacity.rs`; turn expiry and reminders run from the scheduler (`scheduler.rs`, `scheduler_jobs.rs`). The design's rule that sweeps go through `apply` now applies to scheduler jobs |
| "Rate limiting … there is none in place today" (design) | shipped: `throttle.rs`, documented in 4.1 |
| `engine_limit` bounds concurrent searches (impact) | unused (#429); searches are serialised by the games write lock |
| lock sites 35, `pub fn` 33 (impact, measured 2026-08-16) | 37 and 35; the two new lock sites are in `sweeps_capacity.rs`. `mark_changed` is still 17. Close enough for planning |
| file sizes (data model §6, impact) | mostly within a few lines; `app/tests.rs` 8,097 against 7,882 |
| the production account count, "six" (impact, 2026-08-15) | stale by nature; the migration's check is run on the day |

## 3. `71-delivery.md` is overtaken by #71's body

It says two work packages (end to end, and client) in one delivery, with the
requirements #142, #80 and #106 in the first and #105, #152 and #88 in the
second, and with undo (#73) and #157 out of scope. #71's body, split on
2026-09-02, has six packages, from #268 to #272 and #290, that "may ship
separately", with those six requirements "to be allocated" and undo as #272.
Two documents own the deliveries and disagree; the body is the later, and the
one the board reads.

**Suggested**: `71-delivery.md` keeps only what the body does not say (the
migration's cost, `crates/ui` changing in the first package) or is deleted with
the body as the home.

## 4. #157 is closed, but its tests still say it is not fixed

`71-design.md` and `71-impact.md` treat #157 (a staged tile surviving Remove
and Abort) as client work package F, shippable on its own. #157 was closed as
completed on 2026-08-30, by hand, with no milestone and no fixing commit. The
two tests it was meant to turn on, in `e2e/tests/ui-state.spec.ts`, are still
`test.fixme`, with *"Fails today, on purpose … #157 is the fix."* Either the
fix is still owed and #157 closed early, or it was fixed another way and the
tests were never turned on.

## 5. Terms and references that have moved

- The design's opening cites "docs/3.3's rule for a `major-function` change";
  the release queues and that term are retired.
- The impact note's cuts **A to F** use the same letters as the work packages
  **WP A to WP F** for different things (its A is per-game locking, WP A is
  Core Game Lifecycle). Renaming the cuts, or mapping them to packages, avoids
  reading one for the other.
- *Documents this changes* omits 2.3 (the engine interface, most of which the
  engine-as-client change rewrites), 1.1's *Engines* section, and 3.10's
  benchmark path. Its link text for 2.7 is the old title.
- The proposed component diagram draws a CLI client (not planned) and a mobile
  client (now #423's).
- `71-test-approach.md` says `ui-state.spec.ts` is "on this branch"; it is on
  `main`.

## 6. Branch

`290-dioxus-07` (WP F) is five commits ahead of `main`, from the 0.7.1 era. It
will need rebasing onto a `main` that has moved a long way before any work
continues on it.

## 7. Found by the design-reviewer agent's trial (#441)

A second review, by the design-reviewer agent on 2026-09-29 without sight of
the sections above, found everything above except the rate-limiting and
documents-list points, and the following besides. Claude spot-checked three
and they hold.

**More requirements with no design**:

- #87, tell a player a message arrived
- #68, RET-3's countdown
- #142, reconnect catch-up, left open in the data model
- #106, inviting yourself accepts automatically
- #105, withdrawing hides the game at once
- #251, #146, #84 and #313
- #239, which appears only as "not part of the change"

**The design documents contradict each other**:

- the engine seat: 71-design.md removes `SeatKind::Engine` and `engine_id`
  from the seat (bots are accounts); 71-data-model.md keeps `kind` and
  `engine` on `Seat` and `SeatDto`
- the composition key: the design takes a turn number; the data model rules
  the turn out, makes `board_version` the key, then removes `board_version`
  while still using it in five places. Each document says the design wins,
  which picks the key the owner's note of 2026-08-29 rules out
- the client handler: the test approach says a pure `(state, event) → state`
  function; the design and data model say not a reducer
- the test client: compiles against `crates/api` (test approach) or against a
  new `game-wire` crate (data model)
- an aborted game's seats "all end `Departed`", which carries a player, but
  `Unsent` and `Invited` seats have none

**The work packages disagree with the body**: #268 says #253 must not overlap
it, though the body places #253 there; #269 lists #84, #146 and #239, which
the body gives #271; #290 calls itself standalone while titled WP F; #268 says
"first of the five". The body still lists #166 under #270, and #166 is closed.
The body also lacks four of the eight headings CLAUDE.md requires, and carries
the test approach in full as well as linking it.

**Other projects that touch #71**: #402 says "#71 adds a correlation id to
`ApiError`", which #71 does not mention; #408 rewrites `AppState` and the
games map, as per-game locking does, and asks which of memory and database is
the source of truth; #300 expects #71 to build the schema-version dispatch
boundary.

**Code facts, further**: `add_seat_to_game` now refuses an unknown name
(since 2026-08-11), so the design's "the two disagree today" is stale;
`move_number` is already an event sequence; line numbers across the impact
note have drifted.

## 8. Questions for the owner

1. **#157**: is the staged-tile fix still owed? If so it wants reopening, or a
   row in #71.
2. **Ratings by edition and bots as accounts**: design the two changes to the
   rating key together in Core, as suggested above?
3. **#439 and email invitations**: does unique email change the design's rule
   that an emailed invitation binds only on acceptance, and which project
   settles it?
4. **`71-delivery.md`**: trim it to what the body does not say, or delete it?
5. **Scope**: the body's Scope section, `71-delivery.md` and the test approach
   say two packages and one delivery; the body's requirements section says six
   packages that may deliver separately. Which stands?
6. **#402's correlation id on `ApiError`**: a row in #71, or should #402 stop
   claiming it?

The rest, sections 2 and 5 and the missing requirements in section 1, Claude
can apply to the documents once you have read them, on `main`, since the
design folder carries no branch.
