//! **The server counts its own symptoms** (#402 R3), as numbers that grow from
//! the process's start, and `GET /admin/metrics` reads them.
//!
//! One middleware, `count_response`, sits where the response is final, outside
//! the panic layer and the rewrite of the framework's errors, so it sees what
//! the caller sees. It counts with atomics: no lock is taken and nothing is
//! allocated, so it cannot wait on another request or fail one. Two small
//! changes elsewhere tell it what it cannot see: `ApiProblem::render` puts the
//! `Reason` in the response's extensions, and `panic_response` puts a
//! `PanicCaught` marker there (`error.rs`).
//!
//! The state holds the counters, never a `static`, so the tests that share one
//! process each have their own.

use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::time::Instant;

use api::ErrorType;
use axum::extract::MatchedPath;

use super::*;

/// **The upper bounds of the latency histogram, in milliseconds**, inclusive
/// and ascending: nine buckets with the overflow one. A product setting held in
/// this one module (docs/1.10), listed in 4.4.1's *Server timings held in
/// code*, with where each number comes from. Moving one is a code change and a
/// release, and the body carries the bounds so a reader is never told wrong.
pub(crate) const LATENCY_BOUNDS_MS: [u64; 8] = [10, 50, 100, 250, 500, 1_000, 5_000, 60_000];

/// One bucket for each bound, and one for what took longer than every bound.
const BUCKETS: usize = LATENCY_BOUNDS_MS.len() + 1;

/// Put in the extensions of the 500 `panic_response` builds, so the layer
/// adds one to `panics_caught` where it finds it.
#[derive(Debug, Clone, Copy)]
pub(crate) struct PanicCaught;

/// The class of a status, named after RFC 9110's. Every status is in exactly
/// one: a code outside 100 to 599 is read as the nearer end.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Class {
    Informational,
    Success,
    Redirection,
    ClientError,
    ServerError,
}

impl Class {
    fn of(status: StatusCode) -> Self {
        match status.as_u16() {
            0..=199 => Self::Informational,
            200..=299 => Self::Success,
            300..=399 => Self::Redirection,
            400..=499 => Self::ClientError,
            _ => Self::ServerError,
        }
    }

    fn is_error(self) -> bool {
        matches!(self, Self::ClientError | Self::ServerError)
    }
}

/// What the layer saw of one request, as `Metrics::record` takes it.
pub(crate) struct Observed {
    pub(crate) status: StatusCode,
    /// The reason the response carried, if it passed through `render`.
    pub(crate) reason: Option<Reason>,
    /// The response was a caught panic's.
    pub(crate) panicked: bool,
    /// The request's matched path is the events route.
    pub(crate) events_route: bool,
    pub(crate) elapsed: Duration,
}

/// The counters: five classes, four types, two statuses, the panics, the
/// handshakes and nine buckets, 22 in all.
#[derive(Debug)]
pub(crate) struct Metrics {
    started_at: i64,
    informational: AtomicU64,
    success: AtomicU64,
    redirection: AtomicU64,
    client_error: AtomicU64,
    server_error: AtomicU64,
    business: AtomicU64,
    technical: AtomicU64,
    unexpected: AtomicU64,
    unclassified: AtomicU64,
    too_many_requests: AtomicU64,
    service_unavailable: AtomicU64,
    panics_caught: AtomicU64,
    websocket_handshake_failures: AtomicU64,
    latency: [AtomicU64; BUCKETS],
}

fn bump(counter: &AtomicU64) {
    counter.fetch_add(1, Relaxed);
}

/// **The index of the bucket a time falls in**: the first bound it does not
/// exceed, or the overflow bucket after the last.
pub(crate) fn bucket_for(elapsed: Duration) -> usize {
    LATENCY_BOUNDS_MS
        .iter()
        .position(|&bound| elapsed <= Duration::from_millis(bound))
        .unwrap_or(LATENCY_BOUNDS_MS.len())
}

impl Metrics {
    /// Every counter at zero, and the process's start time as now.
    pub(crate) fn new() -> Self {
        Self {
            started_at: now_unix_seconds(),
            informational: AtomicU64::new(0),
            success: AtomicU64::new(0),
            redirection: AtomicU64::new(0),
            client_error: AtomicU64::new(0),
            server_error: AtomicU64::new(0),
            business: AtomicU64::new(0),
            technical: AtomicU64::new(0),
            unexpected: AtomicU64::new(0),
            unclassified: AtomicU64::new(0),
            too_many_requests: AtomicU64::new(0),
            service_unavailable: AtomicU64::new(0),
            panics_caught: AtomicU64::new(0),
            websocket_handshake_failures: AtomicU64::new(0),
            latency: std::array::from_fn(|_| AtomicU64::new(0)),
        }
    }

    /// Adds one request to every counter it belongs in.
    pub(crate) fn record(&self, seen: Observed) {
        let class = Class::of(seen.status);
        bump(match class {
            Class::Informational => &self.informational,
            Class::Success => &self.success,
            Class::Redirection => &self.redirection,
            Class::ClientError => &self.client_error,
            Class::ServerError => &self.server_error,
        });
        if class.is_error() {
            bump(match seen.reason.map(Reason::error_type) {
                Some(ErrorType::Business) => &self.business,
                Some(ErrorType::Technical) => &self.technical,
                // `Unknown` is read as a defect, as everywhere.
                Some(_) => &self.unexpected,
                None => &self.unclassified,
            });
            if seen.events_route {
                bump(&self.websocket_handshake_failures);
            }
        }
        match seen.status.as_u16() {
            429 => bump(&self.too_many_requests),
            503 => bump(&self.service_unavailable),
            _ => {}
        }
        if seen.panicked {
            bump(&self.panics_caught);
        }
        bump(&self.latency[bucket_for(seen.elapsed)]);
    }

    /// Each atomic read once. A response in flight can be in one field and not
    /// yet in another; the next read has it.
    pub(crate) fn snapshot(&self) -> api::AdminMetricsDto {
        let read = |counter: &AtomicU64| counter.load(Relaxed);
        api::AdminMetricsDto {
            started_at: self.started_at,
            responses: api::AdminResponseCountsDto {
                informational: read(&self.informational),
                success: read(&self.success),
                redirection: read(&self.redirection),
                client_error: read(&self.client_error),
                server_error: read(&self.server_error),
            },
            errors: api::AdminErrorTypeCountsDto {
                business: read(&self.business),
                technical: read(&self.technical),
                unexpected: read(&self.unexpected),
                unclassified: read(&self.unclassified),
            },
            too_many_requests: read(&self.too_many_requests),
            service_unavailable: read(&self.service_unavailable),
            panics_caught: read(&self.panics_caught),
            websocket_handshake_failures: read(&self.websocket_handshake_failures),
            latency: api::AdminLatencyDto {
                bounds_ms: LATENCY_BOUNDS_MS.to_vec(),
                counts: self.latency.iter().map(read).collect(),
            },
        }
    }
}

/// **The middleware that counts**: it takes an `Instant`, runs the request and
/// counts the response the caller will see. It awaits only `next` and does
/// nothing that can fail.
pub(crate) async fn count_response(
    State(metrics): State<Arc<Metrics>>,
    request: Request,
    next: Next,
) -> Response {
    let started = Instant::now();
    let events_route = request
        .extensions()
        .get::<MatchedPath>()
        .is_some_and(|path| path.as_str() == routes::EVENTS_PATH);
    let response = next.run(request).await;
    metrics.record(Observed {
        status: response.status(),
        reason: response.extensions().get::<Reason>().copied(),
        panicked: response.extensions().get::<PanicCaught>().is_some(),
        events_route,
        elapsed: started.elapsed(),
    });
    response
}
