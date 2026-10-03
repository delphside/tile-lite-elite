pub mod app;
pub mod email;
pub mod game_state;
pub mod persistence;
pub mod stats;

#[cfg(test)]
mod tests_display_name;

pub use app::{AppState, app_version, build_router, spawn_scheduler};
