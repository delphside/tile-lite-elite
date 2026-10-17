workspace "Tile Lite Elite" "The design map: the application as it is on main." {
    !identifiers hierarchical

    model {
        player = person "Player" "Plays games in a browser or the desktop client."
        admin = person "System administrator" "Runs the admin CLI on the production host."

        resend = softwareSystem "Resend" "Sends the service's emails." {
            tags "External"
        }

        tle = softwareSystem "Tile Lite Elite" "A word game played online." {
            web = container "Web client" "The game in a browser." "Rust, Dioxus, WebAssembly" {
                properties {
                    "artefact" "crates/ui"
                }
            }
            desktop = container "Desktop client" "The same client, built native." "Rust, Dioxus" {
                properties {
                    "artefact" "crates/ui"
                }
            }
            caddy = container "Web server" "Serves the web client and proxies the API." "Caddy" {
                properties {
                    "artefact" "Caddyfile"
                }
            }
            cli = container "Admin CLI" "Lists and deletes users and games." "Rust" {
                properties {
                    "artefact" "crates/admin-cli"
                }
            }
            server = container "Game server" "Decides every game: rules, turns, accounts." "Rust, Axum" {
                properties {
                    "artefact" "crates/server-game"
                }

                api = component "Transport API" "The routes, and the extractors that say who is calling." "Axum" {
                    properties {
                        "artefact" "crates/server-game/src/app.rs"
                    }
                }
                throttle = component "Rate limiting" "How often a caller may ask." "tower" {
                    properties {
                        "artefact" "crates/server-game/src/app/throttle.rs"
                    }
                }
                auth = component "Accounts" "Registration, sign-in, sessions and email changes." {
                    properties {
                        "artefact" "crates/server-game/src/app/auth.rs"
                    }
                }
                games = component "Game service" "Creates games and applies every move." {
                    properties {
                        "artefact" "crates/server-game/src/app/games.rs"
                    }
                }
                roster = component "Roster" "Seats before the start: swap, fill, remove." {
                    properties {
                        "artefact" "crates/server-game/src/app/roster.rs"
                    }
                }
                invitations = component "Invitations" "Open and emailed invitations to a seat." {
                    properties {
                        "artefact" "crates/server-game/src/app/invitations.rs"
                    }
                }
                events = component "Event stream" "Pushes each game's state to its players." "WebSocket" {
                    properties {
                        "artefact" "crates/server-game/src/app/events.rs"
                    }
                }
                catalog = component "Catalogue" "Health, editions and engine profiles." {
                    properties {
                        "artefact" "crates/server-game/src/app/catalog.rs"
                    }
                }
                ratings = component "Ratings" "Ratings and per-player statistics." {
                    properties {
                        "artefact" "crates/server-game/src/stats.rs"
                    }
                }
                adminApi = component "Admin endpoints" "The loopback-only /admin routes." {
                    properties {
                        "artefact" "crates/server-game/src/app/admin.rs"
                    }
                }
                scheduler = component "Scheduler" "Periodic scans: deadlines, sweeps, capacity." {
                    properties {
                        "artefact" "crates/server-game/src/app/scheduler.rs"
                    }
                }
                session = component "Game model" "GameSession: one game's authoritative state." {
                    properties {
                        "artefact" "crates/server-game/src/game_state.rs"
                    }
                }
                proxy = component "Engine proxy" "Takes an engine's turn through the same validation as a player's." {
                    properties {
                        "artefact" "crates/server-game/src/game_state.rs"
                    }
                }
                engines = component "Engines" "The engine trait and the Greedy engine." "Rust crate" {
                    properties {
                        "artefact" "crates/engine-core"
                    }
                }
                rules = component "Rules" "Board, validation, scoring and the word lists." "Rust crate" {
                    properties {
                        "artefact" "crates/rules-shared"
                    }
                }
                store = component "Persistence" "Reads and writes games and accounts." "sqlx" {
                    properties {
                        "artefact" "crates/server-game/src/persistence.rs"
                    }
                }
                email = component "Email" "Builds and sends each account email." {
                    properties {
                        "artefact" "crates/server-game/src/email.rs"
                    }
                }
            }
            db = container "Database" "Games, accounts and history." "SQLite" {
                tags "Database"
                properties {
                    "artefact" "crates/server-game/migrations"
                }
            }
        }

        player -> tle.web "plays in"
        player -> tle.desktop "plays in"
        admin -> tle.cli "runs"
        tle.caddy -> tle.web "serves"

        tle.web -> tle.caddy "calls the API and opens the event stream" "HTTPS, WebSocket"
        tle.desktop -> tle.caddy "calls the API and opens the event stream" "HTTPS, WebSocket"
        tle.caddy -> tle.server.throttle "proxies /api" "HTTP"
        tle.cli -> tle.server.adminApi "calls" "HTTP, loopback"

        tle.server.throttle -> tle.server.api "passes what is within its limits"
        tle.server.api -> tle.server.auth "passes account requests to"
        tle.server.api -> tle.server.games "passes game commands to"
        tle.server.api -> tle.server.roster "passes seat changes to"
        tle.server.api -> tle.server.invitations "passes invitation requests to"
        tle.server.api -> tle.server.events "upgrades to a WebSocket"
        tle.server.api -> tle.server.catalog "passes catalogue reads to"
        tle.server.api -> tle.server.ratings "passes statistics reads to"
        tle.server.api -> tle.server.adminApi "passes admin requests to"

        tle.server.games -> tle.server.session "applies the move to"
        tle.server.roster -> tle.server.session "changes the seats of"
        tle.server.invitations -> tle.server.session "fills a seat of"
        tle.server.scheduler -> tle.server.session "times out and sweeps"
        tle.server.session -> tle.server.rules "validates and scores with"
        tle.server.session -> tle.server.proxy "asks for an engine turn"
        tle.server.proxy -> tle.server.engines "requests a move from"
        tle.server.proxy -> tle.server.rules "previews the candidate move with"
        tle.server.games -> tle.server.events "publishes the new state to"
        tle.server.roster -> tle.server.events "publishes the new state to"
        tle.server.invitations -> tle.server.events "publishes the new state to"
        tle.server.scheduler -> tle.server.events "publishes the new state to"
        tle.server.games -> tle.server.store "saves the game"
        tle.server.roster -> tle.server.store "saves the game"
        tle.server.invitations -> tle.server.store "saves the game and the invitation"
        tle.server.scheduler -> tle.server.store "saves the game, deletes old ones"
        tle.server.store -> tle.server.ratings "records the result of a finished game"
        tle.server.auth -> tle.server.store "reads and writes accounts and sessions with"
        tle.server.auth -> tle.server.email "sends welcome and password-reset emails with"
        tle.server.games -> tle.server.email "sends invitation emails with"
        tle.server.invitations -> tle.server.email "sends invitation emails with"
        tle.server.scheduler -> tle.server.email "sends move-time reminders with"
        tle.server.adminApi -> tle.server.store "lists and deletes"
        tle.server.store -> tle.db "reads and writes" "SQL"
        tle.server.ratings -> tle.db "reads and writes" "SQL"
        tle.server.email -> resend "sends" "HTTPS"
    }
}
