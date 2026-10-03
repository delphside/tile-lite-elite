//! Dev-only load test: do the limits in #11 and #25 behave the way they are
//! documented to, on hardware the size of the one they protect? Never built
//! into the shipped image — examples are not part of the release binary — so
//! this is a `cargo run --example` tool only.
//!
//! Usage:
//!
//! ```text
//! cargo run --release --example rate_limit_load -- https://rehearsal-host
//! cargo run --release --example rate_limit_load          # $REHEARSAL_URL
//! ```
//!
//! **Run it against rehearsal**, which is why that environment exists: the
//! same 2 vCPU / 954 MB shape as production, production's data, and nobody
//! watching. Numbers taken on a development machine say nothing about the box
//! the limits exist to protect. Pointing it at production is refused outright.
//!
//! It asserts the **rules**, not the throughput. Throughput ages the moment
//! the hardware or the workload changes; the rules are what should still be
//! true afterwards, and each check below names the one it is pinning. Measured
//! numbers are still recorded — appended to `rate_limit_results.csv` beside
//! this file — so a change over time shows up as a diff rather than as a
//! memory of what the number used to be. That is the `engine_timing_bench`
//! pattern, for the same reason.
//!
//! Request shapes come from the `api` crate's own DTOs. A load test that
//! builds JSON by hand drifts from the contract silently, and then passes
//! while testing something the server no longer accepts.
//!
//! **What this cannot test, and why.** Caddy replaces `X-Forwarded-For` with
//! the address the connection came from, so every request from one machine is
//! one caller however the header is set — see
//! `docs/changes/25-rate-limiting.md`. Two checks were written here on the
//! assumption that addresses could be spoofed, and would have reported
//! confidently on nothing:
//!
//! - **the global floor**, which needs enough traffic to pass it without
//!   tripping a keyed tier first — impossible from one address, since the
//!   per-caller limit binds long before 1200/min
//! - **the hashing semaphore**, which needs concurrent logins that are not
//!   refused for frequency — and heavy auth refuses them at ten a minute
//!
//! Both need either many real sources or the keyed limits raised on the host
//! for the duration. That is #91's rig, not this one's. The session check
//! below *does* work, because the authenticated tier keys on the session token
//! rather than the address, and two sessions from one machine are genuinely
//! two callers.

use std::fmt::Write as _;
use std::fs::OpenOptions;
use std::io::Write as _;
use std::process::Command;
use std::time::{Duration, Instant};

use api::{LoginPlayerRequest, RegisterPlayerRequest};

const RESULTS_CSV_HEADER: &str = "timestamp_unix_seconds,git_commit,host,target,per_ip_refused_after,health_under_load,sessions_separate,registration_refused_after,hash_median_ms,checks_failed\n";

/// Argon2 at the OWASP profile costs ~47 ms on the production box. A hash that
/// suddenly takes ~1 ms means somebody weakened the parameters, which is a
/// silent reduction in the strength of every stored password. The band is
/// deliberately wide: this is a "has the cost collapsed" check, not a
/// benchmark.
const HASH_MS_FLOOR: u128 = 15;
const HASH_MS_CEILING: u128 = 400;

struct Report {
    failures: Vec<String>,
    checks: usize,
}

impl Report {
    fn new() -> Self {
        Self {
            failures: Vec::new(),
            checks: 0,
        }
    }

    /// Records one rule. `held` is the rule; `detail` says what was actually
    /// seen, so a pass is as informative as a failure — a check that only
    /// speaks up when it fails leaves you guessing whether it ran.
    fn rule(&mut self, name: &str, held: bool, detail: impl AsRef<str>) {
        self.checks += 1;
        if held {
            println!("  ok   {name} — {}", detail.as_ref());
        } else {
            println!("  FAIL {name} — {}", detail.as_ref());
            self.failures.push(name.to_string());
        }
    }
}

fn git_commit_label() -> String {
    let hash = Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".to_string());
    let dirty = Command::new("git")
        .args(["status", "--porcelain"])
        .output()
        .ok()
        .map(|o| !o.stdout.is_empty())
        .unwrap_or(false);
    if dirty { format!("{hash}-dirty") } else { hash }
}

fn hostname() -> String {
    Command::new("hostname")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".to_string())
}

fn append_result_row(row: &str) -> std::io::Result<std::path::PathBuf> {
    let path =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/rate_limit_results.csv");
    let is_new_file = !path.exists();
    let mut file = OpenOptions::new().create(true).append(true).open(&path)?;
    if is_new_file {
        file.write_all(RESULTS_CSV_HEADER.as_bytes())?;
    }
    file.write_all(row.as_bytes())?;
    Ok(path)
}

fn now_unix_seconds() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// A run tag, so a second run is not refused by the buckets the first one
/// filled and the accounts it creates do not collide.
fn run_tag() -> String {
    format!("{:x}", now_unix_seconds() & 0xff_ffff)
}

/// The rehearsal access key (#240), the way `scripts/rehearsal-key.sh` gets
/// one — over ssh, or `REHEARSAL_ACCESS_KEY` to short-circuit it. Before this,
/// `check-rate-limits.sh` knew how to get in and this example did not, which
/// is #371: every request came back 403 from the gate, a closed door that
/// looks exactly like a broken limiter.
fn rehearsal_gate_cookie() -> Option<String> {
    let script =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/rehearsal-key.sh");
    let output = Command::new(&script).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let key = String::from_utf8(output.stdout).ok()?.trim().to_string();
    (!key.is_empty()).then_some(key)
}

async fn status_of(request: reqwest::RequestBuilder) -> u16 {
    match request.send().await {
        Ok(response) => response.status().as_u16(),
        // A refused connection is a result, not a crash: reported as 0 so the
        // check that wanted a status fails rather than the run dying.
        Err(_) => 0,
    }
}

#[tokio::main]
async fn main() {
    let target = std::env::args().nth(1).unwrap_or_else(|| {
        std::env::var("REHEARSAL_URL")
            .unwrap_or_else(|_| "https://129.151.84.183.sslip.io".to_string())
    });

    // This deliberately exhausts allowances and saturates the hashing pool.
    // Doing that to production would be an outage caused by a test.
    if target.contains("tileliteelite.com") {
        eprintln!("refusing to load-test production ({target}) — use the rehearsal host");
        std::process::exit(2);
    }

    let mut default_headers = reqwest::header::HeaderMap::new();
    match rehearsal_gate_cookie() {
        Some(key) => {
            if let Ok(value) = reqwest::header::HeaderValue::from_str(&format!("rehearsal={key}")) {
                default_headers.insert(reqwest::header::COOKIE, value);
            }
        }
        None => {
            eprintln!("warning: no rehearsal access key — every request will be refused by the");
            eprintln!("         gate, and a refusal at the door looks exactly like a broken");
            eprintln!("         limiter. Run ./scripts/rehearsal-access.sh grant first.");
        }
    }

    let client = match reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .default_headers(default_headers)
        .build()
    {
        Ok(client) => client,
        Err(error) => {
            eprintln!("could not build an http client: {error}");
            std::process::exit(2);
        }
    };

    let tag = run_tag();
    println!("==> Rate limits under load on {target}  (run {tag})");
    println!();

    let mut report = Report::new();

    // One address for the whole run, because there is only ever one: Caddy
    // replaces the header with where the connection came from. Randomised only
    // so a re-run is not refused by the bucket the last one filled.
    let address = format!("203.0.113.{}", 1 + (now_unix_seconds() % 250));

    let (seeded, registration_refused_after) =
        match probe_registration_limit(&client, &target, &tag, &address, &mut report).await {
            RegistrationProbeOutcome::Reached {
                seeded,
                refused_after,
            } => (seeded, refused_after),
            // R3: a run that never reached the service records nothing, rather
            // than the other three checks each failing for the same reason and
            // the run reading as a broken limiter instead of a closed door.
            RegistrationProbeOutcome::Unreachable { at_attempt, detail } => {
                eprintln!("could not reach {target} at all — attempt {at_attempt} got {detail}.");
                eprintln!(
                    "A closed rehearsal gate (#240) and a broken rate limiter refuse identically;"
                );
                eprintln!("this is the gate. Run ./scripts/rehearsal-access.sh grant, or check");
                eprintln!("REHEARSAL_ACCESS_KEY / REHEARSAL_SSH_HOST, then try again.");
                std::process::exit(2);
            }
        };
    let sessions_separate =
        check_sessions_are_separate(&client, &target, &address, &seeded, &mut report).await;
    let hash_median_ms = check_hash_cost(&client, &target, &address, &seeded, &mut report).await;
    let health_under_load = check_health_is_never_limited(&client, &target, &mut report).await;
    let per_ip_refused_after = registration_refused_after.clone();

    let mut row = String::new();
    let _ = writeln!(
        row,
        "{},{},{},{},{},{},{},{},{},{}",
        now_unix_seconds(),
        git_commit_label(),
        hostname(),
        target,
        per_ip_refused_after,
        health_under_load,
        sessions_separate,
        registration_refused_after,
        hash_median_ms,
        report.failures.len(),
    );

    println!();
    match append_result_row(&row) {
        Ok(path) => println!("recorded to {}", path.display()),
        Err(error) => eprintln!("failed to record results: {error}"),
    }

    if report.failures.is_empty() {
        println!("all {} rules held.", report.checks);
    } else {
        eprintln!(
            "{} of {} rules failed: {}",
            report.failures.len(),
            report.checks,
            report.failures.join(", ")
        );
        std::process::exit(1);
    }
}

/// One account created by the probe below: enough to sign in as, later.
struct SeededAccount {
    name: String,
    token: String,
}

/// What the registration probe found: either it reached the service, in which
/// case the limit itself has an answer (held or not); or it did not, in which
/// case the limit has no answer at all and saying so is the honest result.
enum RegistrationProbeOutcome {
    Reached {
        seeded: Vec<SeededAccount>,
        refused_after: String,
    },
    Unreachable {
        at_attempt: usize,
        detail: String,
    },
}

/// LIMIT-1 and LIMIT-2, and the setup for everything after it — the same act.
///
/// Registers until refused. What comes back is both the measurement (how many
/// got through, and that the refusal happened at all) and the accounts the
/// later checks need to sign in with.
///
/// **They have to be the same act.** Every request from this machine is one
/// caller — Caddy replaces the forwarded header — so the registration
/// allowance is a single small budget shared by the whole run. An earlier
/// version spent it proving the limit worked and then found it had nothing
/// left to register the accounts the other checks needed, and reported three
/// failures that were all itself.
async fn probe_registration_limit(
    client: &reqwest::Client,
    target: &str,
    tag: &str,
    address: &str,
    report: &mut Report,
) -> RegistrationProbeOutcome {
    let mut seeded: Vec<SeededAccount> = Vec::new();
    let mut refused_after: Option<usize> = None;

    for attempt in 1..=12usize {
        let name = format!("loadtest-{tag}-{attempt}");
        let response = client
            .post(format!("{target}/auth/register"))
            .header("x-forwarded-for", address)
            .json(&RegisterPlayerRequest {
                display_name: name.clone(),
                email: format!("{name}@example.com"),
                password: "correct horse battery staple".to_string(),
                stay_logged_in: false,
            })
            .send()
            .await;

        match response {
            Ok(r) if r.status().as_u16() == 429 => {
                refused_after = Some(attempt - 1);
                break;
            }
            Ok(r) if r.status().is_success() => {
                if let Ok(body) = r.json::<serde_json::Value>().await
                    && let Some(token) = body["session_token"].as_str()
                {
                    seeded.push(SeededAccount {
                        name,
                        token: token.to_string(),
                    });
                }
            }
            // Neither a refusal the limiter makes nor a success: the probe does
            // not understand this response, so it says so rather than reading
            // it as a rule failure (#371 R2). A 403 from the rehearsal access
            // gate (#240) looks exactly like this, and used to be reported as
            // "twelve attempts from one address were all accepted" — the
            // opposite of what happened, since the loop broke on the first
            // attempt and never made a second one.
            Ok(r) => {
                return RegistrationProbeOutcome::Unreachable {
                    at_attempt: attempt,
                    detail: format!("HTTP {}", r.status().as_u16()),
                };
            }
            Err(error) => {
                return RegistrationProbeOutcome::Unreachable {
                    at_attempt: attempt,
                    detail: error.to_string(),
                };
            }
        }
    }

    report.rule(
        "the first registration is not refused",
        !seeded.is_empty(),
        format!("{} got through", seeded.len()),
    );

    let refused_after = match refused_after {
        Some(count) => {
            report.rule(
                "registering repeatedly from one address is refused (429)",
                true,
                format!("after {count}"),
            );
            // The default is 2/min with a burst of 3, so a handful through is
            // right and a dozen is not. The order of magnitude is the
            // assertion; the exact figure is tunable per host by design.
            report.rule(
                "and the allowance is small",
                count <= 8,
                format!("{count} accepted before refusal"),
            );
            count.to_string()
        }
        None => {
            report.rule(
                "registering repeatedly from one address is refused (429)",
                false,
                "twelve attempts from one address were all accepted",
            );
            "never".to_string()
        }
    };

    RegistrationProbeOutcome::Reached {
        seeded,
        refused_after,
    }
}

/// LIMIT-3, and the one separation that *can* be seen from outside: the
/// authenticated tier keys on the session token, so two sessions from one
/// machine are genuinely two callers even though one address is.
async fn check_sessions_are_separate(
    client: &reqwest::Client,
    target: &str,
    address: &str,
    seeded: &[SeededAccount],
    report: &mut Report,
) -> String {
    if seeded.len() < 2 {
        report.rule(
            "two sessions from one address are two callers",
            false,
            format!(
                "needed two accounts, the registration probe yielded {}",
                seeded.len()
            ),
        );
        return "untested".to_string();
    }

    // Spend the first session's allowance, then ask whether the second still
    // answers.
    for _ in 0..80 {
        let _ = status_of(
            client
                .get(format!("{target}/engines"))
                .header("x-forwarded-for", address)
                .bearer_auth(&seeded[0].token),
        )
        .await;
    }
    let second = status_of(
        client
            .get(format!("{target}/engines"))
            .header("x-forwarded-for", address)
            .bearer_auth(&seeded[1].token),
    )
    .await;

    let held = second != 429;
    report.rule(
        "two sessions from one address are two callers",
        held,
        format!("the second session got {second} after the first had been busy"),
    );
    held.to_string()
}

/// A hash still costs what it should. Not a benchmark — a collapse detector.
/// Argon2's cost is the whole of a stored password's strength, and it can be
/// weakened by a one-line change nothing else would notice.
async fn check_hash_cost(
    client: &reqwest::Client,
    target: &str,
    address: &str,
    seeded: &[SeededAccount],
    report: &mut Report,
) -> String {
    let Some(account) = seeded.first() else {
        report.rule(
            "a password hash still costs what it should",
            false,
            "the registration probe yielded no account to log in as",
        );
        return "untested".to_string();
    };

    // A *wrong* password against a real account: the account exists, so the
    // server verifies rather than short-circuiting, and nothing is left signed
    // in afterwards.
    let mut samples = Vec::new();
    for _ in 0..5 {
        let started = Instant::now();
        let _ = status_of(
            client
                .post(format!("{target}/auth/login"))
                .header("x-forwarded-for", address)
                .json(&LoginPlayerRequest {
                    display_name: account.name.clone(),
                    password: "not the right password".to_string(),
                    stay_logged_in: false,
                }),
        )
        .await;
        samples.push(started.elapsed().as_millis());
    }
    samples.sort_unstable();
    let median = samples[samples.len() / 2];

    // Network time is included and cannot be subtracted, so the floor is what
    // carries the check: a round trip cannot be *faster* than the hash inside
    // it. A login refused for frequency returns without hashing at all, which
    // would read as a collapse — hence the ceiling on attempts above.
    report.rule(
        "a password hash still costs what it should",
        (HASH_MS_FLOOR..=HASH_MS_CEILING).contains(&median),
        format!("median login round trip {median} ms (including network)"),
    );
    median.to_string()
}

/// LIMIT-4. `/health` is never limited, at any rate — `deploy.sh` smoke-tests
/// it and `rollback.sh` polls it, so a health check that fails under load
/// would report an outage that is not happening and roll back a release that
/// was merely busy. Checked *after* the global probe, while everything else is
/// still being refused.
async fn check_health_is_never_limited(
    client: &reqwest::Client,
    target: &str,
    report: &mut Report,
) -> bool {
    let mut worst = 200u16;
    for _ in 0..30 {
        let status = status_of(client.get(format!("{target}/health"))).await;
        if status != 200 {
            worst = status;
            break;
        }
    }
    let held = worst == 200;
    report.rule(
        "/health is never limited",
        held,
        format!("thirty checks while the service was refusing others, worst status {worst}"),
    );
    held
}
