//! Desktop server configuration.
//!
//! The web build derives its API origin from the browser (see `app.rs`'s
//! `server_url`), but a native window has no "origin" to derive from, so it
//! picks from a small set of named environments compiled in below. Which
//! server a given run talks to is always overridable at runtime:
//!   --server-url <url>   use this exact URL
//!   --env <name>          use one of the named environments below
//!
//! With neither flag, the default follows `-r`/`--release` (via
//! `cfg!(debug_assertions)`) — debug and `cargo test` builds default to
//! "local", release builds default to "prod". That's the only build-time
//! distinction; testing a release build against "local" (or a debug build
//! against "prod") is a `--env` flag, not a different build.

use std::sync::OnceLock;

pub struct Environment {
    pub name: &'static str,
    pub server_url: &'static str,
}

/// The four environments of docs/3.3, in the order a change moves through
/// them. A desktop client can be pointed at any of them with `--env`, which
/// resolves at runtime — so exercising a release build against rehearsal
/// before anyone downloads it needs no separate build.
pub const ENVIRONMENTS: &[Environment] = &[
    Environment {
        name: "local",
        server_url: "http://127.0.0.1:3000",
    },
    Environment {
        name: "preview",
        server_url: "http://localhost:8081",
    },
    Environment {
        // No domain of its own, so this hard-codes the rehearsal host's IP
        // and breaks if that VM is ever rebuilt. Unavoidable — sslip.io is
        // what gives it a certificate without a DNS record (docs/3.1) — but
        // worth knowing rather than discovering.
        name: "rehearsal",
        server_url: "https://129.151.84.183.sslip.io",
    },
    Environment {
        // The domain, not the sslip.io fallback. Caddy serves both, but the
        // fallback hard-codes production's IP, so `--env prod` would break if
        // the VM's address ever changed; the A record would not.
        name: "prod",
        server_url: "https://tileliteelite.com",
    },
];

const DEFAULT_ENV_NAME: &str = if cfg!(debug_assertions) {
    "local"
} else {
    "prod"
};

fn environment_by_name(name: &str) -> Option<&'static Environment> {
    ENVIRONMENTS.iter().find(|e| e.name == name)
}

fn default_server_url() -> String {
    environment_by_name(DEFAULT_ENV_NAME)
        .unwrap_or(&ENVIRONMENTS[0])
        .server_url
        .to_string()
}

// Used via `init_from_args` under the `desktop` feature; unused on a plain
// host build (e.g. `cargo test`/CI), same feature-conditional deadness as
// `main.rs`'s `app_version`.
#[allow(dead_code)]
fn resolve_from_args(args: &[String]) -> String {
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--server-url" => {
                if let Some(url) = iter.next() {
                    return url.clone();
                }
            }
            "--env" => {
                if let Some(name) = iter.next() {
                    match environment_by_name(name) {
                        Some(env) => return env.server_url.to_string(),
                        None => eprintln!(
                            "Unknown --env '{name}'; known environments: {}",
                            ENVIRONMENTS
                                .iter()
                                .map(|e| e.name)
                                .collect::<Vec<_>>()
                                .join(", ")
                        ),
                    }
                }
            }
            _ => {}
        }
    }
    default_server_url()
}

static SERVER_URL: OnceLock<String> = OnceLock::new();

/// Call once from `main()`, before launching the app, with the process's
/// CLI args (excluding argv[0]). Only wired up under the `desktop` feature
/// (see `main.rs`), hence `allow(dead_code)` for plain host builds.
#[allow(dead_code)]
pub fn init_from_args(args: &[String]) {
    let _ = SERVER_URL.set(resolve_from_args(args));
}

/// The resolved server URL for this run. Falls back to the compiled-in
/// default environment if `init_from_args` was never called.
pub fn server_url() -> String {
    SERVER_URL.get_or_init(default_server_url).clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn no_args_falls_back_to_default_env() {
        assert_eq!(resolve_from_args(&args(&[])), default_server_url());
    }

    // Pins the actual debug-vs-release default (rather than just comparing
    // against the function under test) so a change to the `cfg!` branch in
    // `DEFAULT_ENV_NAME` shows up as a real failure, not a tautology.
    #[test]
    #[cfg(debug_assertions)]
    fn debug_build_defaults_to_local() {
        assert_eq!(default_server_url(), "http://127.0.0.1:3000");
    }

    #[test]
    #[cfg(not(debug_assertions))]
    fn release_build_defaults_to_prod() {
        assert_eq!(default_server_url(), "https://tileliteelite.com");
    }

    /// Every environment docs/3.3 names is selectable. A desktop client that
    /// cannot reach preview or rehearsal cannot be tested anywhere except
    /// local and production, which is the gap this closes.
    #[test]
    fn every_documented_environment_is_selectable() {
        for name in ["local", "preview", "rehearsal", "prod"] {
            assert!(
                environment_by_name(name).is_some(),
                "--env {name} should resolve"
            );
        }
    }

    /// `prod` uses the domain, not the sslip.io fallback. Both are served by
    /// Caddy, but the fallback hard-codes production's IP — this would break
    /// silently if the VM were ever rebuilt, and nothing else would catch it.
    #[test]
    fn prod_uses_the_domain_not_the_ip_fallback() {
        let prod = environment_by_name("prod").expect("prod should exist");
        assert_eq!(prod.server_url, "https://tileliteelite.com");
    }

    #[test]
    fn server_url_flag_wins() {
        assert_eq!(
            resolve_from_args(&args(&["--server-url", "http://example:9999"])),
            "http://example:9999"
        );
    }

    #[test]
    fn env_flag_selects_named_environment() {
        assert_eq!(
            resolve_from_args(&args(&["--env", "prod"])),
            "https://tileliteelite.com"
        );
    }

    #[test]
    fn unknown_env_falls_back_to_default() {
        assert_eq!(
            resolve_from_args(&args(&["--env", "bogus"])),
            default_server_url()
        );
    }
}
