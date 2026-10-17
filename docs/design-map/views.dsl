        container tle "containers" "the deployable parts and how they talk" {
            include *
        }
        component tle.server "server-requests" "the game server, taking a request" {
            include tle.caddy tle.cli tle.server.throttle tle.server.api
            include tle.server.auth tle.server.games tle.server.roster tle.server.invitations
            include tle.server.scheduler tle.server.events tle.server.catalog tle.server.ratings
            include tle.server.adminApi
        }
        component tle.server "server-games" "the game server, changing a game" {
            include tle.server.games tle.server.roster tle.server.invitations tle.server.scheduler
            include tle.server.adminApi tle.server.session tle.server.proxy tle.server.engines
            include tle.server.rules
        }
        component tle.server "server-storage" "the game server, storing games and ratings" {
            include tle.server.games tle.server.roster tle.server.invitations tle.server.scheduler
            include tle.server.adminApi tle.server.store tle.server.ratings tle.db
        }
        component tle.server "server-accounts" "the game server, accounts and email" {
            include tle.server.auth tle.server.games tle.server.invitations tle.server.scheduler
            include tle.server.adminApi tle.server.store tle.server.email tle.db resend
        }
        styles {
            element "Element" {
                background #f6f8fa
                stroke #8c959f
                color #1f2328
            }
            element "new" {
                background #dafbe1
                stroke #1a7f37
                color #0a3622
            }
            element "changed" {
                background #fff8c5
                stroke #9a6700
                color #4d2d00
            }
            element "removed" {
                background #ffebe9
                stroke #cf222e
                color #6e0a12
            }
        }
