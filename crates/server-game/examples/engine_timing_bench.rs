//! Dev-only benchmark: how long `GreedyEngine::choose_action` actually
//! takes per move, measured across real games (not synthetic positions) —
//! plays engine-vs-engine games start to finish via the exact same
//! `GameSession::maybe_run_engine_turn` production Bot Showdown games use,
//! timing each call. Never built or run as part of the shipped
//! server/image (examples aren't part of the release binary) — this is a
//! `cargo run --example` tool only.
//!
//! Usage: `cargo run --release --example engine_timing_bench [num_games]`
//! (release build matters here — move generation is meaningfully slower
//! under a debug build, and would skew the numbers away from what a real
//! deployed server actually experiences).
//!
//! Every run appends one row to `engine_timing_results.csv` (alongside
//! this file, found via `CARGO_MANIFEST_DIR` so it works regardless of
//! the directory `cargo run` was invoked from) — a running, git-committed
//! log of every benchmark run, so later runs (e.g. after an engine change)
//! can be compared against earlier ones rather than only ever seeing the
//! latest numbers.

use std::fs::OpenOptions;
use std::io::Write;
use std::process::Command;
use std::time::{Duration, Instant};

use api::{GameStatus, SeatKind};
use rules_shared::MoveGenerator as _;
use rules_shared::{Rack, VariantRules};
use server_game::game_state::{EngineRegistry, GameSession, ParticipantState};

const RESULTS_CSV_HEADER: &str = "timestamp_unix_seconds,git_commit,host,edition,num_games,games_completed,samples,min_ms,q1_ms,median_ms,mean_ms,q3_ms,p95_ms,p99_ms,max_ms,first_move_median_ms,first_move_mean_ms,first_move_max_ms,cpu_median_ms,cpu_mean_ms,cpu_p99_ms,run_wall_s,steal_ms,steal_pct_of_capacity,cpu_model,cores,slow_moves,slow_cpu_starved\n";

/// CPU time consumed by this process so far, in milliseconds.
///
/// `CLOCK_PROCESS_CPUTIME_ID`, not `CLOCK_THREAD_CPUTIME_ID`, and the
/// difference is the whole measurement: `maybe_run_engine_turn` hands the
/// search to `tokio::task::spawn_blocking`, so it runs on a *different*
/// thread. Reading the calling thread's clock would report a move as costing
/// no CPU at all. Nothing else in the process is doing work while a move is
/// being timed, so the process clock attributes it correctly.
fn process_cpu_ms() -> f64 {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // Safe: `ts` is a valid, correctly-typed output parameter, and the call
    // writes nothing else.
    if unsafe { libc::clock_gettime(libc::CLOCK_PROCESS_CPUTIME_ID, &mut ts) } != 0 {
        return f64::NAN;
    }
    ts.tv_sec as f64 * 1000.0 + ts.tv_nsec as f64 / 1_000_000.0
}

/// Milliseconds this machine has spent as *steal* since boot: runnable, but
/// waiting for a hypervisor that gave the physical CPU to somebody else.
///
/// Field 8 of `/proc/stat`'s `cpu ` line, in USER_HZ, summed over every core.
/// System-wide rather than per-process — the kernel does not attribute steal
/// to whoever lost the time — so it is read once either side of the whole run
/// and reported per run, not per move. That is enough to answer whether a run
/// was competing for a core, which is the question.
fn steal_ms_since_boot() -> Option<f64> {
    let stat = std::fs::read_to_string("/proc/stat").ok()?;
    let cpu_line = stat.lines().find(|line| line.starts_with("cpu "))?;
    let steal_jiffies: f64 = cpu_line.split_whitespace().nth(8)?.parse().ok()?;
    // Safe: `sysconf` takes a name and returns a long; no pointers involved.
    let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) } as f64;
    if hz <= 0.0 {
        return None;
    }
    Some(steal_jiffies * 1000.0 / hz)
}

/// The CPU this ran on, as the kernel names it, with commas removed so it can
/// sit in a CSV field. Recorded rather than folded into the host label: it
/// makes a row self-describing without anyone choosing an abbreviation.
/// A frequency histogram of the move timings, in 100 buckets spanning zero to
/// the slowest move — 1% of the range each.
///
/// The percentiles say where the distribution sits; this says what shape it is,
/// and the shape is the argument. Genuine search cost falls away smoothly from
/// zero. A second clump far out, separated from the first by empty buckets, is
/// not a slower kind of move: it is the hypervisor descheduling the vCPU, and
/// on a machine nobody else is sharing it does not appear at all.
///
/// Bars are logarithmic. A linear bar would put 1100 moves in the first bucket
/// and render every bucket in the tail as nothing, which is exactly the part
/// worth seeing — so the count is printed beside each bar rather than inferred
/// from its length. Runs of empty buckets are collapsed to one line, because
/// the gap is information but its individual buckets are not.
fn print_histogram(sorted_ms: &[f64]) {
    const BUCKETS: usize = 100;
    let max = match sorted_ms.last() {
        Some(m) if *m > 0.0 => *m,
        _ => return,
    };
    let width = max / BUCKETS as f64;
    let mut counts = [0usize; BUCKETS];
    for ms in sorted_ms {
        let idx = ((ms / width) as usize).min(BUCKETS - 1);
        counts[idx] += 1;
    }
    let peak = counts.iter().copied().max().unwrap_or(1).max(1);
    let scale = |n: usize| -> usize {
        if n == 0 {
            0
        } else {
            // log so a bucket holding three moves is still visible beside one
            // holding a thousand.
            (1.0 + 44.0 * (n as f64).ln() / (peak as f64).ln()).round() as usize
        }
    };

    println!();
    println!("distribution, 100 buckets of {width:.2} ms (bars are logarithmic):");
    let mut empty_run = 0usize;
    for (i, &n) in counts.iter().enumerate() {
        if n == 0 {
            empty_run += 1;
            continue;
        }
        if empty_run > 0 {
            let plural = if empty_run == 1 { "bucket" } else { "buckets" };
            println!(
                "      {:>26}",
                format!("... {empty_run} empty {plural} ...")
            );
            empty_run = 0;
        }
        println!(
            "  {:>6.1}-{:<6.1} ms {:<45} {n}",
            i as f64 * width,
            (i + 1) as f64 * width,
            "#".repeat(scale(n))
        );
    }
}

fn num_cores() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(0)
}

fn cpu_model() -> String {
    std::fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|info| {
            info.lines()
                .find(|line| line.starts_with("model name"))
                .and_then(|line| line.split_once(':'))
                .map(|(_, value)| value.trim().replace(',', " "))
        })
        .unwrap_or_else(|| "unknown".to_string())
}

/// The short commit hash `HEAD` is on, with a `-dirty` suffix if the working
/// tree has uncommitted changes — unlike a real deploy (which refuses a
/// dirty tree), benchmarking mid-change is completely normal here, so this
/// records rather than blocks it. `"unknown"` if `git` isn't available at
/// all (e.g. run from outside a checkout).
fn git_commit_label() -> String {
    let hash = Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "unknown".to_string());
    // Excluding what this benchmark itself writes. Without that, the first run
    // records a clean commit and every run after it says `-dirty`, because the
    // results row and the per-move file it just wrote are the uncommitted
    // change. Everything else still counts as dirty, which is the point.
    let dirty = Command::new("git")
        .args([
            "status",
            "--porcelain",
            "--",
            ".",
            ":!crates/server-game/examples/engine_timing_results.csv",
            ":!crates/server-game/examples/moves",
        ])
        .output()
        .ok()
        .is_some_and(|output| output.status.success() && !output.stdout.is_empty());
    if dirty { format!("{hash}-dirty") } else { hash }
}

/// The engine workload is memory-bound in its dictionary access, so the
/// machine is part of the result — the same binary's p99 differs 6x between
/// a modern laptop and the deployment VM.
///
/// The hostname, and nothing else. There was a `BENCH_HOST` override, and it
/// produced three labels for two machines: `stephen-len` and
/// `laptop-ryzen7235hs` are the same laptop, which read as two until somebody
/// checked. A label that can be typed will eventually be typed differently.
/// What the override was really for — a hostname that does not say what the
/// hardware is — is answered by the `cpu_model` and `cores` columns instead.
fn host_label() -> String {
    Command::new("hostname")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".to_string())
}

const MOVES_CSV_HEADER: &str = "run,game,turn,seat,blanks,rack_tiles,n_moves,wall_ms,cpu_ms\n";

/// Writes the per-move rows for one run, named by the run's timestamp and host
/// so it joins to the summary CSV's `timestamp_unix_seconds` column.
///
/// A file per run rather than one growing file: 1229 rows an entry makes a
/// single CSV unopenable within a dozen runs, and a run is the unit anybody
/// wants to load anyway.
fn write_moves_file(run: u64, host: &str, rows: &[String]) -> std::io::Result<std::path::PathBuf> {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/moves");
    std::fs::create_dir_all(&dir)?;
    let safe_host: String = host
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    let path = dir.join(format!("{run}-{safe_host}.csv"));
    let mut file = std::fs::File::create(&path)?;
    file.write_all(MOVES_CSV_HEADER.as_bytes())?;
    for row in rows {
        writeln!(file, "{run},{row}")?;
    }
    Ok(path)
}

fn append_result_row(row: &str) -> std::io::Result<std::path::PathBuf> {
    let path =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/engine_timing_results.csv");
    let is_new_file = !path.exists();
    let mut file = OpenOptions::new().create(true).append(true).open(&path)?;
    if is_new_file {
        file.write_all(RESULTS_CSV_HEADER.as_bytes())?;
    }
    file.write_all(row.as_bytes())?;
    Ok(path)
}

const ENGINE_ID: &str = "greedy-v1";
const ENGINE_TURN_TIMEOUT: Duration = Duration::from_secs(5);
// Defensive cap matching production's own MAX_ENGINE_TURNS_PER_TRIGGER, in
// case a future rules bug ever made a game fail to terminate.
const MAX_TURNS_PER_GAME: usize = 500;

fn engine_participant(seat_number: u8, display_name: &str) -> ParticipantState {
    ParticipantState {
        seat_number,
        kind: SeatKind::Engine,
        display_name: display_name.to_string(),
        player_id: None,
        engine_id: Some(ENGINE_ID.to_string()),
        score: 0,
        rack: Rack::default(),
        resigned: false,
        removed_by_player: false,
        invited_email: None,
        reminder_sent_turn: None,
    }
}

fn percentile(sorted_ms: &[f64], p: f64) -> f64 {
    if sorted_ms.is_empty() {
        return 0.0;
    }
    let idx = (p * (sorted_ms.len() as f64 - 1.0)).round() as usize;
    sorted_ms[idx.min(sorted_ms.len() - 1)]
}

#[tokio::main]
async fn main() {
    let num_games: usize = std::env::args()
        .nth(1)
        .and_then(|arg| arg.parse().ok())
        .unwrap_or(30);
    // Editions differ by dictionary size (german/spanish carry 2-4x the
    // words of official), so "how slow is a move" is not one number across
    // the registry — it has to be asked per edition.
    let edition = std::env::args().nth(2).unwrap_or_else(|| "official".into());
    let base_rules = VariantRules::by_name(&edition)
        .unwrap_or_else(|| panic!("unknown edition '{edition}' — see VariantRules::EDITION_NAMES"));

    let engines = EngineRegistry::default();
    let mut samples_ms: Vec<f64> = Vec::new();
    // The opening move of a game is a distinct population: an empty board
    // with no anchors, and the first turn to touch any lazily-built shared
    // state. Pooling it with the other 40-odd moves of a game averages away
    // the exact thing a player actually notices.
    let mut first_move_ms: Vec<f64> = Vec::new();
    // CPU time for the same calls, paired with samples_ms by index. Wall 60 ms
    // with CPU 0.6 ms is a move that waited; wall 60 ms with CPU 60 ms is a
    // position that was hard. Wall clock alone cannot tell them apart, which is
    // the whole reason production's 57 ms p99 has never been explained.
    let mut cpu_ms: Vec<f64> = Vec::new();
    // One row per move, written beside the summary. The summary answers "is it
    // getting slower"; this answers "which moves, and why", which no percentile
    // can. `game` and `turn` are the case marker: the games are seeded, so the
    // same pair is the same position on every machine and in every run, and two
    // runs can be compared move for move rather than distribution to
    // distribution. That is what showed the VM's tail to be the hypervisor.
    let mut detail: Vec<String> = Vec::new();
    let mut games_completed = 0usize;

    let steal_before = steal_ms_since_boot();
    let run_started = Instant::now();

    for game_index in 0..num_games {
        let rules = base_rules.clone();
        let participants = vec![
            engine_participant(0, "Greedy A"),
            engine_participant(1, "Greedy B"),
        ];
        let mut game = GameSession::new(
            format!("bench-{game_index}"),
            participants,
            None,
            game_index as u64,
            rules,
            72 * 60 * 60,
        );
        game.start();

        for turn in 0..MAX_TURNS_PER_GAME {
            let seat = game.current_seat as usize;
            let (blanks, rack_tiles) = game
                .participants
                .get(seat)
                .map(|p| (p.rack.blanks, p.rack.count()))
                .unwrap_or((0, 0));
            // N, the number of candidates the engine will iterate: the variable
            // that explains what a move costs. Counted outside the timed region
            // with the same `enumerate_legal_moves` the engine uses, so it is
            // exactly what the search will walk, at the price of doing the
            // enumeration twice — the run takes about twice as long and none of
            // that lands in a timing.
            //
            // Worth it because it separates the two ways an engine change can
            // help: generating fewer candidates, or costing less per candidate.
            // Measured 2026-09-04, cost is fixed + linear in N and nothing more
            // — laptop 0.179 ms + 3.35 us each, rehearsal 0.286 ms + 6.97 us.
            let n_moves = {
                let re = rules_shared::RulesEngine {
                    rules: &game.rules,
                    dictionary: rules_shared::dictionary_by_name(&game.rules.language)
                        .expect("known dictionary"),
                };
                let r = game.participants[seat].rack;
                re.enumerate_legal_moves(&game.state, &r).count()
            };
            let cpu_before = process_cpu_ms();
            let before = Instant::now();
            let advanced = game
                .maybe_run_engine_turn(&engines, ENGINE_TURN_TIMEOUT)
                .await
                .expect("engine turn should not error in a clean engine-vs-engine game");
            let elapsed_ms = before.elapsed().as_secs_f64() * 1000.0;
            let cpu_elapsed_ms = process_cpu_ms() - cpu_before;
            if turn == 0 {
                first_move_ms.push(elapsed_ms);
            }
            samples_ms.push(elapsed_ms);
            cpu_ms.push(cpu_elapsed_ms);
            detail.push(format!(
                "{game_index},{turn},{seat},{blanks},{rack_tiles},{n_moves},{elapsed_ms:.4},{cpu_elapsed_ms:.4}"
            ));
            if !advanced || game.status != GameStatus::Active {
                break;
            }
        }
        if game.status == GameStatus::Finished {
            games_completed += 1;
        }
    }

    let samples_ms_unsorted = samples_ms.clone();
    let run_wall_s = run_started.elapsed().as_secs_f64();
    // Steal is a counter since boot, so only the difference across the run
    // means anything, and only if both reads succeeded.
    let steal_ms = match (steal_before, steal_ms_since_boot()) {
        (Some(before), Some(after)) => Some(after - before),
        _ => None,
    };

    // Sorted independently of samples_ms: this is the distribution of CPU cost,
    // not the CPU cost of the slowest wall-clock moves.
    let mut cpu_sorted = cpu_ms.clone();
    cpu_sorted.sort_by(|a, b| a.partial_cmp(b).expect("no NaNs in CPU timing data"));
    let cpu_median = percentile(&cpu_sorted, 0.50);
    let cpu_p99 = percentile(&cpu_sorted, 0.99);
    let cpu_mean = cpu_sorted.iter().sum::<f64>() / cpu_sorted.len().max(1) as f64;

    samples_ms.sort_by(|a, b| a.partial_cmp(b).expect("no NaNs in timing data"));
    let n = samples_ms.len();
    let mean = samples_ms.iter().sum::<f64>() / n as f64;

    println!("host: {}  edition: {edition}", host_label());
    println!("cpu:  {} x{}", cpu_model(), num_cores());
    println!("games played: {num_games} ({games_completed} reached Finished)");
    println!("move-timing samples: {n}");
    println!();
    let min = samples_ms[0];
    let q1 = percentile(&samples_ms, 0.25);
    let median = percentile(&samples_ms, 0.50);
    let q3 = percentile(&samples_ms, 0.75);
    let p95 = percentile(&samples_ms, 0.95);
    let p99 = percentile(&samples_ms, 0.99);
    let max = samples_ms[n - 1];

    println!("min:          {min:>8.2} ms");
    println!("Q1 (25th):    {q1:>8.2} ms");
    println!("median (50th):{median:>8.2} ms");
    println!("mean:         {mean:>8.2} ms");
    println!("Q3 (75th):    {q3:>8.2} ms");
    println!("p95:          {p95:>8.2} ms");
    println!("p99:          {p99:>8.2} ms");
    println!("max:          {max:>8.2} ms");

    let mut first_sorted = first_move_ms.clone();
    first_sorted.sort_by(|a, b| a.partial_cmp(b).expect("no NaNs in timing data"));
    let first_median = percentile(&first_sorted, 0.50);
    let first_mean = first_sorted.iter().sum::<f64>() / first_sorted.len().max(1) as f64;
    let first_max = first_sorted.last().copied().unwrap_or(0.0);

    println!();
    println!("opening move only ({} games):", first_sorted.len());
    println!("  median:     {first_median:>8.2} ms");
    println!("  mean:       {first_mean:>8.2} ms");
    println!("  max:        {first_max:>8.2} ms");
    println!(
        "  vs all-move median: {:.1}x",
        first_median / median.max(f64::EPSILON)
    );

    print_histogram(&samples_ms);

    println!();
    println!("CPU time per move (work, as opposed to elapsed):");
    println!(
        "  median:     {cpu_median:>8.2} ms   ({:.0}% of wall)",
        100.0 * cpu_median / median.max(f64::EPSILON)
    );
    println!("  mean:       {cpu_mean:>8.2} ms");
    println!(
        "  p99:        {cpu_p99:>8.2} ms   ({:.0}% of wall)",
        100.0 * cpu_p99 / p99.max(f64::EPSILON)
    );
    // Denominator is wall x cores, not wall: steal accrues on every core at
    // once, so dividing by wall alone can exceed 100% and reads as "half the
    // run was stolen" when it means half the *machine* was. This is the share
    // of the machine's CPU capacity the hypervisor took during the run.
    let capacity_ms = run_wall_s * 1000.0 * num_cores().max(1) as f64;
    // Moves over 20 ms, and how many of those consumed almost no CPU while they
    // waited. The threshold is not tuned: on a machine nobody else is sharing no
    // move reaches it — the slowest laptop move in 1229 was 16 ms — while a
    // hypervisor descheduling a vCPU produces gaps that cluster at 50-60 ms. So
    // a non-zero count here is the tenancy, not the search.
    //
    // `slow_cpu_starved` is the subset that is *provable*: cpu under a fifth of
    // wall. The rest cannot be told apart from work by this process alone,
    // because a guest kernel credits a process with time the hypervisor took.
    // Both numbers are recorded rather than one, because the gap between them
    // is the part that looks like work and is not.
    let slow_moves = samples_ms.iter().filter(|ms| **ms > 20.0).count();
    let slow_cpu_starved = cpu_ms
        .iter()
        .zip(samples_ms_unsorted.iter())
        .filter(|(cpu, wall)| **wall > 20.0 && **cpu < 0.2 * **wall)
        .count();

    if slow_moves > 0 {
        println!();
        println!(
            "{slow_moves} moves took over 20 ms; {slow_cpu_starved} of them used almost no CPU while they waited."
        );
        println!("On a shared VM these are the hypervisor, not the search — so compare");
        println!("median and p95 between runs. The p99 is inside them and is not");
        println!("evidence about this code. The algorithmic tail is only readable on a");
        println!("machine nobody else is sharing, where this count is zero.");
    }

    match steal_ms {
        Some(steal) => println!(
            "\nsteal during the run: {steal:.0} ms of {capacity_ms:.0} ms of CPU capacity ({:.1}% of the machine)",
            100.0 * steal / capacity_ms.max(f64::EPSILON)
        ),
        None => println!("\nsteal: unavailable (/proc/stat not readable)"),
    }

    let timestamp_unix_seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system time before epoch")
        .as_secs();
    let steal_field = steal_ms.map(|s| format!("{s:.0}")).unwrap_or_default();
    let steal_pct_field = steal_ms
        .map(|s| format!("{:.2}", 100.0 * s / capacity_ms.max(f64::EPSILON)))
        .unwrap_or_default();
    let row = format!(
        "{timestamp_unix_seconds},{},{},{edition},{num_games},{games_completed},{n},{min:.2},{q1:.2},{median:.2},{mean:.2},{q3:.2},{p95:.2},{p99:.2},{max:.2},{first_median:.2},{first_mean:.2},{first_max:.2},{cpu_median:.2},{cpu_mean:.2},{cpu_p99:.2},{run_wall_s:.1},{steal_field},{steal_pct_field},{},{},{slow_moves},{slow_cpu_starved}\n",
        git_commit_label(),
        host_label(),
        cpu_model(),
        num_cores(),
    );
    match write_moves_file(timestamp_unix_seconds, &host_label(), &detail) {
        Ok(path) => println!("per-move detail: {}", path.display()),
        Err(error) => {
            // No manifest directory here, which is the deployment VM. Emit the
            // rows so whatever ran this can save them on a machine that has one.
            eprintln!("per-move detail not written here ({error}) — emitting instead");
            println!("MOVES {MOVES_CSV_HEADER}");
            for r in &detail {
                println!("MOVES {timestamp_unix_seconds},{r}");
            }
        }
    }

    // Printed as well as appended. A run on the deployment VM executes a binary
    // built here and copied there, where CARGO_MANIFEST_DIR does not exist and
    // `git` cannot say what was built — so the row is captured from stdout and
    // appended on the machine that does know both.
    print!("\nrow: {row}");
    match append_result_row(&row) {
        Ok(path) => println!("recorded to {}", path.display()),
        Err(error) => eprintln!("not recorded to a CSV here ({error}) — use the row above"),
    }
}
