# Shared test helpers for the Nurl test suite.
# Sourced by run.nu before individual test files.

use test-assert.nu [assert "assert equal" "assert not"]

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

# ── Skip mechanism ────────────────────────────────────────────────────────────

# Throw a SKIP signal from inside a test when a precondition is not met.
# run-test catches this and marks the test as skipped (not failed).
def require-network [] {
    let ok = (try {
        let r = (^curl -s --max-time 5 "https://jsonplaceholder.typicode.com/posts/1" | complete)
        $r.exit_code == 0
    } catch { false })
    if not $ok {
        error make {msg: "SKIP: network unavailable"}
    }
}

# ── Test runner ───────────────────────────────────────────────────────────────

# Run a named test closure; return {name, status, error}.
# status is one of: "pass" | "fail" | "skip"
# Tests may signal a skip by throwing an error whose msg starts with "SKIP:".
def run-test [name: string, test: closure] {
    try {
        do $test
        print $"  (ansi green)✓(ansi reset) ($name)"
        {name: $name, status: "pass", error: ""}
    } catch {|e|
        if ($e.msg | str starts-with "SKIP:") {
            let reason = ($e.msg | str replace --regex "^SKIP:\\s*" "")
            print $"  (ansi yellow)⚠(ansi reset) ($name) [skipped: ($reason)]"
            return {name: $name, status: "skip", error: $reason}
        }
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
