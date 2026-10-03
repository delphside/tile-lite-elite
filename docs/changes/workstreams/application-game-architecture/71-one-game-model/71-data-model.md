# 71 Data model, modules and message flows

**The shapes behind [`71-design.md`](71-design.md).** That note argues what
must be true; this says what is written. Nothing here overrides it — where they
differ the note wins and this is wrong.

**Everything below is proposed, not built.** Types are given as they would be
written, so that reviewing them is reviewing the design rather than a summary
of it.

## What exists today, for comparison

| | today | after |
| --- | --- | --- |
| the domain seat | `ParticipantState` — 11 flat fields, `resigned: bool`, `rack: Rack` always present | `Seat` — a state enum carrying what that state has |
| a seat's invitation | folded on every read from `game_invitations` rows | a field on the seat |
| freshness | `version: i64` on `GameSession`, moved by whoever remembers | moved by one handler, which is the only writer |
| the turn | `turn_number: i64`, doubling as a version | `turn` and `version` are separate counters |
| the client's rack | `racks: Vec<RackDto>`, a hidden rack sent as an empty one | `SeatRack::Hidden(u8)` on the seat |
| a display name | copied into `ParticipantState` and `snapshot_json` | resolved when the DTO is built |
| who may see what | `ViewerAccess::{Rejected, Creator, Participant{seat}}` — one seat | the set of seats an account holds |
| engine turns | `run_engine_turns` loops to `MAX_ENGINE_TURNS_PER_TRIGGER` holding the write lock | a task per turn, holding nothing while it thinks |
| the games map | `HashMap<String, GameSession>` under one `RwLock` | `HashMap<String, Arc<RwLock<GameSession>>>` |

## 1 · Domain types

### The seat

`ParticipantState` is replaced. The fields that survive do so because they are
true of every seat in every state; the rest move into the state that owns them.

```rust
pub struct Seat {
    pub number: u8,
    pub kind: SeatKind,                   // Human | Engine, as today
    pub player: Option<PlayerId>,         // resolved when the seat is created
    pub engine: Option<EngineId>,
    pub invitation: Option<Invitation>,   // fixed at creation; None for own seat and bots
    pub state: SeatState,
    pub hidden_by_player: bool,           // "removed from my list" — per seat, not per game
    pub reminder_sent_turn: Option<i64>,
}
```

`display_name` is gone — that is the lookup rule. `resigned: bool` is gone:
`SeatState::Departed { how: Departure::Resigned, .. }` says it, and says which
of the three ways it happened. `score` and `rack` move inside the states that
have them, which is what stops a `Claimed` seat carrying a rack it cannot have.

`SeatState`, `Invitation`, `Departure` and `SeatRack` are as
[`71-design.md`](71-design.md) gives them, and are not repeated here.

### The session

```rust
pub struct GameSession {
    pub id: GameId,
    pub status: GameStatus,
    // …variant, language, board_layout, rules, state, bag, moves, messages,
    //   consecutive_scoreless_turns, move_time_limit_seconds, turn_started_at
    //   are unchanged…
    pub seats: Vec<Seat>,                 // was `participants: Vec<ParticipantState>`
    pub current_seat: u8,
    pub turn: i64,                        // was `turn_number`; game state, walks back under undo
    pub version: i64,                     // every change, of any kind. Never decreases
    pub board_version: i64,               // the `version` at which the board last changed
    pub last_scoring_turn: i64,           // see "Deriving beats accumulating"

}
```

**Three counters, and only one of them is monotonic.** Corrected 2026-08-29;
an earlier draft of this section had two and used `turn` as the composition
key, which undo breaks.

| | what it counts | monotonic? |
| --- | --- | --- |
| `version` | every change a client can see, including chat and a rename | **yes, always** |
| `turn` | turns taken since the game started — **game state** | **no**: undo takes it back, redo returns it |
| `board_version` | the `version` at which the board last changed | **yes** |

Owner, 2026-08-29: *"turn is part of game state, how many turns have been taken
since the game started. As you know we intend to introduce undo/redo, so turn
could go backwards. Version always increments."*

**So `turn` cannot key the composition**, and the reason is the one this note
already gives for `version` being a counter rather than a description: a game
can **return to a value it already held**. Undo to turn 7, redo to turn 8, and a
composition staged at turn 8 before the undo matches again — against a board
that is no longer the one it was composed on. That is the same silent-wrong-
answer this whole note exists to remove, reintroduced by the key I chose.

**`board_version` is the key**: the version at the moment the board last
changed. It is a `version`, so it never repeats; it moves only when the board
does, so an opponent's chat leaves a half-typed word alone; and undo *does*
move it, because undo changes the board and produces a new higher version.

```rust
pub struct CompositionKey {
    pub game: GameId,
    pub board_version: i64,   // not `turn` — turn repeats, this cannot
    pub seat: u8,
}
```

**One field, and it costs nothing to maintain**: `apply` sets
`board_version = version` in the arms that touch the board — `Place`, `Pass`,
`Exchange`, and undo — and leaves it alone in the others. It is the one place
that could be forgotten, which is why it belongs inside the single handler
rather than anywhere else.

**Undo increments `board_version`; it does not restore it.** Asked directly,
2026-08-29, and worth stating because the opposite is the natural thing to
write: *"if there is an undo the board version would increment rather than
return to what it had been?"* It increments.

```text
turn 8, board_version 41   a word is staged, keyed on 41
undo                        turn 7, board_version 42   ← new, higher
redo                        turn 8, board_version 43   ← new again
```

The board at `board_version 43` is byte-for-byte the board at 41. **The number
is not**, and that is the point: the staged word is discarded at the undo and
stays discarded through the redo, because it was composed against a board the
player has since moved away from and back to. A key that restored to 41 would
resurrect it.

This is the note's own rule about `version` — *"a game can return to a state it
already held, so anything derived from state repeats and a client comparing
with `>` silently ignores the update"* — applied one level down. `turn` is a
description of the game and repeats; `board_version` is an identifier for *when
the board was last set* and cannot.

**So restoring it would be the bug**, and it is the plausible mistake: undo
restores the board, and restoring the field that describes the board looks
consistent. It is not. Undo restores **content**; versions only ever count
**changes**, and an undo is a change.

### Which changes move which counter

Asked 2026-08-29: *"if a player passes then the turn will increment, the version
will increment: will the board version increment?"* No.

| change | `version` | `turn` | `board_version` |
| --- | --- | --- | --- |
| a word placed | ✓ | ✓ | ✓ |
| a pass | ✓ | ✓ | — |
| an exchange | ✓ | ✓ | — |
| a chat message | ✓ | — | — |
| an invitation sent, accepted, declined | ✓ | — | — |
| a rename (`UpdateUserDetails`) | ✓ | — | — |
| a resignation, force-resign, timeout | ✓ | — | — |
| undo, redo | ✓ | ✓ back / ✓ forward | ✓ |
| a seat added, removed, reordered | ✓ | — | — |

**A pass leaving `board_version` alone is the useful case**, not an edge one: a
word staged while waiting survives an opponent's pass, because the board it was
composed against is unchanged. Under `turn` as the key it would have been
discarded for nothing.

### Three categories of change

Owner, 2026-08-29: *"pass and exchange do move the game state on, especially
exchange, as does resign. So we just need to be clear what is affected and what
we are interested in."*

| category | what is in it | changed by |
| --- | --- | --- |
| **board** | the tiles played on the board, and nothing else | a placement; undo or redo of one |
| **the game** | the board, plus racks, scores, the turn, resignations and timeouts | everything above, plus pass, exchange, resign, force-resign, timeout, start, abort |
| **periphery** | chat messages | posting a message |

**Only two counters exist**, and the categories are not a third and fourth.
`version` moves for all three categories — it answers *is what I hold stale*.
`board_version` moves for the first — it answers *is a staged word still
placeable*. Nothing needs a counter for the middle category, because a client
that hears anything at all replaces the whole state.

**What the categories are for is deciding what to do**, and that is a property
of the **event**, not of a counter. The envelope already carries it —
`State { game, because: Option<GameEventDto> }` — so a client classifies the
event rather than comparing numbers:

| the client is told | it does |
| --- | --- |
| a **board** event | redraw the board; a staged word is void, and the `board_version` check has already discarded it |
| a **game** event | redraw the panes — racks, scores, whose turn. Notify if it is now this player's turn |
| a **periphery** event | a chat badge. Nothing else moves |
| **nothing** — a refetch or a reconnect | rebuild everything, because there is no event to classify |

**Exchange is the case that proves the categories are not the counters.** It
changes the game and not the board: `version` moves, `turn` moves,
`board_version` does not. A staged word survives it — correctly, since the board
is unchanged — but the *exchanging seat's* rack does not, which is why the rack
is checked separately below rather than folded into `board_version`.

**And it is why `board_version` is named for the board rather than for play.**
An earlier draft of this document used it for both jobs, which would have
discarded a staged word every time an opponent passed.

### Staged tiles are displaced by occupancy, not by change

Owner, 2026-08-29: *"on staged tiles, they only need to be displaced if a tile
is played in the same cell."*

That is narrower than anything above, and it removes the field. A staged word
does not care that the board changed; it cares whether **its own cells** are
still free. An opponent playing in the far corner takes nothing away.

So there is no board counter in the composition key at all:

```rust
pub struct CompositionKey {
    pub game: GameId,
    pub seat: u8,
}

fn live_composition(&self) -> Option<Composition> {
    let game = self.cache.peek().as_ref()?;
    let c    = self.composition.peek().clone()?;
    (c.key.game == game.id
        && c.staged.iter().all(|s| game.board[s.index].letter.is_none())
        && staged_tiles_still_held(&c, game))
        .then_some(c)
}
```

**Both conditions are comparisons against the state the DTO already carries** —
the cells are empty, the tiles are still in the rack. Nothing is stored, nothing
is bumped, and nothing can be forgotten in a handler. This is the third time in
this document that deriving has beaten a counter, and the first where it removes
one already proposed.

**`board_version` therefore goes.** It was invented two revisions ago to key the
composition, survived one narrowing when a pass turned out not to move it, and
does not survive this one. `version` and `turn` remain; the schema and the DTO
lose a column and a field.

**Validity is a separate question from survival**, and conflating them would
throw work away. An opponent playing *adjacent* to a staged word leaves its
cells free but may make the word illegal — a cross-word that no longer exists,
or a connection that has become something else.

| | |
| --- | --- |
| the cells are taken | the tiles come back to the rack. There is nowhere for them to be |
| the cells are free but the word is now illegal | **the tiles stay**, and the client says so |

The client already runs the rules engine — `client_rules.rs` validates and
scores before sending — so it can re-validate on every board change and mark the
word rather than silently dismantling it. Losing a half-built word because
somebody played elsewhere is exactly the behaviour this design exists to remove.

### Three tile states, and all three already exist

Owner, 2026-08-29: *"we will need to make sure that staged, just played, and
previously played tiles are easily distinguished"*, and *"we currently
distinguish tile played in the last move."*

Both are true, and this is a **requirement to preserve rather than to build**.
An earlier revision of this section said the board could draw only two states,
from reading the tile-face classes alone. The third is on the **cell**:

| state | drawn as | driven by |
| --- | --- | --- |
| **staged** | `tile-face tile-face-staged` | the composition |
| **just played** | `board-cell-last-move` on the cell | `last_move_cells: HashSet<usize>` |
| **previously played** | `tile-face` | the board |

So what this change owes is that all three survive it. Two things put that at
risk, and neither is obvious from the type definitions:

**`last_move_cells` is computed from the DTO's move list.** Once
`MoveRecordDto.description` becomes structured and the seat model changes, the
computation has to be checked rather than assumed — it is exactly the kind of
derived value that keeps working until it quietly does not, and nothing
currently asserts it.

**The staged state must survive board changes that do not touch its cells.**
That is the section above, and it interacts here: under the current *clear on
any change* behaviour the staged class simply disappears, which no test would
notice because disappearing is what it is supposed to do eventually.

### An enhancement this makes cheap, not part of the change

*"Just played"* means the **last move**. A player returning after several moves
sees only the most recent one highlighted, and what they actually want is
everything that happened while they were away.

The client knows the version it held before the update — `should_apply_update`
compares against it — so *"since the version I last held"* is derivable, **if
move records carry the version they happened at**:

```rust
pub struct MoveRecordDto {
    pub version: i64,      // new — which version this move produced
    // …the rest as today; `description` becomes structured…
}
```

One field, no server state, and the log wants it anyway. Worth listing
separately rather than folding in: it is a change to what a player sees, and it
should be somebody's decision rather than something that arrives with a
refactor.

### What `board_version` did not cover

The design note sets the requirement as *"same game, still this player's turn,
same board underneath"*. `board_version` answers the third. The other two are
comparisons against current state rather than parts of the key:

```rust
fn live_composition(&self) -> Option<Composition> {
    let game = self.cache.peek().as_ref()?;
    let c    = self.composition.peek().clone()?;
    (c.key.game == game.id
        && c.key.board_version == game.board_version
        && staged_tiles_still_held(&c, game))
        .then_some(c)
}
```

**The rack is the gap `board_version` leaves.** A rack changes without the board
changing — an exchange, and a timeout returning tiles to the bag. A composition
names tiles by rack position, so a changed rack invalidates it even though the
board is untouched.

**No third counter is needed for that.** The staged tiles can be checked against
the rack the DTO already carries — seven tiles, compared on read — and it is a
check the composer needs anyway, since a tile you no longer hold cannot be
placed. Deriving beats accumulating here too.

**"Still this player's turn" is deliberately not in the test above**, and that
is a decision waiting on #88. Today a composition is only submittable on your
turn, so requiring `current_seat == key.seat` would be right. #88 asks for
staging *out of turn* — provisionally arranging a word while waiting — and under
that, holding a composition through the opponent's turn is the feature. The
board and rack conditions are correct either way; whether the turn joins them
is #88's to settle, and it is one clause.

**`turn` still earns its place**, as the note says: it is game state, it is what
undo walks, and it is what a player is shown. It is simply not a key.

### Deriving beats accumulating, and the scoreless rule is the case

Owner, 2026-08-29: *"is turn useful for the terminating condition where there
are multiple non-scoring turns?"* Yes, and it is the better shape.

Today the game carries an accumulator:

```rust
pub consecutive_scoreless_turns: u8,     // SCORELESS_TURN_LIMIT = 6
```

Replaced by a mark:

```rust
pub last_scoring_turn: i64,
// the rule, at the point of use:
let scoreless = self.turn - self.last_scoring_turn;
```

**Three things get better, and the third is the one that matters under undo.**

**It is checkable.** `turn - last_scoring_turn` can be verified against the move
log; `consecutive_scoreless_turns` is a number that can only be trusted. A
count that nothing can contradict is a count that can be wrong for a long time.

**The rule stops being baked into the stored value.** Changing the limit from
six to eight is a comparison changing, not stored counters meaning something
new.

**And it survives undo without unwinding.** Undo produces a new higher version
whose content is an earlier state — so every field is restored together, and a
derived quantity is right the moment its inputs are. An accumulator restored the
same way is also right; the difference appears if undo is ever implemented as
*applying an inverse* rather than restoring, where every accumulator needs its
own decrement and one that is forgotten is silently wrong. Deriving means there
is nothing to forget.

**The honest caveat**: as the note has undo — restore, not inverse — the
accumulator would also survive, so this is not a fix for a bug that exists. It
is choosing the shape that stays correct under a change of undo strategy, at a
cost of nothing.

**One thing it does not change.** *Scoreless* still means what it means today —
a pass, an exchange, or a placement scoring zero — and each is a turn, so
`turn` advances for all three. If any of those ever stops advancing the turn,
this derivation breaks silently, which is worth a test rather than a comment.

### The message

`GameMessage` is in the note. What it needs alongside it is the result:

```rust
pub struct Applied {
    pub version: i64,          // the version this change produced
    pub event: GameEvent,      // what happened, structured — for the log and the client
    pub finished: bool,        // the caller settles ratings and stats on the edge
    pub next: Option<u8>,      // the seat now on turn, if any — the engine hook
}

pub enum ApplyError {
    NotYourTurn { seat: u8 },
    SeatNotPlaying { seat: u8 },
    GameNotActive,
    IllegalMove(rules_shared::MoveError),
    Unknown(String),
}
```

**`next` is how a bot's turn is noticed** without anybody searching for one. The
handler already knows who is on turn after applying; returning it means the
caller can hand that seat to the engine runner and return.

### The one handler

```rust
impl GameSession {
    /// The only method that mutates a game. Validates, applies, advances the
    /// version, records the event — in that order.
    pub fn apply(&mut self, message: GameMessage, now: i64)
        -> Result<Applied, ApplyError>;
}
```

Everything else on `GameSession` becomes a reader. The methods that mutate
today — `maybe_run_engine_turn`, the action handlers, the invitation writers —
either disappear into `apply` or become callers of it.

**Enforced by visibility, not by discipline.** `seats`, `state`, `bag`,
`version` and `turn` become private to the module holding `apply`, with readers
for what the outside needs. A second writer then does not compile, which is the
difference between this and `announce_invitation_change`.

## 2 · The wire

### The seat, on the wire

```rust
pub struct SeatDto {
    pub number: u8,
    pub kind: SeatKind,
    pub player_id: Option<String>,
    pub engine_id: Option<String>,
    pub state: SeatStateDto,          // mirrors SeatState, tagged
    pub rack: Option<SeatRackDto>,    // present only for Playing
    pub score: Option<i32>,
}

#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SeatRackDto {
    Visible { tiles: RackDto },
    Hidden  { count: u8 },
}
```

`ParticipantDto` loses `display_name`, `invitation_status`, `invited_email`,
`resigned`, `rating_before`, `rating_after` and `current_rating`. The first four
are now the seat's state; the last three are facts about an event or a
projection, per the note.

### The game, on the wire

```rust
pub struct GameStateDto {
    pub id: String,
    pub version: i64,
    pub turn: i64,                    // new — game state, shown to the player
    pub board_version: i64,           // new — the composition key
    pub status: GameStatus,
    // …variant, language, board_layout, current_seat, winner_seat,
    //   final_bonus_*, bag_count, move_time_limit_seconds, turn_started_at,
    //   board, moves, messages unchanged in shape…
    pub seats: Vec<SeatDto>,          // was `participants`
    pub players: Vec<PlayerRefDto>,   // new — the lookup, resolved at build
}

/// Everything about a person that a game refers to but does not own.
pub struct PlayerRefDto {
    pub id: String,
    pub display_name: String,
    pub current_rating: Option<f64>,
}
```

**`players` is what makes the lookup rule renderable.** The game holds ids; the
client needs names; resolving at DTO-build time is what makes a rename arrive
without anything being copied into game data. It carries every player the game
mentions — seats, chat authors, event subjects — so a client never has a
dangling id.

`racks: Vec<RackDto>` disappears from the top level: a rack belongs to a seat,
and hiding one is `SeatRackDto::Hidden`, not an empty rack.

### Structured descriptions

`MoveRecordDto.description` and the prose in events are replaced:

```rust
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum GameEventDto {
    Placed        { seat: u8, main_word: String, score: i32 },
    Passed        { seat: u8 },
    Exchanged     { seat: u8, count: u8 },
    Resigned      { seat: u8 },
    ForceResigned { seat: u8, by: String },
    TimedOut      { seat: u8 },
    SeatInvited   { seat: u8 },
    InvitationAccepted { seat: u8 },
    InvitationDeclined { seat: u8 },
    SeatWithdrawn { seat: u8 },
    Started, Aborted, Finished { winner: Option<u8> },
    UserDetailsUpdated { player: String },
    ChatPosted    { seat: Option<u8>, player: String },
}

impl GameEventDto {
    /// Which of the three categories this change belongs to. The client reads
    /// it to decide what to redraw; nothing on the server branches on it.
    pub fn category(&self) -> ChangeCategory {
        use GameEventDto::*;
        match self {
            Placed { .. }                          => ChangeCategory::Board,
            ChatPosted { .. }                      => ChangeCategory::Periphery,
            _                                      => ChangeCategory::Game,
        }
    }
}

pub enum ChangeCategory { Board, Game, Periphery }
```

**Undo and redo are classified by what they undo**, not by being undo — undoing
a placement is a board change, undoing a pass is a game change. That falls out
if the event carries what it reversed, which it must anyway for the log to be
readable.

Seat numbers and player ids, not sentences. The client renders them, which is
the only way any of it is readable in a language other than the one the server
was written in — and this service already ships Spanish dictionaries.

### The envelope

```rust
pub enum ServerMessageDto {
    /// The whole state, redacted for this recipient. Sent on connect, on
    /// reconnect, and after every change.
    State { game: GameStateDto, because: Option<GameEventDto> },
    Rejected { message: String },
}
```

**Whole state, never a diff.** A diff needs the client to hold the prior
version and needs the server to know which one it holds; the state is small,
and `should_apply_update`'s version comparison already discards what a client
has. `because` is what the log records and what a client shows in the move
list — it is not applied.

## 3 · The interface layer

A new crate. `api` keeps depending on `serde` alone; `rules-shared` keeps
knowing nothing about the wire.

```text
crates/api            DTOs and serde. No rules, no engine.
crates/rules-shared   the domain: GameState, Rack, Tile, MoveCandidate.
crates/game-wire      NEW. depends on both. The conversion, both directions.
crates/server-game    depends on game-wire.
crates/ui             depends on game-wire.
crates/test-client    NEW. depends on game-wire.  (see 71-test-approach.md)
```

```rust
// crates/game-wire
pub fn game_to_dto(session: &GameSession, viewer: &ViewerAccess) -> GameStateDto;
pub fn game_from_dto(dto: &GameStateDto) -> Result<GameView, WireError>;

pub fn board_from_dto(cells: &[BoardCellDto]) -> Result<Board, WireError>;
pub fn rack_from_dto(rack: &RackDto) -> Result<Rack, WireError>;
pub fn move_candidate_from_dto(m: &MoveCandidateDto) -> Result<MoveCandidate, WireError>;
```

`board_from_dto`, `tile_from_dto` and `move_candidate_from_dto` exist today
inside `server-game`, which is exactly why no other client can have them. They
move here unchanged in behaviour.

**`GameView` is what a client can rebuild** — the game as this viewer is
entitled to see it, with `SeatRack::Hidden` where a rack was withheld. It is
not `GameSession`: a client has no bag and no other player's tiles, and a type
that pretended otherwise would be lying in the type system.

**The identity is a property test over this crate**, which is the point of
putting it here:

```rust
// for any session and viewer:
game_from_dto(&game_to_dto(&session, &viewer))  ==  session.view_for(&viewer)
```

## 4 · Access

```rust
pub struct ViewerAccess {
    pub player: Option<PlayerId>,
    pub seats: Vec<u8>,        // every seat this account holds — not one
    pub is_creator: bool,
}
```

`Creator` stops being a rank below participant: an account can be the creator
*and* hold two seats. What a viewer may see is the union over `seats`, which is
the live defect the note names — today `.find(...)` returns one seat, so a
player holding two has one of their own racks hidden from them.

## 5 · Database

| table | change |
| --- | --- |
| `games` | add `version`, `turn`, `board_version` and `last_scoring_turn`, all `integer not null default 0`. `snapshot_json` changes shape |
| `game_participants` | drop `display_name`. Add `state text not null`, `invitation_id text`, `hidden_by_player integer not null default 0`. Keep `outcome`, `bingo_count`, `score` — stats read them without loading a snapshot |
| `game_invitations` | unchanged. It stays the record of who was asked and what they said, which DEL-2 reads |
| `game_moves`, `game_messages` | drop `display_name` from messages; descriptions become structured |

**`version` and `turn` become columns** rather than living only inside
`snapshot_json`, because a sweep needs to find games by state without
deserialising every snapshot, and because a column can be indexed.

**Migration is a deletion.** The note settles this: existing games are deleted,
users and ratings kept. So the migration is a schema rewrite plus
`delete from games`, and the risk is entirely in what it must *not* delete —
`players`, `player_ratings`, `rating_history`, `sessions`.

## 6 · Modules

| module | what happens to it |
| --- | --- |
| `game_state.rs` | `ParticipantState` → `Seat`; gains `apply`; loses every other mutator. Its private fields are what enforce the single writer |
| `app/games.rs` (999 lines) | the action handlers become thin: parse, build a `GameMessage`, call `apply`, publish. `run_engine_turns` and `MAX_ENGINE_TURNS_PER_TRIGGER` go |
| `app/roster.rs` (391) | seat add/remove/swap become `GameMessage`s |
| `app/invitations.rs` (367) | send/accept/decline become `GameMessage`s; the table write stays, the seat write moves into `apply` |
| `app/events.rs` (105) | gains `publish(Applied)` — persist, broadcast, one place |
| `app/sweeps.rs` (268) | timeouts and retention go through `apply` rather than writing rows, which is what makes them visible to clients |
| `app/admin.rs` (370) | force-resign and force-end become `GameMessage`s |
| `app/stats.rs`, `ratings.rs` | unchanged in substance; read `Applied.finished` instead of inspecting status transitions |
| `crates/ui/src/app.rs` (5,500) | section 7 |
| `crates/engine-core` | **unchanged.** The trait already takes a request and returns an action; what changes is who calls it |

## 7 · The client

### Where the state lives

```rust
selected_game: Signal<Option<GameId>>,        // intent
cache:         Signal<Option<GameStateDto>>,  // what the server last said
composition:   Signal<Option<Composition>>,   // keyed, see below

pub struct Composition {
    pub key: CompositionKey,
    pub staged: Vec<StagedPlacementView>,
    pub cursor: Option<usize>,
    pub direction: Option<DirectionDto>,
    pub blank_letter: Option<String>,
    pub exchange: Option<HashSet<usize>>,
}

pub struct CompositionKey {
    pub game: GameId,
    pub board_version: i64,   // not `turn`: turn repeats under undo, this cannot
    pub seat: u8,
}
```

The seven composer signals become one optional struct with a key. `selected_id`
stops being read back out of the loaded DTO, which is what currently makes
*deselect* and *clear the panes* the same action.

### How updates are centralised

**One entry point for anything the server says.** `apply_game_update` is called
from **23 sites** in `app.rs` today; each is a place that could forget
something. It becomes one:

```rust
/// The only function that writes `cache`. Every response and every socket
/// frame arrives here.
fn on_server_state(&mut self, incoming: GameStateDto, because: Option<GameEventDto>) {
    if !should_apply(self.cache.peek().as_ref(), &incoming) { return; }  // as today
    self.cache.set(Some(incoming));
    // nothing else. No clearing, no cascade.
}
```

**And nothing clears the composition.** It is filtered on read:

```rust
fn live_composition(&self) -> Option<Composition> {
    let key = self.current_key()?;              // from selected_game + cache
    self.composition.peek().clone().filter(|c| c.key == key)
}
```

That is the note's *stop clearing, start matching*, made concrete: a writer that
forgets cannot cause the failure, because no writer participates.

**Two side effects stay explicit**, because they are not state: storing the
session token, and tearing down the socket. Everything else is derived on
render, which is what Dioxus does for free.

### What this does not become

Not a reducer over an event enum. Dioxus already propagates; a reducer would
sit on top of that and duplicate it, at the cost of rewriting a 5,500-line
component. The centralisation that is worth having is **one writer of the
server cache**, not one writer of everything.

## 8 · The engine

### What does not change

```rust
pub trait GameEngine: Send + Sync {
    fn metadata(&self) -> &EngineMetadata;
    fn choose_action(&self, request: EngineRequest<'_>) -> EngineResponse;
}
```

`EngineRequest` borrows `&GameState`, `&Rack`, `&VariantRules` — all
`rules-shared` types, none of them server types. **That is why the engine can
be lifted out at all**, and it is already true today.

### What changes: who calls it

```rust
/// Same code in the server and in a client. Given a view of a game and an
/// engine, decide whether it is this seat's turn and what to do about it.
pub fn take_turn(
    engine: &dyn GameEngine,
    view:   &GameView,          // from game_wire::game_from_dto
    seat:   u8,
    budget: Option<Duration>,
) -> Option<GameMessage>;
```

**In the server**, after `apply` returns `Applied { next: Some(seat), .. }` and
that seat is an engine seat:

1. the request returns — the human's move is already applied and broadcast
2. a task is spawned holding **no lock**
3. it builds the view, calls `take_turn`, and searches
4. it submits the result through `apply`, exactly as a client would
5. **the move is re-validated on arrival**, because the game may have moved —
   aborted, or the seat retired. A rejection is normal, not an error

**In a client**, the loop is the same three steps with a socket in the middle:

```text
connect, authenticate as the bot account
on each State frame:
    view  = game_from_dto(frame.game)
    for seat in my_seats:
        if view.current_seat == seat:
            if let Some(msg) = take_turn(engine, &view, seat, budget) {
                POST /games/{id}/actions   ← the same public route a person uses
            }
```

**Nothing mediates.** There is no proxy and no bot-specific route: a bot posts
the action a person posts, over the session of the bot's own account, and its
rating moves because the account is the bot's.

### What makes lifting it possible

Three things, and two of them are this note's other sections:

| | |
| --- | --- |
| the engine takes domain types, not server types | already true |
| a client can rebuild those types from a DTO | `game_wire::game_from_dto` — §3 |
| a hidden rack is distinguishable from an empty one | `SeatRack::Hidden(u8)` — otherwise an engine off the server reads an opponent's empty rack as fact and plays the endgame wrongly |

**The third is the one that would have been missed.** An engine running in the
server sees the whole game; the same engine in a client sees a redacted one, and
today redaction is indistinguishable from an empty rack. Lifting the engine out
without fixing that would give it a confident wrong answer rather than an
absent one.

### Where the engine runs is not in the data model

A bot seat carries an account id whichever side runs the search. The server
writes it without authenticating because it is the server; a harness
authenticates as the same account. Nothing downstream — ratings, stats,
DEL-2 — can tell the difference, and that is the goal at the top of the design
note stated as a property of the schema.

## Open questions this raises

**Does `apply` persist, or does its caller?** Written above as: `apply` mutates
in memory and returns `Applied`; `events::publish` persists and broadcasts.
That keeps `GameSession` free of the database, and makes `apply` a pure
function of state and message — which is what makes it testable without a
pool. The cost is that a caller can forget to publish. Enforceable by making
`Applied` `#[must_use]`, which is weaker than the type-level guarantee the
server side otherwise gets.

**Is `GameView` one type or two?** A server holds `GameSession`; a client holds
`GameView`. `take_turn` needs only the second. Whether the server builds a
`GameView` of its own game to call the same function, or `take_turn` is generic
over a trait both satisfy, decides whether there is one code path or two that
look alike. The first is simpler and copies; the second is cheaper and is a
trait nobody else needs.

**How does the harness discover its turn on startup?** The note settles this —
polling on start, socket thereafter. What it does not settle is what the
harness does with a game whose bot seat is on turn but whose socket frame was
missed while it was down, which is the same reconnect question the human client
has and should have the same answer.

**Does `turn` need to be persisted separately from `moves.len()`?** Settled by
undo, 2026-08-29: yes. Under undo `turn` walks backwards while `moves` does not
necessarily — an undone move stays in the log, since the log is the record of
what happened and undo is itself an event. So they diverge the first time undo
is used, and `moves.len()` was only ever a coincidence.

**Is `board_version` a fourth thing to keep in step?** It is set in the same
handler, in the arms that touch the board, and it is the only field of the four
whose maintenance is a rule rather than a consequence. If any of these is going
to be forgotten it is this one — so it is worth a test that asserts
`board_version` moves for `Place`, `Pass`, `Exchange` and undo, and does not
move for chat, an invitation or a rename.
