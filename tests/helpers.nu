# Shared test helpers for the Nurl test suite.
# Sourced by run.nu before individual test files.

use std assert

# ── Infrastructure ────────────────────────────────────────────────────────────

# Create a unique temp directory and return its absolute path.
def make-temp-dir [prefix: string = "test"] {
    let id = (random uuid | str substring 0..12)
    let tmp = ($nu.temp-dir | path join $"nurl-($prefix)-($id)")
    mkdir $tmp
    $tmp | path expand
}

# Remove a directory, silently ignoring errors.
def cleanup [path: string] {
    try { rm -rf $path } catch {}
}

# Initialize a real Nurl workspace at the given path.
# Callers MUST set $env.API_ROOT = $path before calling this.
def init-workspace [] {
    api init
}

# ── Test runner ───────────────────────────────────────────────────────────────

# Run a named test closure; return {name, status, error}.
# status is one of: "pass" | "fail" | "skip"
def run-test [name: string, test: closure] {
    try {
        do $test
        print $"  (ansi green)✓(ansi reset) ($name)"
        {name: $name, status: "pass", error: ""}
    } catch {|e|
        print $"  (ansi red)✗(ansi reset) ($name)"
        print $"    ($e.msg)"
        {name: $name, status: "fail", error: $e.msg}
    }
}

# Skip a test with a reason (returns a skip record without running anything).
def skip-test [name: string, reason: string] {
    print $"  (ansi yellow)⚠(ansi reset) ($name) [SKIP: ($reason)]"
    {name: $name, status: "skip", error: $reason}
}

# ── Network check ─────────────────────────────────────────────────────────────

# Return true if jsonplaceholder.typicode.com is reachable.
# Uses api get internally (api.nu must already be sourced).
def network-ok [] {
    try {
        let r = (api get "https://jsonplaceholder.typicode.com/posts/1" --raw --no-history)
        $r != null and $r.response.status == 200
    } catch {
        false
    }
}
