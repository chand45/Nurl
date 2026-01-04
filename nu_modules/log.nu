# Logging Utility Module
# Controls debug output based on $env.API_DEBUG flag
# Usage: Commands with --debug flag should set $env.API_DEBUG = true

# Check if debug mode is enabled
def is-debug [] {
    ($env.API_DEBUG? | default false) == true
}

# Debug message (only shown with --debug) - dark gray
export def "log debug" [msg: string] {
    if (is-debug) {
        print $"(ansi dark_gray)($msg)(ansi reset)"
    }
}

# Info message (only shown with --debug) - blue
export def "log info" [msg: string] {
    if (is-debug) {
        print $"(ansi blue)($msg)(ansi reset)"
    }
}

# Success message (only shown with --debug) - green
export def "log success" [msg: string] {
    if (is-debug) {
        print $"(ansi green)($msg)(ansi reset)"
    }
}

# Warning message (only shown with --debug) - yellow
export def "log warn" [msg: string] {
    if (is-debug) {
        print $"(ansi yellow)($msg)(ansi reset)"
    }
}

# Error message (ALWAYS shown) - red
export def "log error" [msg: string] {
    print $"(ansi red)($msg)(ansi reset)"
}

# Status line for HTTP responses (only shown with --debug)
# Takes status code, status text, time in ms, and size in bytes
export def "log status" [status: int, status_text: string, time_ms: int, size_bytes: int] {
    if (is-debug) {
        let status_color = if $status >= 200 and $status < 300 {
            "green"
        } else if $status >= 400 {
            "red"
        } else {
            "yellow"
        }
        print $"(ansi $status_color)($status) ($status_text)(ansi reset) (ansi dark_gray)($time_ms)ms, ($size_bytes) bytes(ansi reset)"
        print ""
    }
}
