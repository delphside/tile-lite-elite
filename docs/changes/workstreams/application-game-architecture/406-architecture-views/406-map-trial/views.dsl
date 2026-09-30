        container tle "containers" {
            include *
        }
        component tle.server "server-components" {
            include *
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
    
