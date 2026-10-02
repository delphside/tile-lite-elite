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

use clap::{Parser, Subcommand};
use unicode_width::UnicodeWidthStr;

#[derive(Parser)]
#[command(
    name = "tile-lite-elite-admin",
    about = "Administer a tile-lite-elite server (users, games). Must run on the same machine as the server."
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
    let cli = Cli::parse();
    let client = reqwest::blocking::Client::new();
    let output = Output { json: cli.json };

    let result = match cli.command {
        Command::Users { action } => run_users(&client, &cli.server, output, action),
        Command::Games { action } => run_games(&client, &cli.server, output, action),
        Command::Size => run_size(&client, &cli.server, output),
    };

    if let Err(error) = result {
        eprintln!("error: {error}");
        std::process::exit(1);
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
) -> Result<(), String> {
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

fn run_users(
    client: &reqwest::blocking::Client,
    server: &str,
    output: Output,
    action: UsersAction,
) -> Result<(), String> {
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
) -> Result<(), String> {
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

fn print_json<T: serde::Serialize>(value: &T) -> Result<(), String> {
    let rendered = serde_json::to_string_pretty(value)
        .map_err(|error| format!("could not render: {error}"))?;
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

fn fmt_err(error: reqwest::Error) -> String {
    format!(
        "could not reach {}: {error}",
        error.url().map(|u| u.as_str()).unwrap_or("server")
    )
}

fn check_response(
    response: reqwest::blocking::Response,
) -> Result<reqwest::blocking::Response, String> {
    if response.status().is_success() {
        return Ok(response);
    }
    let status = response.status();
    let Ok(problem) = response.json::<api::ApiError>() else {
        return Err(status.to_string());
    };
    // A refusal that names games gets the same table `games list` prints, so
    // an operator does not have to translate between two descriptions of the
    // same thing. Printed here rather than folded into the error string
    // because it is output, not a reason — the reason follows it.
    if !problem.blocking_games.is_empty() {
        eprintln!("{status}: {}", problem.message);
        eprintln!();
        print_table(
            &["ID", "STATUS", "LAST ACTIVITY (UTC)", "SEATS"],
            problem
                .blocking_games
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
        std::process::exit(1);
    }
    Err(format!("{status}: {}", problem.message))
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
) -> Result<String, String> {
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
}
