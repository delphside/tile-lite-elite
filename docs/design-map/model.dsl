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
            caddy = container "Web server" "Serves version.txt and the web client files. Reverse-proxies the API paths its Caddyfile lists." "Caddy" {
                properties {
                    "artefact" "Caddyfile"
                }
            }
            cli = container "Admin CLI" "Administers accounts and games, and reads the database size and scheduler health." "Rust" {
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
                        "artefact" "crates/server-game/src/app.rs, crates/server-game/src/app/common.rs, crates/server-game/src/app/error.rs"
                    }
                }
                throttle = component "Rate limiting" "How often a caller may ask, on every public route but /health." "tower_governor" {
                    properties {
                        "artefact" "crates/server-game/src/app/throttle.rs"
                    }
                }
                auth = component "Accounts" "Registration, sign-in, sessions, passwords, player details and player search." {
                    properties {
                        "artefact" "crates/server-game/src/app/auth.rs"
                    }
                }
                games = component "Game service" "Creates and lists games, and applies every move." {
                    properties {
                        "artefact" "crates/server-game/src/app/games.rs, crates/server-game/src/app/sweeps_capacity.rs"
                    }
                }
                roster = component "Roster" "Seats before the start, force-resigning a seat, and aborting a game." {
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
                catalog = component "Catalogue" "Health, engine profiles and the word lists." {
                    properties {
                        "artefact" "crates/server-game/src/app/catalog.rs"
                    }
                }
                ratings = component "Ratings" "Ratings, statistics and rating history, for players and engines." {
                    properties {
                        "artefact" "crates/server-game/src/stats.rs, crates/server-game/src/app/ratings.rs"
                    }
                }
                adminApi = component "Admin endpoints" "The loopback-only /admin routes." {
                    properties {
                        "artefact" "crates/server-game/src/app/admin.rs"
                    }
                }
                scheduler = component "Scheduler" "Periodic jobs: overdue turns, move-time reminders and stalled-job checks." {
                    properties {
                        "artefact" "crates/server-game/src/app/scheduler.rs, crates/server-game/src/app/scheduler_jobs.rs, crates/server-game/src/app/sweeps_game.rs"
                    }
                }
                session = component "Game model" "GameSession: one game's authoritative state." {
                    properties {
                        "artefact" "crates/server-game/src/game_state.rs"
                    }
                }
                proxy = component "Engine proxy" "Runs engine turns and applies each move through the same validation as a player's." {
                    properties {
                        "artefact" "crates/server-game/src/game_state.rs, crates/server-game/src/app/games.rs"
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
                email = component "Email" "Builds each email from its template and sends it." {
                    properties {
                        "artefact" "crates/server-game/src/email.rs, crates/server-game/emails"
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
        tle.caddy -> tle.web "serves the wasm bundle"

        tle.web -> tle.caddy "sends requests, receives GameEventDto, polls version.txt for a new bundle" "HTTPS, WebSocket"
        tle.desktop -> tle.caddy "sends requests, receives GameEventDto" "HTTPS, WebSocket"
        tle.caddy -> tle.server.throttle "reverse-proxies the API paths its Caddyfile lists" "HTTP"
        tle.caddy -> tle.server.catalog "reverse-proxies /health" "HTTP"
        tle.cli -> tle.server.adminApi "sends admin requests" "HTTP, loopback"

        tle.server.throttle -> tle.server.api "passes requests within their limits"
        tle.server.api -> tle.server.auth "routes account requests"
        tle.server.api -> tle.server.games "routes GameActionRequest and game requests"
        tle.server.api -> tle.server.roster "routes seat requests"
        tle.server.api -> tle.server.invitations "routes invitation requests"
        tle.server.api -> tle.server.events "upgrades to a WebSocket"
        tle.server.api -> tle.server.catalog "routes catalogue reads"
        tle.server.api -> tle.server.ratings "routes statistics reads"

        tle.server.games -> tle.server.session "applies the move to the GameSession"
        tle.server.games -> tle.server.rules "previews and suggests MoveCandidate with"
        tle.server.games -> tle.server.proxy "runs engine turns with"
        tle.server.roster -> tle.server.session "changes the seats of the GameSession"
        tle.server.invitations -> tle.server.session "fills a seat of the GameSession"
        tle.server.scheduler -> tle.server.session "times out overdue turns of the GameSession"
        tle.server.adminApi -> tle.server.session "force-ends the GameSession, releases a deleted player's seats"
        tle.server.session -> tle.server.rules "validates and scores MoveCandidate with"
        tle.server.proxy -> tle.server.engines "requests an EngineAction from"
        tle.server.proxy -> tle.server.session "applies the EngineAction to the GameSession"
        tle.server.engines -> tle.server.rules "searches the GameState with"

        tle.server.games -> tle.server.events "publishes GameEventDto to"
        tle.server.roster -> tle.server.events "publishes GameEventDto to"
        tle.server.invitations -> tle.server.events "publishes GameEventDto to"
        tle.server.scheduler -> tle.server.events "publishes GameEventDto to"
        tle.server.adminApi -> tle.server.events "publishes GameEventDto to"

        tle.server.games -> tle.server.store "saves the GameSession, deletes old games and expired sessions, records the database size"
        tle.server.roster -> tle.server.store "saves the GameSession, updates invitation rows"
        tle.server.invitations -> tle.server.store "saves the GameSession and invitation rows"
        tle.server.scheduler -> tle.server.store "saves the GameSession, reads player rows"
        tle.server.auth -> tle.server.store "reads and writes player, session and password-reset rows"
        tle.server.adminApi -> tle.server.store "reads and writes player, session and game rows, reads the database-size history"
        tle.server.adminApi -> tle.server.scheduler "reads the scheduler's health"
        tle.server.store -> tle.server.ratings "settles the ratings of a finished game"
        tle.server.games -> tle.server.ratings "attaches ratings to the GameStateDto"
        tle.server.roster -> tle.server.ratings "attaches ratings to the GameStateDto"
        tle.server.adminApi -> tle.server.ratings "attaches ratings to the GameStateDto"
        tle.server.invitations -> tle.server.ratings "attaches ratings to the GameStateDto"
        tle.server.scheduler -> tle.server.ratings "attaches ratings to the GameStateDto"
        tle.server.api -> tle.server.store "reads the session row, updates last-seen"
        tle.server.api -> tle.server.throttle "marks the session verified"
        tle.server.catalog -> tle.server.engines "reads EngineMetadata from"
        tle.server.catalog -> tle.server.rules "reads the word lists from"
        tle.server.games -> tle.server.scheduler "expires an overdue turn with"
        tle.server.store -> tle.db "reads and writes rows" "SQL"
        tle.server.ratings -> tle.db "reads and writes rating rows" "SQL"

        tle.server.auth -> tle.server.email "sends welcome and password-reset emails with"
        tle.server.games -> tle.server.email "sends invitation emails with"
        tle.server.invitations -> tle.server.email "sends invitation emails with"
        tle.server.scheduler -> tle.server.email "sends move-time reminders with"
        tle.server.email -> resend "sends each email as JSON to" "HTTPS"
    }
}
