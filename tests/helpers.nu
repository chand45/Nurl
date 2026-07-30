# Shared test helpers for the Nurl test suite.
# Sourced by run.nu before individual test files.

use test-assert.nu [assert "assert equal" "assert not"]

# ── Infrastructure ────────────────────────────────────────────────────────────

def test-temp-dir [] {
    try { $nu.temp-dir } catch {
        try { $nu.temp-path } catch {
            try { $env.TEMP } catch {
                try { $env.TMPDIR } catch { "/tmp" }
            }
        }
    }
}

def test-complete-result [result: record] {
    $result
    | upsert stdout ($result.stdout? | default "")
    | upsert stderr ($result.stderr? | default "")
    | upsert exit_code ($result.exit_code? | default 1)
}

# Create a unique temp directory and return its absolute path.
def make-temp-dir [prefix: string = "test"] {
    let id = (random uuid | str substring 0..12)
    let tmp = (test-temp-dir | path join $"nurl-($prefix)-($id)")
    mkdir $tmp
    $tmp | path expand
}

# Remove a directory, silently ignoring errors.
def cleanup [path: string] {
    try { rm -rf $path } catch {}
}

# Run an API command in an isolated subprocess and capture all streams.
def run-command-process [root: string, command: string] {
    let script_path = (test-temp-dir | path join $"nurl-command-error-(random uuid).nu")
    let config_path = (test-temp-dir | path join $"nurl-command-config-(random uuid).nu")
    let env_config_path = (test-temp-dir | path join $"nurl-command-env-(random uuid).nu")
    let module_path = ($env.NURL_REPO_ROOT | path join "nu_modules" "mod.nu")
    [
        $"use ($module_path | to nuon) *"
        $"$env.API_ROOT = ($root | to nuon)"
        "$env.NO_COLOR = '1'"
        $command
    ] | str join "\n" | save -f $script_path
    "$env.config.use_ansi_coloring = false" | save -f $config_path
    "# Isolated test environment." | save -f $env_config_path

    let result = (test-complete-result (do {
        ^$nu.current-exe --config $config_path --env-config $env_config_path $script_path
    } | complete))
    rm -f $script_path $config_path $env_config_path
    $result
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
