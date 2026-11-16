//! Operator tooling for a tile-lite-elite server: list/delete users, reset
//! passwords, list/delete/force-end games. Talks to the server's `/admin/*`
//! endpoints over plain HTTP rather than touching the database directly, so
//! it can't drift from the cascading-delete/password-hashing logic the
//! server already has to get right for its own sake.
//!
//! The server only accepts these endpoints from loopback callers — running
//! this CLI IS the authentication, in the sense that you need to be on the
//! same machine as the server to reach them at all. Point `--server` at
//! anything other than the server's own loopback address and every request
//! will be rejected with 403, by design (see `require_loopback` in
//! `server-game`).
//!
//! Output is a plain aligned table by default and machine-readable JSON
//! under `--json` — the server's own DTOs, re-serialized, so a script gets
//! the full record rather than whatever the table had room for.
//!
//! **Exit status says why the run stopped** (docs/1.10 *What a script's exit
//! status means*), read from the reason the server answers with: `1` for a
//! *business* refusal, `2` for a *technical, fundamental* one, `75` for a
//! *blip* or a connection that was refused or timed out, `70` for an
//! *unexpected* error, a body the tool cannot read, or a panic in the tool
//! itself, `64` for a usage error. `--help` lists them. A failure prints the
//! body's `detail`, never reqwest's text; under `--json` it prints the body to
//! stdout, as a success does.

use api::{ErrorType, Reason};
use clap::{Parser, Subcommand};
use unicode_width::UnicodeWidthStr;

/// What `--help` says about the exit status; docs/1.10's table, as this tool
/// reads it.
const EXIT_CODES: &str = "\
Exit codes:
  0   completed
  1   the server refused the request: a business error, such as a missing user
  2   a fundamental error: a credential or a setting is at fault, such as a
      server address that is not loopback
  64  a usage error: a bad flag or a missing argument
  70  an unexpected error: a defect, or an answer this tool cannot read
  75  the server was busy or unreachable; a later retry may work";

#[derive(Parser)]
#[command(
    name = "tile-lite-elite-admin",
    about = "Administer a tile-lite-elite server (users, games). Must run on the same machine as the server.",
    after_help = EXIT_CODES
)]
struct Cli {
    /// Base URL of the server's HTTP API. Must resolve to loopback from the
    /// server's point of view, or every request will 403.
    #[arg(
        long,
        env = "TILE_LITE_ELITE_API_BASE_URL",
        default_value = "http://127.0.0.1:3000"
    )]
    server: String,

    /// Emit JSON instead of a table — the server's own records, unabridged,
    /// for piping into `jq` or a script.
    #[arg(long, global = true)]
    json: bool,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Manage player accounts.
    Users {
        #[command(subcommand)]
        action: UsersAction,
    },
    /// Manage games.
    Games {
        #[command(subcommand)]
        action: GamesAction,
    },
    /// What the database holds, day by day.
    ///
    /// Recorded by a sweep that runs when somebody uses the service, so a
    /// missing day means the service was quiet — not that anything broke.
    Size,
    /// When each scheduled job last finished a pass, and how many items
    /// errored on it.
    ///
    /// A job that has stopped shows an old time; one that fails shows a
    /// count. Times are UTC, to the second, because the fastest job runs
    /// every five seconds and a stall would hide inside a minute.
    SchedulerHealth,
}

#[derive(Subcommand)]
enum UsersAction {
    /// List all registered users, newest first, with their rating.
    List,
    /// Delete a user, along with their sessions, invitations, password-reset
    /// tokens, rating and rating history.
    ///
    /// Refused while any game still refers to them — one they created, a seat
    /// they hold, or an invitation they have not answered. Delete those games
    /// first, or wait: a completed game is removed a week after it ends and
    /// takes its invitations with it.
    Delete {
        /// Display name or account id. Names are unique, so either
        /// identifies exactly one account.
        user: String,
    },
    /// End every session an account has, so a delete that was refused for a
    /// live session can go ahead.
    ///
    /// The refusal says sessions end on their own — 48 hours idle, 10 days at
    /// the outside. That is true and it is not an action. This is the action.
    ///
    /// It removes nothing but sessions: the account is left exactly as it
    /// would have been when its sessions expired anyway. Signing out an
    /// account with none succeeds quietly, because "already signed out" is the
    /// state being asked for.
    SignOut {
        /// Display name or account id, as for `delete`.
        user: String,
    },
    /// Reset a user's password. Prints the new password if you don't
    /// supply one — there's no email flow to deliver it any other way.
    ResetPassword {
        /// Display name or account id, as for `delete`.
        user: String,
        #[arg(long)]
        password: Option<String>,
    },
}

#[derive(Subcommand)]
enum GamesAction {
    /// List games, optionally filtered by status and/or age.
    List {
        /// waiting | active | finished | aborted
        #[arg(long)]
        status: Option<String>,
        /// Only games created at least this many days ago.
        #[arg(long)]
        older_than_days: Option<i64>,
    },
    /// Delete a game and all its moves, chat, participants, invitations and
    /// rating history.
    Delete { game_id: String },
    /// Mark a stuck or abandoned game Finished without going through
    /// per-seat resignation. Doesn't touch scores. Refused for a game that
    /// has already finished or been aborted.
    ForceEnd { game_id: String },
}

fn main() {
    std::process::exit(guarded(run));
}

/// A panic in this tool is *unexpected*: exit 70, never Rust's 101.
fn guarded(run: impl FnOnce() -> i32 + std::panic::UnwindSafe) -> i32 {
    std::panic::catch_unwind(run).unwrap_or(EXIT_UNEXPECTED)
}

fn run() -> i32 {
    // clap's own usage error exits 2, which here means a fundamental error.
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(error) => {
            let usage_error = error.use_stderr();
            let _ = error.print();
            return if usage_error { EXIT_USAGE } else { 0 };
        }
    };
    let client = reqwest::blocking::Client::new();
    let output = Output { json: cli.json };

    let result = match cli.command {
        Command::Users { action } => run_users(&client, &cli.server, output, action),
        Command::Games { action } => run_games(&client, &cli.server, output, action),
        Command::Size => run_size(&client, &cli.server, output),
        Command::SchedulerHealth => run_scheduler_health(&client, &cli.server, output),
    };

    match result {
        Ok(()) => 0,
        Err(failure) => {
            failure.report(output);
            failure.exit
        }
    }
}

const EXIT_BUSINESS: i32 = 1;
const EXIT_FUNDAMENTAL: i32 = 2;
const EXIT_USAGE: i32 = 64;
const EXIT_UNEXPECTED: i32 = 70;
const EXIT_BLIP: i32 = 75;

/// Why a run stopped: the exit status, the sentence for the operator, and the
/// server's body where there was one.
#[derive(Debug)]
struct Failure {
    exit: i32,
    detail: String,
    status: Option<u16>,
    body: Option<Box<api::ApiError>>,
}

impl Failure {
    /// An answer the server sent, classified by its reason.
    fn from_problem(status: u16, problem: api::ApiError) -> Self {
        Self {
            exit: exit_for(status, &problem),
            detail: problem.sentence().to_string(),
            status: Some(status),
            body: Some(Box::new(problem)),
        }
    }

    /// An error of this tool's or an answer it cannot read: *unexpected*.
    fn unexpected(detail: impl Into<String>) -> Self {
        Self {
            exit: EXIT_UNEXPECTED,
            detail: detail.into(),
            status: None,
            body: None,
        }
    }

    /// The connection was refused or timed out: a *blip*.
    fn unreachable(url: &str) -> Self {
        Self {
            exit: EXIT_BLIP,
            detail: format!(
                "Could not reach the server at {url}. Check that it is running, then try again."
            ),
            status: None,
            body: None,
        }
    }

    /// What `--json` prints: the server's own body, or one in the same shape
    /// for a failure that never reached the server's answer.
    fn body_for_json(&self) -> api::ApiError {
        if let Some(body) = &self.body {
            return (**body).clone();
        }
        let error_type = if self.exit == EXIT_BLIP {
            ErrorType::Technical
        } else {
            ErrorType::Unexpected
        };
        api::ApiError {
            message: self.detail.clone(),
            status: self.status.unwrap_or(0),
            detail: self.detail.clone(),
            outcome: "fatal".to_string(),
            error_type: Some(error_type),
            blip: self.exit == EXIT_BLIP,
            domain: "tile-lite-elite-admin".to_string(),
            ..api::ApiError::default()
        }
    }

    /// Under `--json` the body goes to stdout, as a success's does and with
    /// nothing on stderr; otherwise the sentence goes to stderr, after the
    /// table of games where the refusal names some.
    fn report(&self, output: Output) {
        if output.json {
            match serde_json::to_string_pretty(&self.body_for_json()) {
                Ok(rendered) => println!("{rendered}"),
                Err(_) => println!("{{\"detail\":\"{}\"}}", self.detail),
            }
            return;
        }
        if let Some(body) = &self.body
            && !body.blocking_games.is_empty()
        {
            eprintln!("{}", self.detail);
            eprintln!();
            print_table(
                &["ID", "STATUS", "LAST ACTIVITY (UTC)", "SEATS"],
                body.blocking_games
                    .iter()
                    .map(|game| {
                        vec![
                            game.id.clone(),
                            format!("{:?}", game.status).to_lowercase(),
                            format_timestamp(game.last_activity_at),
                            api::describe_seats(game.status, &game.participants),
                        ]
                    })
                    .collect(),
            );
            return;
        }
        eprintln!("error: {}", self.detail);
    }
}

/// **The exit status for an answer**, by its reason's type (docs/1.10). A
/// reason this build does not know, or a body from a server that predates
/// reasons, is read by its status.
fn exit_for(status: u16, problem: &api::ApiError) -> i32 {
    match problem.reason {
        // The loopback guard is a business error to the server, but for this
        // tool it is a setting at fault: `--server` does not name loopback.
        Some(Reason::AdminLoopbackOnly) => EXIT_FUNDAMENTAL,
        Some(Reason::Unknown) | None => exit_for_status(status),
        Some(reason) => match reason.error_type() {
            ErrorType::Business => EXIT_BUSINESS,
            ErrorType::Technical if reason.blip() => EXIT_BLIP,
            ErrorType::Technical => EXIT_FUNDAMENTAL,
            _ => EXIT_UNEXPECTED,
        },
    }
}

fn exit_for_status(status: u16) -> i32 {
    match status {
        401 => EXIT_FUNDAMENTAL,
        429 | 502 | 503 | 504 => EXIT_BLIP,
        400..=499 => EXIT_BUSINESS,
        _ => EXIT_UNEXPECTED,
    }
}

/// Whether this invocation is talking to a human or to a script. Threaded
/// through rather than read from a global so each command states which one
/// it's rendering for.
#[derive(Clone, Copy)]
struct Output {
    json: bool,
}

impl Output {
    /// Renders a successful mutation. The JSON form is an object rather
    /// than a bare string so a caller can add fields later without
    /// breaking whatever is parsing it.
    fn confirm(self, human: &str, machine: serde_json::Value) {
        if self.json {
            println!("{machine}");
        } else {
            println!("{human}");
        }
    }
}

/// Prints the daily record newest first, so today is the first line read.
fn run_size(
    client: &reqwest::blocking::Client,
    server: &str,
    output: Output,
) -> Result<(), Failure> {
    let rows: Vec<api::AdminDatabaseSizeDto> = check_response(
        client
            .get(format!("{server}/admin/database-size"))
            .send()
            .map_err(fmt_err)?,
    )?
    .json()
    .map_err(fmt_err)?;
    if output.json {
        return print_json(&rows);
    }
    if rows.is_empty() {
        println!(
            "Nothing recorded yet — the first row is written the next time somebody lists their games."
        );
        return Ok(());
    }
    print_table(
        &[
            "DAY",
            "PLAYERS",
            "SESSIONS",
            "GAMES",
            "INVITES",
            "CHAT",
            "IN MEMORY",
            "DB BYTES",
        ],
        rows.iter()
            .map(|row| {
                vec![
                    row.recorded_on.clone(),
                    row.players.to_string(),
                    row.sessions.to_string(),
                    row.games.to_string(),
                    row.invitations.to_string(),
                    row.chat_messages.to_string(),
                    row.games_in_memory.to_string(),
                    row.database_bytes.to_string(),
                ]
            })
            .collect(),
    );
    Ok(())
}

/// One row per job, in the order the server reports them.
fn run_scheduler_health(
    client: &reqwest::blocking::Client,
    server: &str,
    output: Output,
) -> Result<(), Failure> {
    let rows: Vec<api::AdminSchedulerJobHealthDto> = check_response(
        client
            .get(format!("{server}/admin/scheduler-health"))
            .send()
            .map_err(fmt_err)?,
    )?
    .json()
    .map_err(fmt_err)?;
    if output.json {
        return print_json(&rows);
    }
    if rows.is_empty() {
        println!("No scheduled job has reported yet — the server may have only just started.");
        return Ok(());
    }
    print_table(
        &["JOB", "LAST COMPLETED (UTC)", "ERRORED LAST PASS"],
        scheduler_health_rows(&rows),
    );
    Ok(())
}

fn scheduler_health_rows(rows: &[api::AdminSchedulerJobHealthDto]) -> Vec<Vec<String>> {
    rows.iter()
        .map(|row| {
            vec![
                row.job.clone(),
                row.last_completed_at
                    .map(format_timestamp_seconds)
                    .unwrap_or_else(|| "never".to_string()),
                row.errored_last_pass.to_string(),
            ]
        })
        .collect()
}

fn run_users(
    client: &reqwest::blocking::Client,
    server: &str,
    output: Output,
    action: UsersAction,
) -> Result<(), Failure> {
    match action {
        UsersAction::List => {
            let users: Vec<api::AdminPlayerSummaryDto> = check_response(
                client
                    .get(format!("{server}/admin/users"))
                    .send()
                    .map_err(fmt_err)?,
            )?
            .json()
            .map_err(fmt_err)?;
            if output.json {
                print_json(&users)?;
                return Ok(());
            }
            if users.is_empty() {
                println!("No users.");
                return Ok(());
            }
            print_table(
                &[
                    "ID",
                    "NAME",
                    "EMAIL",
                    "RATING",
                    "GAMES",
                    "CREATED (UTC)",
                    "LAST SEEN (UTC)",
                ],
                users
                    .iter()
                    .map(|user| {
                        vec![
                            user.id.clone(),
                            user.display_name.clone(),
                            user.email.clone(),
                            // An unrated account reads as "-", not as 1500:
                            // "has never finished a rated game" and "is rated,
                            // and sits at the starting value" are different
                            // facts about an account.
                            user.rating
                                .map_or_else(|| "-".to_string(), |rating| format!("{rating:.0}")),
                            user.games_rated.to_string(),
                            format_timestamp(user.created_at),
                            user.last_seen_at
                                .map_or_else(|| "never".to_string(), format_timestamp),
                        ]
                    })
                    .collect(),
            );
        }
        UsersAction::Delete { user } => {
            let player_id = resolve_user(client, server, &user)?;
            check_response(
                client
                    .delete(format!("{server}/admin/users/{player_id}"))
                    .send()
                    .map_err(fmt_err)?,
            )?;
            output.confirm(
                &format!("Deleted user {player_id}."),
                serde_json::json!({ "deleted": true, "player_id": player_id }),
            );
        }
        UsersAction::SignOut { user } => {
            let player_id = resolve_user(client, server, &user)?;
            check_response(
                client
                    .post(format!("{server}/admin/users/{player_id}/sign-out"))
                    .send()
                    .map_err(fmt_err)?,
            )?;
            output.confirm(
                &format!("Signed out {player_id}. Any delete refused for a live session can go ahead now."),
                serde_json::json!({ "signed_out": true, "player_id": player_id }),
            );
        }
        UsersAction::ResetPassword { user, password } => {
            let player_id = resolve_user(client, server, &user)?;
            let new_password = password.unwrap_or_else(generate_password);
            check_response(
                client
                    .post(format!("{server}/admin/users/{player_id}/reset-password"))
                    .json(&api::AdminResetPasswordRequest {
                        new_password: new_password.clone(),
                    })
                    .send()
                    .map_err(fmt_err)?,
            )?;
            output.confirm(
                &format!("Password reset for {player_id}.\nNew password: {new_password}"),
                serde_json::json!({ "player_id": player_id, "new_password": new_password }),
            );
        }
    }
    Ok(())
}

fn run_games(
    client: &reqwest::blocking::Client,
    server: &str,
    output: Output,
    action: GamesAction,
) -> Result<(), Failure> {
    match action {
        GamesAction::List {
            status,
            older_than_days,
        } => {
            let mut request = client.get(format!("{server}/admin/games"));
            let mut query = Vec::new();
            if let Some(status) = &status {
                query.push(("status", status.clone()));
            }
            if let Some(days) = older_than_days {
                query.push(("older_than_days", days.to_string()));
            }
            request = request.query(&query);

            let games: Vec<api::AdminGameSummaryDto> =
                check_response(request.send().map_err(fmt_err)?)?
                    .json()
                    .map_err(fmt_err)?;
            if output.json {
                print_json(&games)?;
                return Ok(());
            }
            if games.is_empty() {
                println!("No games match.");
                return Ok(());
            }
            print_table(
                &[
                    "ID",
                    "STATUS",
                    "CREATED (UTC)",
                    "LAST ACTIVITY (UTC)",
                    "SEATS",
                ],
                games
                    .iter()
                    .map(|game| {
                        vec![
                            game.id.clone(),
                            format!("{:?}", game.status).to_lowercase(),
                            format_timestamp(game.created_at),
                            format_timestamp(game.last_activity_at),
                            api::describe_seats(game.status, &game.participants),
                        ]
                    })
                    .collect(),
            );
        }
        GamesAction::Delete { game_id } => {
            check_response(
                client
                    .delete(format!("{server}/admin/games/{game_id}"))
                    .send()
                    .map_err(fmt_err)?,
            )?;
            output.confirm(
                &format!("Deleted game {game_id}."),
                serde_json::json!({ "deleted": true, "game_id": game_id }),
            );
        }
        GamesAction::ForceEnd { game_id } => {
            // The server returns the whole finished game, not just a status
            // code — worth showing, since the scores are the one thing an
            // operator wants to see after ending a game by hand.
            let finished: api::GameStateDto = check_response(
                client
                    .post(format!("{server}/admin/games/{game_id}/force-end"))
                    .send()
                    .map_err(fmt_err)?,
            )?
            .json()
            .map_err(fmt_err)?;
            if output.json {
                print_json(&finished)?;
                return Ok(());
            }
            println!("Game {game_id} marked finished.");
            println!("Final scores: {}", describe_final_scores(&finished));
        }
    }
    Ok(())
}

fn describe_final_scores(game: &api::GameStateDto) -> String {
    let mut seats: Vec<&api::ParticipantDto> = game.participants.iter().collect();
    seats.sort_by_key(|seat| seat.seat_number);
    seats
        .iter()
        .map(|seat| format!("{} {}", seat.display_name, seat.score))
        .collect::<Vec<_>>()
        .join(" vs ")
}

/// Prints rows under headers, padding each column to its widest cell. Fixed
/// widths were a guess that real data outgrew constantly — an e2e test
/// account's name and email both overflow any reasonable constant, and once
/// one cell overflows every column after it on that row is misaligned.
///
/// Width is measured in terminal columns, not `char`s (see `unicode-width`
/// in `Cargo.toml`), and the last column is never padded — trailing spaces
/// on every line serve nobody.
fn print_table(headers: &[&str], rows: Vec<Vec<String>>) {
    let widths: Vec<usize> = headers
        .iter()
        .enumerate()
        .map(|(column, header)| {
            rows.iter()
                .filter_map(|row| row.get(column))
                .map(|cell| cell.width())
                .chain(std::iter::once(header.width()))
                .max()
                .unwrap_or(0)
        })
        .collect();

    let render = |cells: &[String]| {
        let last = cells.len().saturating_sub(1);
        let line: String = cells
            .iter()
            .enumerate()
            .map(|(column, cell)| {
                if column == last {
                    cell.clone()
                } else {
                    let padding = widths[column].saturating_sub(cell.width());
                    format!("{cell}{}  ", " ".repeat(padding))
                }
            })
            .collect();
        println!("{line}");
    };

    render(
        &headers
            .iter()
            .map(|header| (*header).to_string())
            .collect::<Vec<_>>(),
    );
    for row in &rows {
        render(row);
    }
}

fn print_json<T: serde::Serialize>(value: &T) -> Result<(), Failure> {
    let rendered = serde_json::to_string_pretty(value)
        .map_err(|_| Failure::unexpected("The result could not be rendered as JSON."))?;
    println!("{rendered}");
    Ok(())
}

/// Renders one of the server's timestamps — seconds since the Unix epoch
/// (`game_state::now_unix_seconds`) — as a readable date-time.
///
/// Always UTC, which the column header states once rather than every row
/// repeating it. This is a server-side tool: the machine it runs on is the
/// deployment VM, whose local time is an accident of provisioning and not
/// something to silently reinterpret timestamps through. It also has to
/// line up with `--older-than-days`, which the server evaluates in absolute
/// seconds, and with the raw values in the database when someone goes
/// looking there. (`--json` sidesteps the question entirely: it emits the
/// epoch seconds the server actually sent.)
///
/// Falls back to the bare integer if the value can't be a real date, so an
/// impossible timestamp still shows the operator what's actually stored
/// instead of a blank or a lie.
fn format_timestamp(epoch_seconds: i64) -> String {
    chrono::DateTime::from_timestamp(epoch_seconds, 0)
        .map(|moment| moment.format("%Y-%m-%d %H:%M").to_string())
        .unwrap_or_else(|| epoch_seconds.to_string())
}

/// `format_timestamp` to the second, for the scheduler's five-second jobs.
fn format_timestamp_seconds(epoch_seconds: i64) -> String {
    chrono::DateTime::from_timestamp(epoch_seconds, 0)
        .map(|moment| moment.format("%Y-%m-%d %H:%M:%S").to_string())
        .unwrap_or_else(|| epoch_seconds.to_string())
}

/// A transport failure, in the operator's words and never reqwest's: a
/// connection that was refused or timed out is a blip, anything else is a
/// failure to read what came back.
fn fmt_err(error: reqwest::Error) -> Failure {
    if error.is_connect() || error.is_timeout() {
        Failure::unreachable(error.url().map(|u| u.as_str()).unwrap_or("the server"))
    } else if error.is_decode() || error.is_body() {
        Failure::unexpected("The server answered with something this tool cannot read.")
    } else {
        Failure::unreachable(error.url().map(|u| u.as_str()).unwrap_or("the server"))
    }
}

fn check_response(
    response: reqwest::blocking::Response,
) -> Result<reqwest::blocking::Response, Failure> {
    if response.status().is_success() {
        return Ok(response);
    }
    let status = response.status().as_u16();
    // A body this tool cannot parse is *unexpected*, whatever the status: a
    // proxy's page is not an answer from the server.
    let Ok(problem) = response.json::<api::ApiError>() else {
        return Err(Failure::unexpected(format!(
            "The server answered {status} with something this tool cannot read."
        )));
    };
    Err(Failure::from_problem(status, problem))
}

/// A 16-character password from a charset with visually-ambiguous
/// characters (0/O, 1/l/I) removed, since a human has to read this off a
/// terminal and type it somewhere.
/// Turn a display name or an account id into an id.
///
/// `display_name` is `not null unique` in the schema, so a name identifies
/// exactly one account — which is what makes accepting either safe. The
/// admin API only takes ids, so a name is resolved here by listing users
/// rather than by adding a lookup endpoint for one caller.
///
/// A value that matches no name is passed through unchanged and assumed to
/// be an id. That keeps every existing invocation working, and an id that
/// does not exist still fails at the API with a clear 404 — trying to
/// distinguish "not a name" from "not an id" here would only duplicate a
/// check the server already does.
fn resolve_user(
    client: &reqwest::blocking::Client,
    server: &str,
    user: &str,
) -> Result<String, Failure> {
    let users: Vec<api::AdminPlayerSummaryDto> = check_response(
        client
            .get(format!("{server}/admin/users"))
            .send()
            .map_err(fmt_err)?,
    )?
    .json()
    .map_err(fmt_err)?;

    match users
        .iter()
        .find(|candidate| candidate.display_name == user)
    {
        Some(found) => Ok(found.id.clone()),
        None => Ok(user.to_string()),
    }
}

fn generate_password() -> String {
    use rand::Rng;
    const CHARSET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
    let mut rng = rand::thread_rng();
    (0..16)
        .map(|_| CHARSET[rng.gen_range(0..CHARSET.len())] as char)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_an_epoch_second_as_a_utc_date_time() {
        // 2026-07-26 13:52:02 UTC — the timestamp of commit 8975493.
        assert_eq!(format_timestamp(1_785_073_922), "2026-07-26 13:52");
    }

    #[test]
    fn formats_the_epoch_itself() {
        assert_eq!(format_timestamp(0), "1970-01-01 00:00");
    }

    /// Timestamps are `i64` on the wire, so a negative one is representable
    /// even though the server never writes one; it should still read as a
    /// date rather than falling through to the raw-integer branch.
    #[test]
    fn formats_a_pre_epoch_timestamp() {
        assert_eq!(format_timestamp(-1), "1969-12-31 23:59");
    }

    /// The fallback: `i64::MAX` seconds is far outside any representable
    /// date, so the operator sees what's actually stored instead of a blank.
    #[test]
    fn falls_back_to_the_raw_value_when_it_cannot_be_a_date() {
        assert_eq!(format_timestamp(i64::MAX), i64::MAX.to_string());
    }

    #[test]
    fn scheduler_times_are_shown_to_the_second() {
        assert_eq!(
            format_timestamp_seconds(1_785_073_922),
            "2026-07-26 13:52:02"
        );
    }

    /// A job that has never completed must not read as one that completed
    /// at the epoch, nor as blank.
    #[test]
    fn a_job_that_never_ran_says_so() {
        let rows = scheduler_health_rows(&[
            api::AdminSchedulerJobHealthDto {
                job: "expire_overdue_turns".into(),
                last_completed_at: Some(1_785_073_922),
                errored_last_pass: 2,
            },
            api::AdminSchedulerJobHealthDto {
                job: "send_move_time_reminders".into(),
                last_completed_at: None,
                errored_last_pass: 0,
            },
        ]);
        assert_eq!(
            rows[0],
            ["expire_overdue_turns", "2026-07-26 13:52:02", "2"]
        );
        assert_eq!(rows[1], ["send_move_time_reminders", "never", "0"]);
    }

    /// T12: a panic in the tool exits 70, not Rust's 101.
    #[test]
    fn a_panic_exits_70() {
        assert_eq!(guarded(|| panic!("a defect in the tool")), 70);
        assert_eq!(guarded(|| 0), 0);
        assert_eq!(guarded(|| 1), 1);
    }

    /// T12: a connection that times out is a blip, said without reqwest's text.
    #[test]
    fn a_timeout_is_a_blip_in_the_operators_words() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        // Accepts, then says nothing.
        std::thread::spawn(move || {
            let held: Vec<_> = listener.incoming().take(1).collect();
            std::thread::sleep(std::time::Duration::from_secs(2));
            drop(held);
        });
        let client = reqwest::blocking::Client::builder()
            .timeout(std::time::Duration::from_millis(150))
            .build()
            .unwrap();
        let error = client
            .get(format!("http://{address}/admin/users"))
            .send()
            .expect_err("nothing answers");
        let failure = fmt_err(error);
        assert_eq!(failure.exit, 75);
        assert!(failure.detail.contains("Could not reach the server"));
        assert!(!failure.detail.contains("error sending request"));
        assert!(!failure.detail.contains("timed out"));
    }

    /// The classification, row by row, from the design's table.
    #[test]
    fn exit_for_reads_the_type_and_the_loopback_exception() {
        let problem = |reason| api::ApiError {
            reason: Some(reason),
            ..api::ApiError::default()
        };
        assert_eq!(exit_for(404, &problem(Reason::PlayerNotFound)), 1);
        assert_eq!(exit_for(403, &problem(Reason::AdminLoopbackOnly)), 2);
        assert_eq!(exit_for(401, &problem(Reason::SignInRequired)), 2);
        assert_eq!(exit_for(429, &problem(Reason::TooManyRequests)), 75);
        assert_eq!(exit_for(503, &problem(Reason::ServiceBusy)), 75);
        assert_eq!(exit_for(500, &problem(Reason::Internal)), 70);
    }
}
