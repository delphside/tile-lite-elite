# #71 — impact assessment

What the design note beside this one will touch, measured against the code as
it stands. **This is not a second design.** The note decides; this says what
each decision costs, where it lands, and where the change can be cut into
pieces that ship separately.

Measured 2026-08-16 against `main` at `2179771`. Anything not read from the
code today says so.

---

## 1. The code as it stands

For orientation before the detail. Sizes are lines, and they are a fair proxy
for where the work is.

| crate | lines | what it owns |
| --- | --- | --- |
| `server-game` | 19,118 | the game model, persistence, HTTP handlers, sweeps |
| `ui` | 10,985 | the Dioxus client: state, effects, rendering |
| `rules-shared` | 8,397 | board, tiles, dictionaries, word lists |
| `api` | 939 | the wire contract — every DTO, and `API_VERSION` |
| `admin-cli` | 808 | the operator's CLI, compiled into the server image |
| `engine-core` | 503 | move generation and choice |

Inside `server-game`, the parts this change touches:

| file | lines | what it owns |
| --- | --- | --- |
| `game_state.rs` | 2,239 | `GameSession`, `version`, every mutating method |
| `persistence.rs` | 1,676 | SQLite, `snapshot_json`, the invitation tables |
| `app/games.rs` | 998 | game handlers, DTO assembly, broadcasts |
| `app/roster.rs` | 391 | seats: add, remove, swap, withdraw |
| `app/invitations.rs` | 366 | invite, accept, reject — and the current stopgap |
| `app/events.rs` | 105 | the WebSocket, and per-connection redaction |
| `app/tests.rs` | 7,882 | the bulk of the server's tests |

---

## 2. Decision by decision

### One version, moved in one place

**The design**: every change goes through one handler taking a `GameMessage`,
which applies, advances the version, records and broadcasts.

**Measured**: `game_state.rs` has **33 `pub fn`**, of which **17 call
`mark_changed()`**. Those 17 are the candidate message variants, and they line
up closely with the note's enum — turn flow, roster, chat, and the
administrative endings.

The other 16 are readers and helpers, which stay.

**Where the work is**: `game_state.rs` mostly, plus every caller. The handlers
currently call methods directly (`game.remove_seat(n)`), so each call site
becomes a message. *Inferred*: roughly 40–60 call sites across `games.rs`,
`roster.rs`, `invitations.rs`, `admin.rs` and `sweeps.rs` — I counted the lock
acquisitions rather than the method calls, so treat this as an order of
magnitude.

**What it buys, precisely.** Today the coupling between "changed something a
client renders" and "moved the version" is enforced by nothing. Verified:

| write | where | version moves? |
| --- | --- | --- |
| `create_invitation` | `invitations.rs:124` | yes — via `announce_invitation_change` |
| `create_invitation` | `games.rs:283` | yes — creation changes the session anyway |
| `claim_invitation` | `invitations.rs:264` | yes — `claim_seat` bumps |
| `update_invitation_status` → rejected | `invitations.rs:355` | yes — via the stopgap |
| `update_invitation_status` → cancelled | `roster.rs:184` | **rides along** on `remove_seat` at 176 |
| `shift_invitation_seat_numbers_down` | `roster.rs:188` | **rides along** on the same |
| `update_invitation_status` → rejected | `roster.rs:256` | **rides along** on `withdraw_seat` at 243 |

Three of seven are correct by coincidence. `announce_invitation_change` is
defined in `invitations.rs:28` and called **twice**, both in that same module.
The other three modules that touch invitations — `roster.rs`, `games.rs`,
`admin.rs` — never call it.

**And it has already cost us bugs.** `EngineTurnsOutcome { announced }`
(`games.rs:907`) exists solely because the engine loop and its caller both
broadcast the same state at the same `version`, and the client applies an
update only on a strictly greater one (`should_apply_update`,
`ui/src/app.rs:2506`). The second event was always discarded — harmless while
the payloads matched, and the comment in the code names the two bugs it caused
the moment they didn't: the missing rating change, and the blanked-out
`current_rating`. That flag is a workaround for exactly the thing this design
removes; under one write path it deletes itself.

### Per-game locking

**The design**: `HashMap<String, Arc<RwLock<GameSession>>>`.

**Measured**: **35 call sites** take `state.games.read()` or `.write()`, across
six modules — `games.rs` 15, `roster.rs` 6, `admin.rs` 5, `sweeps.rs` 5,
`invitations.rs` 3, `events.rs` 1 — plus **27 more** in `tests.rs` and
`tests_account_lifecycle.rs`. Every one changes shape: today they hold the map
lock and index it; afterwards they take the map lock briefly, clone an `Arc`,
and lock the game.

**What it buys, verified.** `run_engine_turns` (`games.rs:913`) awaits
`maybe_run_engine_turn` *inside* `state.games.write().await`. The lock is
released between turns — deliberately, and the doc comment above it explains
why at length — but a single search holds the map's write lock for its whole
duration, bounded only by `ENGINE_TURN_TIMEOUT` (**5 seconds**). While it runs,
every other game in the process is blocked, including a WebSocket's own read
lock. Per-game locking is the only thing that fixes that, and it fixes it
without touching the engine at all.

This is the most mechanical part of the change and the most widespread. It is
also independently testable — the behaviour should not change at all — which
makes it a good candidate for its own work package.

### Seat state belongs to the seat

**The design**: invitation state moves onto the seat; `game_invitations`
remains the record of who was asked and when.

**Where the work is**: `game_state.rs` (the seat type), `persistence.rs` (the
queries, and `snapshot_json`), plus a migration. `attach_invitation_status`
disappears, and with it the per-read fold in `app/common.rs:42`.

**The cost the note weighed** was the deletion guard —
*which games still mention this player* — cheap in SQL against
`game_invitations`, a scan over `snapshot_json` otherwise. Verified: that query
(`game_ids_mentioning_player`) has **one caller**, `admin_delete_user`, on an
admin path with no latency budget. Worth confirming that is the only cost
before the note's judgement is relied on.

### DTOs are invisible, and redaction is in the model

**The design**: `state → DTO → state'` is an identity, and redaction is
expressed as `SeatRack::Visible(Rack) | Hidden(u8)` rather than by blanking.

**Where the work is**: `api/src/lib.rs` for the types, `app/events.rs:73` for
redaction, and the client for the count display. **This is the change that
moves `API_VERSION` by a major**, because an old client cannot read the new
shapes.

*Worth noting for the plan*: the note calls the opponent tile count "UI work,
not just a data fix" — so this work package has a visible, user-testable component,
where the others largely do not. It is the one that earns a preview pass.

### The engine is a client

**The design**: the engine is told it is its turn and returns a move; the
search runs without holding the lock; the submitted move is re-validated on
arrival.

**Where the work is**: `engine-core` (503 lines) barely changes — the note
says the rules engine, dictionaries, scoring and validation do not change. The
work is in how it is driven, which lives in `games.rs`: `run_engine_turns`
(`:913`), `MAX_ENGINE_TURNS_PER_TRIGGER` (400), `ENGINE_TURN_TIMEOUT` (5s), and
the `engine_limit` semaphore in `app.rs:100` that bounds how many searches run
at once on the two-core production VM.

**Depends on per-game locking**, and gains most of its value from it. Today the
search runs holding the *map's* write lock, so the semaphore is bounding
something the lock has already serialised across games. Per-game locking is
what makes "the engine is a client that takes as long as it takes" true rather
than aspirational; this work package then removes the remaining coupling.

### Migration, and the snapshot schema version

**The design**: existing games are deleted; `snapshot_json` gains a schema
version so this is the last deletion.

**Where the work is**: one migration, and a field in `persistence.rs`. Cheap in
code and irreversible in effect.

**Verified against production, 2026-08-15**: production has six accounts, five
of them real users who are not the owner. So "check nobody else is mid-game"
is now a real check with a real chance of saying no — `sa games list --status
active` before the migration, not as a formality.

### Display name is a lookup, never a copy

**Measured**: `ParticipantState.display_name` (`game_state.rs:202`) and
`ChatMessageRecord.display_name` (`:76`) are both denormalised copies written
into `snapshot_json`; `claim_seat` (`:394`) takes one as an argument.

Removing them touches the DTO assembly in three places that already add
per-read data: `app/common.rs:42` (invitation status), `stats.rs:494` (current
ratings), `app/events.rs:73` (redaction). *Inferred*: display name joins that
set rather than adding a new mechanism.

---

## 3. Where it can be cut

Ordered by dependency. Each is separately testable, which is the property that
matters if this ships in pieces.

**A — per-game locking.** 35 call sites, mechanical, no behaviour change, no
wire change. Testable by the existing suite passing unchanged. Nothing depends
on it being done first except the engine change, and everything is easier
after it.

**B — one version, moved in one place.** The `GameMessage` handler, with seat
state still where it is. Removes the three rides-along coincidences. No wire
change. Testable by a second client seeing every invitation change — the
capability exists now (`startTwoPlayerGame`, `e2e/tests/live.spec.ts`), and the
**four-second window** matters: the games list polls every ten seconds, so a
longer timeout passes against a completely broken implementation.

**C — seat state onto the seat.** Migration, `snapshot_json` shape, the
deletion-guard question. Depends on B being the single write path, or it
multiplies the places to change.

**D — DTOs and redaction.** `SeatRack`, the round-trip property test, the
opponent tile count in the UI. Moves `API_VERSION` by a major. The only work package
with something for a person to look at.

**E — the engine as a client.** Depends on A. Small in `engine-core`, mostly in
how the turn is driven.

**F — the client state model (#157).** `selected_game` as real state, composition
keyed to the game and turn it belongs to, and one transition per invariant. See
*The client has the same defect* in the note. Client-only: no server change, no
API move, no migration, and no dependency in either direction on A–E. It has a
failing test already (`e2e/tests/ui-state.spec.ts`), which makes it the one
work package that can start without anything else moving first.

A, B and F are independent of the design's open questions and useful whatever
the note concludes. They are the natural first work packages — and F is the one to
take first if the point is to get familiar with the parts of the code that were
not written by hand.

---

## 4. What I could not establish

- **The real cost of the deletion guard** against `snapshot_json` rather than
  SQL. A measurement, not a judgement, and it decides whether the note's
  rejected option was rejected for the right reason.
- **Whether any current version comparison is affected by per-viewer
  redaction.** Two clients receive different DTOs from one broadcast; if a
  per-aspect counter were ever introduced it would have to be
  redaction-invariant. Not a problem today — one counter, set before
  redaction — but worth stating before granularity is revisited.
- **The exact call-site count** for the `GameMessage` conversion. I counted
  lock acquisitions (35), not method calls, so the 40–60 estimate above is an
  order of magnitude rather than a number.
