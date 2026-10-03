workspace "Tile Lite Elite" "As-is map (trial)" {
    !identifiers hierarchical
    model {
        player = person "Player"
        admin = person "System administrator"
        tle = softwareSystem "Tile Lite Elite" {
            web = container "Web client" "Dioxus, compiled to wasm" "Rust"
            caddy = container "Web server" "Serves the client, proxies the API" "Caddy"
            server = container "Game server" "Axum" "Rust" {
                api = component "Transport API" "routes, auth extractors"
                games = component "Game service" "app/games.rs"
                invitations = component "Invitations" "app/invitations.rs"
                store = component "Persistence" "persistence.rs"
                proxy = component "Engine proxy"
            }
            db = container "Database" "SQLite" "SQLite" "Database"
        }
        player -> tle.web "plays in a browser"
        tle.web -> tle.caddy "GameStateDto, over HTTPS and a WebSocket"
        tle.caddy -> tle.server "proxies /api"
        tle.server.api -> tle.server.games "commands"
        tle.server.api -> tle.server.invitations "commands"
        tle.server.games -> tle.server.proxy "engine turn"
        tle.server.games -> tle.server.store "GameSession"
        tle.server.store -> tle.db "rows"
        admin -> tle.server "admin CLI, over docker exec"
    }
}
