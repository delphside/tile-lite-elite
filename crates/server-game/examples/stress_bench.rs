//! Dev-only stress harness: #404, drives each of the four load categories
//! the server already distinguishes — `trivial`, `ordinary`, `hash-bounded`,
//! `engine-bounded` — at rising concurrency, against a running server over
//! HTTP, and reports where each one starts failing.
//!
//! Never built or run as part of the shipped server/image (examples aren't
//! part of the release binary) — `cargo run --release --example
//! stress_bench` only, against a target this harness does not start itself.
//!
//! Usage:
//!
//!     cargo run --release --example stress_bench -- <base-url> [category]
//!
//! `category` is one of `trivial`, `ordinary`, `hash`, `engine`, or `all`
//! (the default). Steps concurrency through `CONCURRENCY_STEPS`, holding
//! each level for `STEP_DURATION` and recording latency and the error rate;
//! stops a category once the error rate crosses `ERROR_RATE_BREAKING_POINT`
//! and reports that as where it breaks.
//!
//! **Why passing, not playing, generates engine-bounded load.**
//! `GameSession::apply_pass` has one precondition — it must be the caller's
//! turn — and no move-legality check, so a harness that never thinks still
//! triggers a real `maybe_run_engine_turn` on every response. This is
//! deliberately not #10's bot client, which plays intelligently and is
//! blocked on #9's DTO-conversion move; this package does not need that.
//!
//! **Rate limits are the regression suite's problem too.** Run this against
//! rehearsal with `scripts/rehearsal-limits.sh regression` first, or every
//! category collapses into "the limiter", which answers a different
//! question from "the service".
//!
//! **What this does not yet do.** CPU, memory and steal on the *target*
//! host are not sampled here — the capacity plan already reads those over
//! SSH (`docs/reports/capacity_plan/`), and correlating a run here with a
//! host-side sample is the next increment, not built tonight.

use std::env;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use api::{
    CreateGameRequest, CreateSeatRequest, GameActionRequest, LoginPlayerRequest, PlayerActionDto,
    PlayerSessionDto, RegisterPlayerRequest, SeatClaim, SeatKind,
};
use reqwest::Client;

/// Concurrency levels tried in order. Doubling, because the interesting
/// question is an order of magnitude, not a smooth curve — the report asks
/// "where does it break", not "draw me the whole line".
const CONCURRENCY_STEPS: &[u32] = &[1, 2, 4, 8, 16, 32, 64, 128];

/// How long each concurrency level runs before moving to the next.
const STEP_DURATION: Duration = Duration::from_secs(10);

/// A category stops being reported once this fraction of requests in a step
/// fail or time out — the point R4 calls "where the service breaks".
const ERROR_RATE_BREAKING_POINT: f64 = 0.05;

/// Every request gets this long before it counts as a failure rather than a
/// slow success — long enough that a loaded server answering slowly isn't
/// mistaken for a broken one, short enough that a hung connection doesn't
/// stall the whole step.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Default)]
struct StepStats {
    latencies_ms: std::sync::Mutex<Vec<f64>>,
    successes: AtomicU64,
    failures: AtomicU64,
}

impl StepStats {
    fn record(&self, elapsed: Duration, ok: bool) {
        if ok {
            self.successes.fetch_add(1, Ordering::Relaxed);
            self.latencies_ms
                .lock()
                .unwrap()
                .push(elapsed.as_secs_f64() * 1000.0);
        } else {
            self.failures.fetch_add(1, Ordering::Relaxed);
        }
    }

    fn error_rate(&self) -> f64 {
        let ok = self.successes.load(Ordering::Relaxed);
        let bad = self.failures.load(Ordering::Relaxed);
        let total = ok + bad;
        if total == 0 {
            0.0
        } else {
            bad as f64 / total as f64
        }
    }

    /// `(peak, average)` over what succeeded. A gauge-shaped summary — see
    /// #291's design note, *4a* — because latency is read per request, not
    /// counted, and totalling it would mean nothing.
    fn peak_and_average_ms(&self) -> (f64, f64) {
        let latencies = self.latencies_ms.lock().unwrap();
        if latencies.is_empty() {
            return (f64::NAN, f64::NAN);
        }
        let peak = latencies.iter().cloned().fold(f64::MIN, f64::max);
        let average = latencies.iter().sum::<f64>() / latencies.len() as f64;
        (peak, average)
    }
}

/// One authenticated identity, provisioned before a category's timed window
/// starts — registration is itself rate-limited (2/min, burst 3), so
/// creating accounts inside the measurement loop would measure the
/// registration limiter, not the category.
struct Identity {
    session_token: String,
}

async fn register_and_login(client: &Client, base: &str, tag: &str) -> anyhow::Result<Identity> {
    let display_name = format!("stress-{tag}-{}", uuid_ish());
    let email = format!("{display_name}@example.invalid");
    let password = "throwaway-password-not-a-real-account";

    let resp = client
        .post(format!("{base}/auth/register"))
        .json(&RegisterPlayerRequest {
            display_name: display_name.clone(),
            email,
            password: password.to_string(),
            stay_logged_in: true,
        })
        .send()
        .await?;
    if !resp.status().is_success() {
        anyhow::bail!(
            "register {display_name} failed: {} {}",
            resp.status(),
            resp.text().await.unwrap_or_default()
        );
    }
    let session: PlayerSessionDto = resp.json().await?;
    Ok(Identity {
        session_token: session.session_token,
    })
}

/// Not a real UUID — this harness has no `uuid` dependency and does not need
/// one. Good enough to make display names distinct within one run.
fn uuid_ish() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    (nanos as u64) ^ (std::process::id() as u64).rotate_left(32)
}

// --- the four drivers, one call each -------------------------------------

/// **trivial** — no auth, no database, no compute.
async fn hit_health(client: &Client, base: &str) -> bool {
    client
        .get(format!("{base}/health"))
        .send()
        .await
        .map(|r| r.status().is_success())
        .unwrap_or(false)
}

/// **ordinary** — a session check plus a database query.
async fn hit_list_games(client: &Client, base: &str, identity: &Identity) -> bool {
    client
        .get(format!("{base}/games"))
        .bearer_auth(&identity.session_token)
        .send()
        .await
        .map(|r| r.status().is_success())
        .unwrap_or(false)
}

/// **hash-bounded** — one Argon2 verify, the cost `throttle.rs` already
/// records at ~47 ms. A fixed account registered once, logged into
/// repeatedly — the login itself is the measured operation, not the setup.
async fn hit_login(client: &Client, base: &str, display_name: &str, password: &str) -> bool {
    client
        .post(format!("{base}/auth/login"))
        .json(&LoginPlayerRequest {
            display_name: display_name.to_string(),
            password: password.to_string(),
            stay_logged_in: false,
        })
        .send()
        .await
        .map(|r| r.status().is_success())
        .unwrap_or(false)
}

/// **engine-bounded** — a dictionary search, triggered without the harness
/// having to think. See the module comment for why passing is enough.
struct EngineGame {
    id: String,
    seat_number: u8,
}

async fn create_engine_game(
    client: &Client,
    base: &str,
    identity: &Identity,
) -> anyhow::Result<EngineGame> {
    let resp = client
        .post(format!("{base}/games"))
        .bearer_auth(&identity.session_token)
        .json(&CreateGameRequest {
            seats: vec![
                CreateSeatRequest {
                    kind: SeatKind::Human,
                    display_name: "stress-human".to_string(),
                    engine_id: None,
                    claim: Some(SeatClaim::Creator),
                },
                CreateSeatRequest {
                    kind: SeatKind::Engine,
                    display_name: "stress-engine".to_string(),
                    engine_id: Some("greedy-v1".to_string()),
                    claim: None,
                },
            ],
            seed: None,
            variant: None,
            language: None,
            board_layout: None,
            move_time_limit_seconds: None,
        })
        .send()
        .await?;
    if !resp.status().is_success() {
        anyhow::bail!(
            "create game failed: {} {}",
            resp.status(),
            resp.text().await.unwrap_or_default()
        );
    }
    #[derive(serde::Deserialize)]
    struct Created {
        id: String,
    }
    let created: Created = resp.json().await?;

    let start = client
        .post(format!("{base}/games/{}/start", created.id))
        .bearer_auth(&identity.session_token)
        .send()
        .await?;
    if !start.status().is_success() {
        anyhow::bail!("start game failed: {}", start.status());
    }

    // Seat 0 is the creator by construction above.
    Ok(EngineGame {
        id: created.id,
        seat_number: 0,
    })
}

async fn hit_pass(client: &Client, base: &str, identity: &Identity, game: &EngineGame) -> bool {
    client
        .post(format!("{base}/games/{}/actions", game.id))
        .bearer_auth(&identity.session_token)
        .json(&GameActionRequest {
            seat_number: game.seat_number,
            action: PlayerActionDto::Pass,
        })
        .send()
        .await
        .map(|r| r.status().is_success())
        .unwrap_or(false)
}

// --- the ramp, shared across categories -----------------------------------

async fn run_step<F, Fut>(concurrency: u32, work: F) -> StepStats
where
    F: Fn() -> Fut + Send + Sync + 'static,
    Fut: std::future::Future<Output = bool> + Send,
{
    let stats = Arc::new(StepStats::default());
    let deadline = Instant::now() + STEP_DURATION;
    let work = Arc::new(work);

    let mut workers = Vec::new();
    for _ in 0..concurrency {
        let stats = Arc::clone(&stats);
        let work = Arc::clone(&work);
        workers.push(tokio::spawn(async move {
            while Instant::now() < deadline {
                let started = Instant::now();
                let ok = work().await;
                stats.record(started.elapsed(), ok);
            }
        }));
    }
    for w in workers {
        let _ = w.await;
    }

    Arc::try_unwrap(stats).unwrap_or_default()
}

async fn ramp_category<F, Fut>(name: &str, make_work: impl Fn() -> F)
where
    F: Fn() -> Fut + Send + Sync + 'static,
    Fut: std::future::Future<Output = bool> + Send,
{
    println!("== {name} ==");
    println!("  concurrency  peak_ms  avg_ms  error_rate  n");
    for &concurrency in CONCURRENCY_STEPS {
        let stats = run_step(concurrency, make_work()).await;
        let (peak, avg) = stats.peak_and_average_ms();
        let rate = stats.error_rate();
        let n = stats.successes.load(Ordering::Relaxed) + stats.failures.load(Ordering::Relaxed);
        println!(
            "  {concurrency:>11}  {peak:>7.1}  {avg:>6.1}  {:>9.1}%  {n}",
            rate * 100.0
        );
        if rate > ERROR_RATE_BREAKING_POINT {
            println!(
                "  -- {name} breaks between {} and {concurrency} concurrent, at {:.1}% error rate --",
                CONCURRENCY_STEPS
                    .iter()
                    .take_while(|&&c| c < concurrency)
                    .last()
                    .copied()
                    .unwrap_or(0),
                rate * 100.0
            );
            return;
        }
    }
    println!("  -- {name} did not break within the concurrency steps tried --");
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = env::args().collect();
    let base = args
        .get(1)
        .cloned()
        .unwrap_or_else(|| "http://127.0.0.1:3000".to_string());
    let category = args.get(2).cloned().unwrap_or_else(|| "all".to_string());

    let client = Client::builder().timeout(REQUEST_TIMEOUT).build()?;

    println!("stress_bench against {base}, category={category}");
    println!(
        "steps: {CONCURRENCY_STEPS:?}, {}s each, breaking point at {:.0}% errors\n",
        STEP_DURATION.as_secs(),
        ERROR_RATE_BREAKING_POINT * 100.0
    );

    if category == "trivial" || category == "all" {
        let client = client.clone();
        let base = base.clone();
        ramp_category("trivial (/health)", move || {
            let client = client.clone();
            let base = base.clone();
            move || {
                let client = client.clone();
                let base = base.clone();
                async move { hit_health(&client, &base).await }
            }
        })
        .await;
    }

    if category == "ordinary" || category == "all" {
        // One identity shared by every worker: the endpoint under test reads
        // the caller's own games, and a shared, quiet account keeps the
        // *query* the same cost on every call rather than growing with how
        // many games this run itself creates.
        let identity = Arc::new(register_and_login(&client, &base, "ordinary").await?);
        let client = client.clone();
        let base = base.clone();
        ramp_category("ordinary (GET /games)", move || {
            let client = client.clone();
            let base = base.clone();
            let identity = Arc::clone(&identity);
            move || {
                let client = client.clone();
                let base = base.clone();
                let identity = Arc::clone(&identity);
                async move { hit_list_games(&client, &base, &identity).await }
            }
        })
        .await;
    }

    if category == "hash" || category == "all" {
        let display_name = format!("stress-hash-{}", uuid_ish());
        let password = "throwaway-password-not-a-real-account";
        client
            .post(format!("{base}/auth/register"))
            .json(&RegisterPlayerRequest {
                display_name: display_name.clone(),
                email: format!("{display_name}@example.invalid"),
                password: password.to_string(),
                stay_logged_in: false,
            })
            .send()
            .await?;
        let client = client.clone();
        let base = base.clone();
        ramp_category("hash-bounded (POST /auth/login)", move || {
            let client = client.clone();
            let base = base.clone();
            let display_name = display_name.clone();
            move || {
                let client = client.clone();
                let base = base.clone();
                let display_name = display_name.clone();
                async move { hit_login(&client, &base, &display_name, password).await }
            }
        })
        .await;
    }

    if category == "engine" || category == "all" {
        // One identity and one game per worker would need CONCURRENCY_STEPS'
        // max provisioned up front to keep setup out of the timed window —
        // not built tonight. This runs at concurrency 1 only, against one
        // game, which is enough to measure per-move cost but not the
        // breaking rate the design note asks for.
        println!("== engine-bounded (POST /games/{{id}}/actions, pass) ==");
        println!("  NOT YET RAMPED — concurrency 1 only, see the module comment.");
        let identity = register_and_login(&client, &base, "engine").await?;
        let game = create_engine_game(&client, &base, &identity).await?;
        let stats = StepStats::default();
        let deadline = Instant::now() + STEP_DURATION;
        while Instant::now() < deadline {
            let started = Instant::now();
            let ok = hit_pass(&client, &base, &identity, &game).await;
            stats.record(started.elapsed(), ok);
            if !ok {
                break; // the game likely ended; a fresh-game loop is the next increment
            }
        }
        let (peak, avg) = stats.peak_and_average_ms();
        println!(
            "  concurrency=1  peak_ms={peak:.1}  avg_ms={avg:.1}  error_rate={:.1}%  n={}",
            stats.error_rate() * 100.0,
            stats.successes.load(Ordering::Relaxed) + stats.failures.load(Ordering::Relaxed)
        );
    }

    Ok(())
}
