workspace extends model.dsl {
    model {
        !element tle.server.proxy {
            tags "removed" "wp:268"
        }
        !element tle.server.games {
            tags "changed" "wp:268"
            description "the single point for every game state change"
        }
        !element tle.server {
            lifecycle = component "Lifecycle" "the one state machine" {
                tags "new" "wp:268"
            }
        }
        tle.server.games -> tle.server.lifecycle "every transition" {
            tags "new" "wp:268"
        }
    }
    views {
        !include views.dsl
    }
}
