use serde::{Deserialize, Serialize};

/// The API contract version this build implements. Both server and client
/// binaries embed whatever this constant was at *their own* build time, so
/// comparing a client's compiled-in value against what a server reports at
/// `/health` detects real drift (e.g. a desktop client that predates a
/// breaking server change) rather than just tautologically matching itself.
///
/// Bump `major` for a breaking change to routes/DTOs (old clients can't be
/// trusted to work — should be treated as incompatible), `minor` for an
/// additive/non-breaking one (old clients still work, just without whatever
/// the change added). There's deliberately no patch/build component here:
/// those never change the wire contract, so including them would make the
/// compatibility check fire on every routine bugfix deploy. Release/build
/// numbering for display purposes is a separate concern — see each
/// binary's own `app_version()`.
// 2.0: every timestamp DTO field changed from a `String` (unix seconds as
// text) to a plain `i64` — a breaking wire change, hence the major bump.
// 2.4: `GET /admin/users` returns `AdminPlayerSummaryDto` instead of
// `PlayerDto`, to carry rating alongside the account. Minor, not major,
// despite being a changed response type: `/admin/*` is loopback-only with
// exactly one client — `tile-lite-elite-admin`, built from this same tree
// and shipped in the same container — so no player-facing client can be
// running against a server it disagrees with. Either bump reaches those
// clients, since any skew at all trips the web client's auto-update; what
// major would add is blocking them — a hard error on web, a "download a
// new client" banner on desktop — over a change they cannot observe.
// 2.5: `GET /dictionaries/{name}` now requires a session token. Minor by
// the same test as 2.4, though it does take a capability away rather than
// add one: the only client that calls it is the wasm build (native builds
// compile every dictionary in and never fetch), and any skew already
// auto-reloads the web client into a build that sends the header. A
// pre-2.5 web client that somehow didn't reload would keep playing and
// lose only its client-side move preview, which already degrades to
// absent whenever the fetch fails. Major would banner desktop users about
// an endpoint their build never calls.
// 2.6: the `spicy` edition joins the registry, so `variant` accepts a value
// a 2.5 client doesn't know. Additive and non-breaking, hence minor — but
// worth spelling out, because 0.4.13 shipped this edition *without* the
// bump and that is precisely what went wrong: no skew meant open tabs never
// reloaded, so they kept working while being unable to offer the edition
// they'd never heard of. The rule to apply is "can a client observe
// something new?", not "did a type change" — a new value for an existing
// field is new functionality.
// 2.7: `HealthDto` gains `schema_version`, the highest migration applied to
// the server's database. Purely additive — an older client deserializing
// this ignores the field — and it exists for `scripts/deploy.sh`, which
// compares it against the target commit's migrations and refuses to ship an
// image the database has already moved past.
// 2.8: removing an *aborted* game now succeeds where it used to be
// rejected; only `Finished` was accepted before, while the games panel
// offered the button for both. A new accepted value rather than a new type,
// so minor by the 2.6 test above — nothing changed shape, but a client can
// do something it could not before. Also worth the skew on its own account:
// the same release fixes the session being lost on reload, and that fix is
// *client* code, so open tabs only receive it when something makes them
// reload.
// 2.9: no wire change at all — this one is here to *deliver* two client
// changes to tabs that are already open, because api skew was still the
// only reload trigger when they were written. The last bump that will ever
// need to do that: the same release moves client-update delivery onto a
// build id in `/version.txt`, so from here a client-only change
// moves nothing here and this number goes back to meaning the contract.
// Carries the 502 fix (a proxy 502 no longer counts as "the server is up")
// and the switch itself.
// This number describes the *wire contract*, and nothing else. It once
// doubled as a client-update signal, on the assumption that a client change
// implied an API behaviour change — which is not true, and 2.9 is the proof:
// it moved with no server change at all. That reading was dropped rather
// than kept, because a third-party client needs the contract version to mean
// the contract, not "our web build changed". Client updates are delivered by
// a hash of the built bundle instead; see `watch_for_new_bundle` in
// `tile-lite-elite-ui`, and docs/3.3's "Decide whether the API version
// moves" for which changes bump this.
pub const API_VERSION: ApiVersion = ApiVersion {
    major: 2,
    minor: 13,
};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub struct ApiVersion {
    pub major: u32,
    pub minor: u32,
}

impl std::fmt::Display for ApiVersion {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}", self.major, self.minor)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HealthDto {
    pub status: String,
    pub api_version: ApiVersion,
    /// `Major.Minor.Patch[+build]` — see `server-game`'s `app_version()`.
    /// Lets anything that can reach `/health` (a human with `curl`, a
    /// deploy script) find out exactly which commit is live without SSHing
    /// in to grep startup logs — e.g. `scripts/deploy-preview.sh at prod`
    /// reads this to bring preview to the same version as production.
    pub app_version: String,
    /// Highest migration version applied to the server's database.
    ///
    /// Lets `scripts/deploy.sh` tell, before shipping anything, whether the
    /// image it is about to deploy is *older* than the schema already in
    /// place — an image that doesn't know a migration the database has
    /// applied fails sqlx's `validate_applied_migrations` and never boots.
    /// Rolling back across a migration is therefore a restore from the
    /// pre-deploy snapshot, not a redeploy; this field is what makes the
    /// script able to say so instead of shipping a container that dies.
    ///
    /// `None` only for a database with nothing applied yet.
    #[serde(default)]
    pub schema_version: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SeatKind {
    Human,
    Engine,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GameStatus {
    Waiting,
    Active,
    Finished,
    /// The game's creator cancelled it (force-resigning everyone) before a
    /// natural finish. Terminal like `Finished`, but not a real result — no
    /// winner, no rating change.
    Aborted,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DirectionDto {
    Horizontal,
    Vertical,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PremiumDto {
    Blank,
    DoubleLetter,
    TripleLetter,
    DoubleWord,
    TripleWord,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PositionDto {
    pub x: u8,
    pub y: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TileDto {
    /// One or two characters — most tiles are one, but a digraph tile
    /// (e.g. Spanish's CH/LL/RR) is a single physical tile/board
    /// square/rack slot that displays two.
    Letter {
        letter: String,
    },
    Blank {
        acting_as: Option<String>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TilePlacementDto {
    pub offset: u8,
    pub tile: TileDto,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MoveCandidateDto {
    pub start: PositionDto,
    pub direction: DirectionDto,
    pub tiles: Vec<TilePlacementDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PlayerActionDto {
    Place { candidate: MoveCandidateDto },
    Pass,
    Exchange { tiles: Vec<TileDto> },
    Resign,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GameActionRequest {
    pub seat_number: u8,
    pub action: PlayerActionDto,
}

/// How a `Human` seat gets filled at game-creation time. Ignored for
/// `Engine` seats, which are always filled immediately.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum SeatClaim {
    /// Bound immediately to the authenticated caller creating the game. At
    /// most one seat per request may use this.
    Creator,
    /// Pending until the named player accepts the invitation.
    Named { display_name: String },
    /// Pending until any logged-in player accepts — first to accept claims
    /// the seat.
    Open,
    /// Pending until whoever holds the emailed join link registers or logs
    /// in and confirms — no account is required to exist yet. Accepting
    /// works exactly like `Open` (first to confirm claims the seat; there's
    /// no cryptographic proof the confirmer is really the emailed person),
    /// it's just reached via a mailed link instead of general browsing —
    /// see `SeatInvitationStatus` and `get_open_invitations`'s doc comment
    /// for why this doesn't show up as a generic open seat to everyone.
    Email { email: String },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateSeatRequest {
    pub kind: SeatKind,
    pub display_name: String,
    pub engine_id: Option<String>,
    /// Required for `Human` seats; ignored for `Engine` seats.
    pub claim: Option<SeatClaim>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateGameRequest {
    pub seats: Vec<CreateSeatRequest>,
    pub seed: Option<u64>,
    pub variant: Option<String>,
    pub language: Option<String>,
    pub board_layout: Option<String>,
    /// How long a seat may sit on its turn before being auto-retired.
    /// `None` falls back to the server default (72 hours).
    pub move_time_limit_seconds: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct StartGameRequest {}

/// Swaps two seats' positions (and with them, turn order) in a game that
/// hasn't started yet — see `crates/server-game/src/game_state.rs`'s
/// `GameSession::swap_seats`. Always a single adjacent swap from the
/// client's perspective (an up/down button in the player list); the server
/// doesn't need to know the caller's intent beyond "swap these two."
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SwapSeatsRequest {
    pub seat_a: u8,
    pub seat_b: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EngineProfileDto {
    pub id: String,
    pub name: String,
    pub version: String,
    pub author: Option<String>,
    pub description: Option<String>,
    pub supports_timed_play: bool,
    pub supports_analysis: bool,
    pub supports_ranking: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ParticipantDto {
    pub seat_number: u8,
    pub kind: SeatKind,
    pub display_name: String,
    pub player_id: Option<String>,
    pub engine_id: Option<String>,
    pub score: i32,
    /// This seat's rating immediately before/after this game, if — and
    /// only if — the game actually moved it: both `None` while the game
    /// is still in progress, and both stay `None` even once `Finished` if
    /// this particular ending skipped rating (a timeout, a creator-forced
    /// resignation, or an admin force-end — see `stats::settle_ratings`).
    /// Populated by `stats::attach_rating_deltas`, not by `to_dto()`
    /// itself, since it needs a DB read `to_dto()` doesn't have.
    pub rating_before: Option<f64>,
    pub rating_after: Option<f64>,
    /// This seat's rating *right now* — shown next to their name so an
    /// opponent's standing is visible at a glance, at any point in a
    /// game, not just once it's `Finished`. Distinct from `rating_after`:
    /// this is always their current `player_ratings` row (1500 if never
    /// rated), not specifically what this game itself changed it to (and
    /// unaffected by the current game's own outcome until it's actually
    /// settled). `None` only for a seat with neither a `player_id` nor an
    /// `engine_id` (an unclaimed seat), same as every other rating field.
    /// Populated by `stats::attach_current_ratings`, not `to_dto()`
    /// itself, since it needs a DB read `to_dto()` doesn't have.
    pub current_rating: Option<f64>,
    /// `None` for an Engine seat or any already-claimed Human seat (the
    /// creator's own seat, or an accepted invitee) — there's no invitation
    /// lifecycle left to report. `Some(...)` for an unclaimed Human seat,
    /// reflecting its most recent invitation (or lack of one). Only
    /// populated by handlers where it's meaningful (a `Waiting` game) —
    /// see `attach_invitation_status` in `server-game`; elsewhere this is
    /// always `None`, which is also correct there (every seat is claimed
    /// once a game is `Active`, since `start_game` requires full seating).
    pub invitation_status: Option<SeatInvitationStatus>,
    /// Set only for a seat created with `SeatClaim::Email`, and only until
    /// claimed — the address the join link was sent to, so the creator's
    /// roster view can show it and a "Send"/"Resend" click doesn't need it
    /// re-typed. `None` for every other seat kind/claim.
    pub invited_email: Option<String>,
    /// This seat has left the game — resigned, force-resigned, or timed
    /// out — but is still shown in the roster (never removed mid-game),
    /// gone from the turn order, and (once the game is `Finished`)
    /// excluded from ranking unless it was a voluntary resignation, which
    /// is still ranked, just below every seat that kept playing — see
    /// `stats::settle_ratings`'s doc comment for the full ranking rule.
    /// The roster view uses this to gray the seat out; which of
    /// resigned/force-resigned/timed-out it was is already visible via
    /// that seat's own "Last move" cell.
    pub resigned: bool,
}

/// A `Waiting` game's unclaimed-seat lifecycle, inferred from that seat's
/// most recent `game_invitations` row (see `persistence::InvitationRecord`)
/// — not stored redundantly on the seat itself, so there's exactly one
/// source of truth. Deliberately excludes `Accepted`/`Cancelled`: an
/// accepted invitation means the seat is claimed (`ParticipantDto.player_id`
/// is `Some`, `invitation_status` is `None` instead), and a cancelled one
/// means the seat no longer exists at all (removing a seat deletes it).
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SeatInvitationStatus {
    /// Seat exists (the creator added it) but no invitation has been sent.
    NotSent,
    /// Invitation sent, awaiting response.
    Pending,
    /// Invitee declined, or previously accepted and then withdrew.
    Rejected,
}

/// Why a game appears in a particular caller's `GET /games` list — the
/// server returns one flat, tagged list rather than pre-split buckets, so
/// the client can group/sort/filter however it wants.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GameRelationship {
    /// You hold a claimed seat, the game is active, and it's your turn.
    YourTurn,
    /// You hold a claimed seat, but it's not (currently) your turn.
    Participant,
    /// You created this game but hold no seat in it (e.g. an Engine vs
    /// Engine game you set up to watch).
    Creator,
    /// You've been invited by name to a specific seat.
    InvitedByName,
    /// A seat in this game is open to any logged-in player.
    InvitedOpen,
}

/// A lightweight summary of a game, cheap enough to fetch in bulk for a
/// games list. Deliberately excludes the board/rack/move-log detail that
/// `GameStateDto` carries — fetch the full game by id once it's selected.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct GameSummaryDto {
    pub id: String,
    pub status: GameStatus,
    /// The bundled edition this game was created under (e.g. "official",
    /// "north_american", "german") — see `GameStateDto.variant`.
    pub variant: String,
    pub current_seat: u8,
    pub participants: Vec<ParticipantDto>,
    /// Seconds since the Unix epoch (as a string, matching the server's
    /// storage format) of the most recent move, or the game's creation
    /// time if no moves have been made yet.
    pub last_activity_at: i64,
    pub move_time_limit_seconds: u64,
    /// Seconds since the Unix epoch when `current_seat`'s turn began.
    /// Meaningless while `status` isn't `Active`.
    pub turn_started_at: i64,
    pub relationship: GameRelationship,
    /// Set when `relationship` is `InvitedByName` or `InvitedOpen` — the
    /// invitation to accept/reject directly from the list.
    pub invitation_id: Option<String>,
    /// When the most recent message **from somebody else** was sent, if there
    /// has been one — deliberately separate from `last_activity_at` (moves), so
    /// the client can tell "new chat" apart from "new move" and show an unread
    /// indicator. The client compares this against its own locally-stored "last
    /// seen" watermark per game; the server has no concept of read receipts.
    ///
    /// **Caller-relative**, like `relationship` and `invitation_id`: your own
    /// messages are excluded, because an unread mark for something you just
    /// typed says nothing. Answering that here rather than shipping the sender
    /// and making every client work it out keeps the question and its answer in
    /// one place — and the client already knows the sender of every message it
    /// has actually loaded, so the gap was only ever in the games list.
    pub last_message_received_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BoardCellDto {
    pub premium: PremiumDto,
    /// One or two characters — see `TileDto::Letter`.
    pub letter: Option<String>,
    pub is_blank: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RackDto {
    /// One count per letter in whichever alphabet the game's edition uses
    /// (26 for every Latin-alphabet edition, 29 for German, ...) — a `Vec`
    /// rather than a fixed-size array specifically so this crate doesn't
    /// need to depend on `rules_shared` just to know `MAX_ALPHABET_SIZE`,
    /// and so older/shorter snapshots on either side of the wire still
    /// deserialize fine (the receiving end pads to whatever width it needs).
    pub counts: Vec<u8>,
    pub blanks: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MoveRecordDto {
    pub move_number: i64,
    pub seat_number: u8,
    pub move_type: String,
    pub main_word: Option<String>,
    pub score_delta: i32,
    /// Board squares this move placed a tile on — empty for anything but
    /// `"place"`.
    pub positions: Vec<PositionDto>,
    pub description: String,
    /// How long this move took, in **microseconds** — a human's turn wall-clock
    /// (seconds resolution, from `turn_started_at`) or a bot's actual compute
    /// time (excludes the engine broadcast-pacing delay). Microseconds because
    /// bot moves are routinely sub-millisecond; i64 still holds a multi-hour
    /// human turn. `None` where it isn't meaningful/wasn't captured
    /// (resign/timeout/abort/admin, or a snapshot predating the field).
    /// `#[serde(default)]`.
    #[serde(default)]
    pub elapsed_us: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChatMessageDto {
    pub id: String,
    pub player_id: String,
    pub display_name: String,
    pub body: String,
    pub created_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PostChatMessageRequest {
    pub body: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct GameStateDto {
    pub id: String,
    /// A monotonic per-game counter bumped on every state change. Lets a
    /// client ignore a snapshot older than the one it already shows —
    /// guarding against out-of-order arrivals across the WebSocket and HTTP
    /// response paths, which both deliver full snapshots (see the client's
    /// `apply_game_update`). `#[serde(default)]` → `0` for a snapshot/peer
    /// predating the field.
    #[serde(default)]
    pub version: i64,
    pub status: GameStatus,
    /// `None` only for a game persisted before this field existed (see
    /// `#[serde(default)]` on `PersistedGame.creator_player_id`) — every
    /// game created since has one. Lets the client identify the creator
    /// from the game-detail view itself, for gating the roster-management
    /// controls (start/reorder/add/remove seat, force-resign) to them.
    pub creator_player_id: Option<String>,
    pub variant: String,
    pub language: String,
    pub board_layout: String,
    pub turn_number: i64,
    pub current_seat: u8,
    pub winner_seat: Option<u8>,
    /// Set only when the game ended because someone went out (emptied
    /// their rack) — the seat that received the standard end-of-game rack
    /// bonus (everyone else's remaining rack value), and how many points
    /// that was. `None` for a scoreless-turn-limit ending, a resignation,
    /// or a timeout, none of which involve that transfer.
    pub final_bonus_seat: Option<u8>,
    pub final_bonus_points: Option<i32>,
    pub bag_count: usize,
    pub move_time_limit_seconds: u64,
    /// Seconds since the Unix epoch when `current_seat`'s turn began.
    /// Meaningless while `status` isn't `Active`.
    pub turn_started_at: i64,
    pub participants: Vec<ParticipantDto>,
    pub board: Vec<BoardCellDto>,
    /// Redacted per-viewer at the API boundary (see `resolve_viewer_access`/
    /// `redact_game_state` in `server-game`) — a caller only ever receives
    /// their own seat's rack, everyone else's entries are zeroed. Never
    /// trust this field's *absence* of data as proof a seat has no tiles;
    /// it just means you're not allowed to see them.
    pub racks: Vec<RackDto>,
    pub moves: Vec<MoveRecordDto>,
    /// Empty unless the caller is a seated participant — see
    /// `resolve_viewer_access` in `server-game`.
    pub messages: Vec<ChatMessageDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum GameEventDto {
    StateUpdated { game: GameStateDto },
    GameStarted { game: GameStateDto },
    GameFinished { game: GameStateDto },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ApiError {
    pub message: String,
    /// Games standing in the way of whatever was refused, for a client that
    /// wants to show them rather than reprint a sentence about them. Empty
    /// and omitted for every other error, so a client that ignores it sees
    /// exactly what it saw before.
    ///
    /// The server sends the games; the client decides how to display them.
    /// Formatting a terminal table server-side would put presentation in the
    /// crate least able to know how it will be read.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub blocking_games: Vec<AdminGameSummaryDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PreviewMoveRequest {
    pub seat_number: u8,
    pub candidate: MoveCandidateDto,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PreviewMoveResponse {
    pub is_legal: bool,
    pub headline: String,
    pub detail: String,
    pub score: Option<i16>,
}

// ========== Authentication ==========

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RegisterPlayerRequest {
    pub display_name: String,
    pub email: String,
    pub password: String,
    /// Mirrors the "Stay logged in" checkbox — determines how long the
    /// issued session lives server-side (see `LoginPlayerRequest`'s doc
    /// comment on the same field for why this matters).
    pub stay_logged_in: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PlayerSessionDto {
    pub player_id: String,
    pub session_token: String,
    pub display_name: String,
    pub email: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LoginPlayerRequest {
    pub display_name: String,
    pub password: String,
    /// The server has no other way to know whether this login should
    /// outlive a short-lived session — the checkbox only decides, client
    /// side, whether the token gets persisted to local storage at all, so
    /// without this the server can't tell "abandoned the moment this tab
    /// closes" apart from "meant to last." `false` gets a short server-side
    /// expiry (so an ordinary sign-in doesn't linger in the sessions table
    /// forever); `true` gets none, matching how long "stay logged in" is
    /// meant to actually mean.
    pub stay_logged_in: bool,
}

/// Self-service — the caller proves they know the current password rather
/// than relying solely on holding a valid session token (a "remember me"
/// token could otherwise be enough to hijack the account by itself).
/// Distinct from the admin CLI's `AdminResetPasswordRequest`, which is
/// loopback-gated and doesn't require the old password.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChangePasswordRequest {
    pub current_password: String,
    pub new_password: String,
}

/// Updates the caller's own display name and/or email — unlike
/// `ChangePasswordRequest`, doesn't require re-proving the current password:
/// a valid session is already the bar for these, matching every other
/// account action that isn't the password itself (see `change_password`'s
/// doc comment for why *that* one is different). Both fields optional so a
/// client can send just the one being edited; at least one must be set.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct UpdatePlayerDetailsRequest {
    pub display_name: Option<String>,
    pub email: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ValidateSessionRequest {
    pub session_token: String,
}

/// "Forgot password" — request a reset link by email. The response is the
/// same (`204 No Content`) whether or not the email is registered, so this
/// endpoint can't be used to enumerate accounts — same non-enumeration
/// principle as `LoginPlayerRequest`'s shared error message.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RequestPasswordResetRequest {
    pub email: String,
}

/// The second half of the flow: the caller presents the token from the
/// emailed link (not the old password — proving control of the email
/// address stands in for it, which is the whole point of this flow existing
/// alongside `ChangePasswordRequest`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ResetPasswordRequest {
    pub token: String,
    pub new_password: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PlayerDto {
    pub id: String,
    pub display_name: String,
    pub email: String,
    pub created_at: i64,
    pub last_seen_at: Option<i64>,
}

// ========== Game Invitations ==========

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum InvitationStatus {
    Pending,
    Accepted,
    Rejected,
    Cancelled,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GameInvitationDto {
    pub id: String,
    pub game_id: String,
    /// `None` for an open/stranger invitation.
    pub invited_player_id: Option<String>,
    pub inviting_player_id: String,
    pub seat_number: u8,
    pub status: InvitationStatus,
    pub created_at: i64,
    pub responded_at: Option<i64>,
    pub inviting_player_display_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct InvitePlayerRequest {
    /// `None` invites any logged-in player (open/stranger) rather than one
    /// specific person by name.
    pub invited_display_name: Option<String>,
    /// Set instead of `invited_display_name` to (re)send an email-invite
    /// join link — mutually exclusive with it; both `None` means a plain
    /// open/stranger invitation.
    pub invited_email: Option<String>,
    pub seat_number: u8,
}

/// Minimal, unauthenticated preview of an invitation — what the emailed
/// join link's landing page shows before the visitor has registered or
/// logged in (see the doc comment on `SeatClaim::Email`). Deliberately
/// excludes anything about the game itself (board, other players' names,
/// etc.) — just enough to render "X invited you to play" and know whether
/// the link is still live.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct InvitationPreviewDto {
    pub inviting_player_display_name: String,
    pub status: InvitationStatus,
}

// ========== Admin ==========
//
// The /admin/* endpoints these types serve are restricted to loopback
// callers only (see `server-game`'s admin route guard) — there's no
// per-request auth beyond "you're running on the same machine as the
// server," so these types intentionally aren't reachable by the ordinary
// player-facing clients.

/// One row of the admin user listing: the account record, plus the rating
/// subsystem's view of it. Distinct from `PlayerDto` (which
/// `/auth/validate` returns to the player themselves) because rating is an
/// operator-facing join, not part of a player's own identity payload —
/// a player reads their rating from `/players/{id}/stats` instead.
/// One day's record of what the database holds — see migration 0007 and #90.
///
/// A gap in the series means the service was quiet that day, not that anything
/// broke: the row is written by a sweep that only runs when somebody uses the
/// service, which is the accepted cost of having no scheduler on the VM.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdminDatabaseSizeDto {
    pub recorded_on: String,
    pub recorded_at: i64,
    pub players: i64,
    pub sessions: i64,
    pub games: i64,
    pub invitations: i64,
    pub chat_messages: i64,
    pub database_bytes: i64,
    pub games_in_memory: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AdminPlayerSummaryDto {
    pub id: String,
    pub display_name: String,
    pub email: String,
    pub created_at: i64,
    pub last_seen_at: Option<i64>,
    /// `None` — not 1500 — for an account that has never finished a rated
    /// game, so the listing can distinguish "unrated" from "rated and sits
    /// exactly at the starting value". `PlayerStatsDto` deliberately makes
    /// the opposite choice (1500 for everyone) because it answers "what is
    /// this player's rating", where an operator listing answers "has this
    /// account ever actually played".
    pub rating: Option<f64>,
    pub games_rated: i64,
}

/// A game summary with `created_at`, for age-based filtering/display in the
/// admin CLI — the ordinary player-facing `GameSummaryDto` deliberately
/// doesn't carry this.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AdminGameSummaryDto {
    pub id: String,
    pub status: GameStatus,
    pub created_at: i64,
    pub last_activity_at: i64,
    pub participants: Vec<ParticipantDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdminResetPasswordRequest {
    pub new_password: String,
}

// ========== Rating & Stats ==========
//
// A "rating subject" is a player or an engine (bot) — both are rated and
// tracked identically, keyed by (subject_kind, subject_id) where subject_id
// is a `players.id` or an `engine_profiles.id`. See `server_game::stats` for
// the ELO-style update and outcome bookkeeping this serves.

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RatingSubjectKind {
    Player,
    Engine,
}

/// A subject's current rating plus aggregate outcome/bingo counters. Never
/// 404s for an unrated subject — `rating` is 1500 and every counter is 0
/// for a player/engine that's never finished a rated game.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlayerStatsDto {
    pub subject_kind: RatingSubjectKind,
    pub subject_id: String,
    pub rating: f64,
    pub games_rated: i64,
    pub wins: i64,
    pub losses: i64,
    pub ties: i64,
    pub timeouts: i64,
    pub resignations: i64,
    pub bingo_count: i64,
}

/// One point on a subject's rating-over-time graph — its rating
/// immediately after one specific game.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RatingPointDto {
    pub game_id: String,
    pub rating_after: f64,
    pub created_at: i64,
}

/// One line describing who is in a game and how they are doing.
///
/// Shared rather than owned by whichever tool renders it: the admin listing's
/// last column and the refusal an operator gets when an account still has
/// games are the same question asked twice, and two copies of the answer
/// would eventually disagree about what a bot or a departed seat looks like.
///
/// Everything here comes from data the caller already holds and a name-only
/// rendering discards — an unclaimed seat used to be indistinguishable from a
/// player named "Open seat", a bot from a human, and a seat that has left from
/// one still playing, which is precisely what someone reads this to find out.
///
/// Scores appear only once a game has started: every seat in a `Waiting` game
/// reads `0`, which is a column of noise rather than information.
pub fn describe_seats(status: GameStatus, participants: &[ParticipantDto]) -> String {
    let show_scores = status != GameStatus::Waiting;
    let mut seats: Vec<&ParticipantDto> = participants.iter().collect();
    seats.sort_by_key(|seat| seat.seat_number);
    seats
        .iter()
        .map(|seat| {
            let mut cell = seat.display_name.clone();
            match seat.kind {
                SeatKind::Engine => cell.push_str(" [bot]"),
                // An empty seat is not one thing. Somebody asked and is
                // waiting, somebody asked and was turned down, or nobody has
                // asked — and an operator deciding whether a game will ever
                // start needs to know which.
                SeatKind::Human if seat.player_id.is_none() => {
                    cell.push_str(match seat.invitation_status {
                        Some(SeatInvitationStatus::Pending) => " [invited]",
                        Some(SeatInvitationStatus::Rejected) => " [declined]",
                        _ => " [unclaimed]",
                    })
                }
                SeatKind::Human => {}
            }
            if seat.resigned {
                cell.push_str(" [out]");
            }
            if show_scores {
                cell.push_str(&format!(" {}", seat.score));
            }
            cell
        })
        .collect::<Vec<_>>()
        .join(" vs ")
}

#[cfg(test)]
mod describe_seats_tests {
    use super::*;

    fn seat(
        seat_number: u8,
        display_name: &str,
        kind: SeatKind,
        claimed: bool,
        resigned: bool,
        score: i32,
    ) -> ParticipantDto {
        ParticipantDto {
            seat_number,
            kind,
            display_name: display_name.to_string(),
            player_id: claimed.then(|| format!("player-{seat_number}")),
            engine_id: None,
            score,
            invitation_status: None,
            invited_email: None,
            resigned,
            current_rating: None,
            rating_before: None,
            rating_after: None,
        }
    }

    /// The distinctions a name-only rendering throws away: a bot reads as a
    /// bot, a seat nobody has claimed reads as unclaimed rather than as a
    /// player who happens to be called "Open seat", and a seat that has left
    /// the game reads as out.
    #[test]
    fn seat_summary_marks_bots_unclaimed_seats_and_resignations() {
        let summary = describe_seats(
            GameStatus::Active,
            &[
                seat(0, "Alice", SeatKind::Human, true, false, 130),
                seat(1, "Bob", SeatKind::Human, true, true, 88),
                seat(2, "Open seat", SeatKind::Human, false, false, 0),
                seat(3, "Greedy", SeatKind::Engine, false, false, 155),
            ],
        );
        assert_eq!(
            summary,
            "Alice 130 vs Bob [out] 88 vs Open seat [unclaimed] 0 vs Greedy [bot] 155"
        );
    }

    /// Every seat in a game that has not started scores zero, so the column
    /// would be pure noise.
    #[test]
    fn seat_summary_omits_scores_before_a_game_starts() {
        let summary = describe_seats(
            GameStatus::Waiting,
            &[
                seat(0, "Alice", SeatKind::Human, true, false, 0),
                seat(1, "Open seat", SeatKind::Human, false, false, 0),
            ],
        );
        assert_eq!(summary, "Alice vs Open seat [unclaimed]");
    }

    /// An empty seat says which kind of empty it is, so a game nobody will
    /// ever join reads differently from one still waiting on an answer.
    #[test]
    fn seat_summary_tells_the_kinds_of_empty_apart() {
        let mut invited = seat(1, "Bob", SeatKind::Human, false, false, 0);
        invited.invitation_status = Some(SeatInvitationStatus::Pending);
        let mut declined = seat(2, "Carol", SeatKind::Human, false, false, 0);
        declined.invitation_status = Some(SeatInvitationStatus::Rejected);

        let summary = describe_seats(
            GameStatus::Waiting,
            &[
                seat(0, "Alice", SeatKind::Human, true, false, 0),
                invited,
                declined,
                seat(3, "Open seat", SeatKind::Human, false, false, 0),
            ],
        );
        assert_eq!(
            summary,
            "Alice vs Bob [invited] vs Carol [declined] vs Open seat [unclaimed]"
        );
    }

    /// Seats render in turn order regardless of the order they arrived in.
    #[test]
    fn seat_summary_is_ordered_by_seat_number() {
        let summary = describe_seats(
            GameStatus::Active,
            &[
                seat(2, "Carol", SeatKind::Human, true, false, 3),
                seat(0, "Alice", SeatKind::Human, true, false, 1),
                seat(1, "Bob", SeatKind::Human, true, false, 2),
            ],
        );
        assert_eq!(summary, "Alice 1 vs Bob 2 vs Carol 3");
    }
}
