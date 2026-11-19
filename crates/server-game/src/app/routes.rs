//! Every route the server has: the one list `build_router` registers from.
//!
//! **A route is added here or not at all.** Each row says who may call it
//! (`Access`) and which rate-limit tier it sits in (`Limit`), and the level is
//! a required argument, so a route with none does not compile. The checks
//! themselves stay in the handlers; `tests_routes.rs` walks this list and
//! holds every handler to its level, and compares it with docs/4.4.3.

use super::*;
use axum::handler::Handler;
use axum::routing::MethodRouter;

/// Who may call a route, and what the server answers otherwise.
/// docs/4.4.3 (*Endpoints*) is the table the words come from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Access {
    /// Anyone. No session is required, so never answered 401.
    Public,
    /// Any signed-in player. 401 without a valid session.
    Session,
    /// The player `{player_id}` names. 401 without a session, 403 for another.
    Owner,
    /// A player seated in the game, or its creator; a handler may narrow it
    /// to the seat or the turn. 401 without a session, 403 for anyone else.
    Game,
    /// The game's creator only (`caller_may_manage_game`, which lets a game
    /// with no recorded creator be managed by any seated player). 401 without
    /// a session, 403 for anyone else, a seated player included.
    Creator,
    /// The operator, on the host. 403 from anywhere else.
    Loopback,
}

/// The rate-limit tier a route sits in; `throttle.rs` says what each is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Limit {
    Registration,
    HeavyAuth,
    Authenticated,
    /// `/health` and `/admin/*`: no limiter of any kind.
    Unlimited,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Verb {
    Get,
    Post,
    Delete,
}

pub(super) struct Route {
    /// Read by the tests, which compare it with docs/4.4.3.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(super) verb: Verb,
    pub(super) path: &'static str,
    pub(super) access: Access,
    pub(super) limit: Limit,
    handler: MethodRouter<AppState>,
}

/// One row. The verb picks the method the handler is mounted on, so the
/// listed method and the registered one cannot differ.
fn row<H, T>(verb: Verb, path: &'static str, access: Access, limit: Limit, handler: H) -> Route
where
    H: Handler<T, AppState>,
    T: 'static,
{
    let handler = match verb {
        Verb::Get => get(handler),
        Verb::Post => post(handler),
        Verb::Delete => delete(handler),
    };
    Route {
        verb,
        path,
        access,
        limit,
        handler,
    }
}

/// The routes for which `keep` holds, as a router.
pub(super) fn router(keep: impl Fn(&Route) -> bool) -> Router<AppState> {
    all()
        .into_iter()
        .filter(|route| keep(route))
        .fold(Router::new(), |router, route| {
            router.route(route.path, route.handler)
        })
}

#[rustfmt::skip]
pub(super) fn all() -> Vec<Route> {
    use Access::{Creator, Game, Loopback, Owner, Public, Session};
    use Limit::{Authenticated, HeavyAuth, Registration, Unlimited};
    use Verb::{Delete, Get, Post};

    vec![
        // No limit of any kind: monitoring and deploy.sh's smoke test call
        // this, and it has to answer while everything else is refusing.
        row(Get,  "/health",                   Public, Unlimited, health),
        // Creating an account is limited hardest, and on its own.
        row(Post, "/auth/register",            Public, Registration, register_player),
        // The rest of the unauthenticated auth surface; each spends Argon2 time.
        row(Post, "/auth/login",               Public, HeavyAuth, login_player),
        row(Post, "/auth/forgot-password",     Public, HeavyAuth, request_password_reset),
        row(Post, "/auth/reset-password",      Public, HeavyAuth, reset_password),
        // Everything below is keyed by session, then the global floor.
        row(Get,  "/engines",                  Public,  Authenticated, list_engines),
        row(Get,  "/dictionaries/{name}",      Session, Authenticated, get_dictionary),
        // Authentication
        row(Post, "/auth/validate",            Session, Authenticated, validate_session),
        row(Post, "/auth/logout",              Public,  Authenticated, logout),
        row(Post, "/auth/change-password",     Session, Authenticated, change_password),
        row(Post, "/auth/update-details",      Session, Authenticated, update_player_details),
        row(Get,  "/players/search",           Session, Authenticated, search_players),
        // Rating & Stats
        row(Get,  "/players/{player_id}/stats",          Session, Authenticated, get_player_stats),
        row(Get,  "/players/{player_id}/rating-history", Session, Authenticated, get_player_rating_history),
        row(Get,  "/engines/{engine_id}/stats",          Session, Authenticated, get_engine_stats),
        row(Get,  "/engines/{engine_id}/rating-history", Session, Authenticated, get_engine_rating_history),
        // Games
        row(Post, "/games",                    Session, Authenticated, create_game),
        row(Get,  "/games",                    Session, Authenticated, list_games),
        row(Get,  "/games/{game_id}",          Game, Authenticated, get_game),
        row(Post, "/games/{game_id}/start",    Creator, Authenticated, start_game),
        row(Post, "/games/{game_id}/reorder-seats", Creator, Authenticated, swap_seats),
        row(Post, "/games/{game_id}/seats",    Creator, Authenticated, add_seat_to_game),
        row(Post, "/games/{game_id}/seats/{seat_number}/remove",       Creator, Authenticated, remove_seat_from_game),
        row(Post, "/games/{game_id}/seats/{seat_number}/withdraw",     Game, Authenticated, withdraw_from_seat),
        row(Post, "/games/{game_id}/seats/{seat_number}/force-resign", Creator, Authenticated, force_resign_seat),
        row(Post, "/games/{game_id}/abort",    Creator, Authenticated, abort_game),
        row(Post, "/games/{game_id}/actions",  Game, Authenticated, submit_action),
        row(Post, "/games/{game_id}/chat",     Game, Authenticated, post_chat_message),
        row(Post, "/games/{game_id}/remove",   Game, Authenticated, remove_game_for_player),
        row(Post, "/games/{game_id}/preview",  Game, Authenticated, preview_move),
        row(Post, "/games/{game_id}/suggest",  Game, Authenticated, suggest_move),
        // The token comes from the query: a browser cannot set headers on a
        // WebSocket handshake.
        row(Get,  "/games/{game_id}/events",   Game, Authenticated, game_events),
        // Game Invitations
        row(Post, "/games/{game_id}/invite",   Creator, Authenticated, invite_player_to_game),
        row(Get,  "/players/{player_id}/invitations",       Owner,   Authenticated, list_player_invitations),
        row(Get,  "/invitations/{invitation_id}/preview",   Public,  Authenticated, preview_invitation),
        row(Post, "/invitations/{invitation_id}/accept",    Session, Authenticated, accept_invitation),
        row(Post, "/invitations/{invitation_id}/reject",    Session, Authenticated, reject_invitation),
        // Admin routes are for operating the server, not for players: no
        // token or account, just "you're on the same machine as the server".
        // `build_router` puts the loopback guard on every `Loopback` row,
        // whatever TILE_LITE_ELITE_BIND is set to.
        row(Get,    "/admin/users",                  Loopback, Unlimited, admin_list_users),
        row(Get,    "/admin/database-size",          Loopback, Unlimited, admin_list_database_size),
        row(Get,    "/admin/scheduler-health",       Loopback, Unlimited, admin_scheduler_health),
        row(Delete, "/admin/users/{player_id}",      Loopback, Unlimited, admin_delete_user),
        row(Post,   "/admin/users/{player_id}/sign-out",       Loopback, Unlimited, admin_sign_out_user),
        row(Post,   "/admin/users/{player_id}/reset-password", Loopback, Unlimited, admin_reset_password),
        row(Get,    "/admin/games",                  Loopback, Unlimited, admin_list_games),
        row(Delete, "/admin/games/{game_id}",        Loopback, Unlimited, admin_delete_game),
        row(Post,   "/admin/games/{game_id}/force-end",        Loopback, Unlimited, admin_force_end_game),
    ]
}
