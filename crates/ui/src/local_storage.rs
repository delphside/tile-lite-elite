//! Persists a small amount of state across app restarts:
//! - `StoredAuth`: `remembered_name` (pure convenience, just pre-fills the
//!   display-name field next time — no security weight) and `session_token`
//!   (the actual bearer token). Where the token goes depends on "Stay
//!   logged in": `localStorage` when checked, so it survives closing the
//!   browser; `sessionStorage` when not, so it survives a reload but not
//!   the tab closing. See `save_authenticated`.
//! - `StoredChatWatermarks`: per-game "last seen chat message" markers, so
//!   an unread-messages indicator survives a reload. There's no server-side
//!   read-receipt concept — this is purely local to the device/browser.
//!
//! Storage differs by platform since there's no browser localStorage on
//! desktop: web uses `localStorage`, native writes a small JSON file
//! under the OS config directory.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[cfg(target_arch = "wasm32")]
use gloo_storage::Storage;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct StoredAuth {
    pub remembered_name: Option<String>,
    pub session_token: Option<String>,
}

#[cfg(target_arch = "wasm32")]
const STORAGE_KEY: &str = "tile_lite_elite_auth";

/// `sessionStorage`, not `localStorage` — a separate key because the two
/// stores hold tokens with deliberately different lifetimes.
#[cfg(target_arch = "wasm32")]
const SESSION_TOKEN_KEY: &str = "tile_lite_elite_session_token";

pub fn load() -> StoredAuth {
    load_impl().unwrap_or_default()
}

pub fn save(auth: &StoredAuth) {
    let _ = save_impl(auth);
}

/// The token to authenticate with on startup, from either store.
///
/// Prefer this over `load().session_token`, which sees only the persistent
/// half. The two stores mean different things and the difference is the
/// whole point — see `save_authenticated`.
pub fn load_token() -> Option<String> {
    load()
        .session_token
        .or_else(load_transient_token)
        .filter(|token| !token.is_empty())
}

/// Records a freshly authenticated session, putting the token in whichever
/// store matches what "Stay logged in" was supposed to mean.
///
/// Unchecked used to mean *not stored at all*, so the token lived only in a
/// signal — and any reload dropped it, sending the player back to the login
/// screen. That was already wrong for an accidental F5, and it got worse
/// when the client started reloading itself on api skew: a deploy would log
/// out everyone who hadn't ticked the box, mid-game, with no warning. See
/// `watch_for_new_bundle`.
///
/// `sessionStorage` is the store that actually expresses the intent. It
/// survives a reload but is dropped when the tab closes, so "don't stay
/// logged in" keeps its meaning — close the browser and you are logged out
/// — while a refresh or a self-update no longer costs the session.
///
/// Writes both stores every time, so switching the box off on a later login
/// can't leave a persistent token behind from an earlier one.
pub fn save_authenticated(remembered_name: Option<String>, token: &str, stay_logged_in: bool) {
    save(&StoredAuth {
        remembered_name,
        session_token: if stay_logged_in {
            Some(token.to_string())
        } else {
            None
        },
    });
    save_transient_token(if stay_logged_in { None } else { Some(token) });
}

/// Drops the token from both stores, keeping any remembered display name.
/// For logging out, and for a token the server has stopped accepting.
pub fn clear_tokens() {
    let remembered_name = load().remembered_name;
    save(&StoredAuth {
        remembered_name,
        session_token: None,
    });
    save_transient_token(None);
}

#[cfg(target_arch = "wasm32")]
fn load_impl() -> Option<StoredAuth> {
    gloo_storage::LocalStorage::get(STORAGE_KEY).ok()
}

#[cfg(target_arch = "wasm32")]
fn save_impl(auth: &StoredAuth) -> Result<(), String> {
    gloo_storage::LocalStorage::set(STORAGE_KEY, auth).map_err(|error| error.to_string())
}

#[cfg(target_arch = "wasm32")]
fn load_transient_token() -> Option<String> {
    gloo_storage::SessionStorage::get(SESSION_TOKEN_KEY).ok()
}

#[cfg(target_arch = "wasm32")]
fn save_transient_token(token: Option<&str>) {
    match token {
        Some(token) => {
            let _ = gloo_storage::SessionStorage::set(SESSION_TOKEN_KEY, token);
        }
        None => gloo_storage::SessionStorage::delete(SESSION_TOKEN_KEY),
    }
}

// Desktop has no sessionStorage, and no reload for it to survive — the app
// restarting is a process restart, which is exactly the boundary
// `stay_logged_in` already draws. So a non-persistent token stays in memory
// only, as it always has here.
#[cfg(not(target_arch = "wasm32"))]
fn load_transient_token() -> Option<String> {
    None
}

#[cfg(not(target_arch = "wasm32"))]
fn save_transient_token(_token: Option<&str>) {}

#[cfg(not(target_arch = "wasm32"))]
fn config_file_path() -> Option<std::path::PathBuf> {
    let mut dir = dirs::config_dir()?;
    dir.push("tile-lite-elite");
    std::fs::create_dir_all(&dir).ok()?;
    dir.push("auth.json");
    Some(dir)
}

#[cfg(not(target_arch = "wasm32"))]
fn load_impl() -> Option<StoredAuth> {
    let path = config_file_path()?;
    let contents = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&contents).ok()
}

#[cfg(not(target_arch = "wasm32"))]
fn save_impl(auth: &StoredAuth) -> Result<(), String> {
    let path =
        config_file_path().ok_or_else(|| "Could not resolve config directory".to_string())?;
    let contents = serde_json::to_string(auth).map_err(|error| error.to_string())?;
    std::fs::write(path, contents).map_err(|error| error.to_string())
}

/// game_id -> the `created_at` of the last chat message this device has
/// seen for that game. A game with no entry (or an entry that doesn't
/// match the latest message) has unread chat.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct StoredChatWatermarks {
    pub last_seen: HashMap<String, i64>,
}

#[cfg(target_arch = "wasm32")]
const CHAT_STORAGE_KEY: &str = "tile_lite_elite_chat_seen";

pub fn load_chat_watermarks() -> StoredChatWatermarks {
    load_chat_watermarks_impl().unwrap_or_default()
}

pub fn save_chat_watermarks(watermarks: &StoredChatWatermarks) {
    let _ = save_chat_watermarks_impl(watermarks);
}

#[cfg(target_arch = "wasm32")]
fn load_chat_watermarks_impl() -> Option<StoredChatWatermarks> {
    gloo_storage::LocalStorage::get(CHAT_STORAGE_KEY).ok()
}

#[cfg(target_arch = "wasm32")]
fn save_chat_watermarks_impl(watermarks: &StoredChatWatermarks) -> Result<(), String> {
    gloo_storage::LocalStorage::set(CHAT_STORAGE_KEY, watermarks).map_err(|error| error.to_string())
}

#[cfg(not(target_arch = "wasm32"))]
fn chat_watermarks_file_path() -> Option<std::path::PathBuf> {
    let mut dir = dirs::config_dir()?;
    dir.push("tile-lite-elite");
    std::fs::create_dir_all(&dir).ok()?;
    dir.push("chat_watermarks.json");
    Some(dir)
}

#[cfg(not(target_arch = "wasm32"))]
fn load_chat_watermarks_impl() -> Option<StoredChatWatermarks> {
    let path = chat_watermarks_file_path()?;
    let contents = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&contents).ok()
}

#[cfg(not(target_arch = "wasm32"))]
fn save_chat_watermarks_impl(watermarks: &StoredChatWatermarks) -> Result<(), String> {
    let path = chat_watermarks_file_path()
        .ok_or_else(|| "Could not resolve config directory".to_string())?;
    let contents = serde_json::to_string(watermarks).map_err(|error| error.to_string())?;
    std::fs::write(path, contents).map_err(|error| error.to_string())
}
