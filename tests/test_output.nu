# Output contract tests — C1, C2, C3
# Verifies the output-mode contract: data modes return typed values,
# pretty mode prints and returns null, --select normalizes paths.

# ── C1: Data modes return typed values ────────────────────────────────────────

def test-c1-raw-describe [] {
    let tmp = (make-temp-dir "c1-raw")
    $env.API_ROOT = $tmp
    let r = (api get "https://jsonplaceholder.typicode.com/posts/1" --raw --no-history)
    assert ($r != null) "--raw must return non-null"
    let d = ($r | describe)
    assert ($d | str starts-with "record") $"--raw must return record, got: ($d)"
    cleanup $tmp
}

def test-c1-output-status-returns-int [] {
    let tmp = (make-temp-dir "c1-status")
    $env.API_ROOT = $tmp
    let s = (api get "https://jsonplaceholder.typicode.com/posts/1" --output status --no-history)
    assert equal ($s | describe) "int" "--output status must return int"
    assert equal $s 200
    cleanup $tmp
}

def test-c1-output-body-returns-value [] {
    let tmp = (make-temp-dir "c1-body")
    $env.API_ROOT = $tmp
    let b = (api get "https://jsonplaceholder.typicode.com/posts/1" --output body --no-history)
    assert ($b != null) "--output body must return non-null"
    # Should be a parsed record (JSON object)
    assert ($b | describe | str starts-with "record") "--output body for JSON should return record"
    cleanup $tmp
}

def test-c1-output-headers-returns-record [] {
    let tmp = (make-temp-dir "c1-headers")
    $env.API_ROOT = $tmp
    let h = (api get "https://jsonplaceholder.typicode.com/posts/1" --output headers --no-history)
    assert ($h != null) "--output headers must return non-null"
    assert ($h | describe | str starts-with "record") "--output headers must return record"
    # Should have Content-Type header
    assert (($h | get "Content-Type"? | default null) != null) "headers should include Content-Type"
    cleanup $tmp
}

def test-c1-output-json-returns-string [] {
    let tmp = (make-temp-dir "c1-json")
    $env.API_ROOT = $tmp
    let j = (api get "https://jsonplaceholder.typicode.com/posts/1" --output json --no-history)
    assert equal ($j | describe) "string" "--output json must return string"
    # Should be parseable JSON
    let parsed = ($j | from json)
    assert (($parsed | get request? | default null) != null) "json should include request field"
    cleanup $tmp
}

def test-c1-output-none-returns-null [] {
    let tmp = (make-temp-dir "c1-none")
    $env.API_ROOT = $tmp
    let n = (api get "https://jsonplaceholder.typicode.com/posts/1" --output none --no-history)
    assert ($n == null) "--output none must return null"
    cleanup $tmp
}

def test-c1-pretty-returns-null [] {
    let tmp = (make-temp-dir "c1-pretty")
    $env.API_ROOT = $tmp
    let n = (api get "https://jsonplaceholder.typicode.com/posts/1" --no-history)
    assert ($n == null) "default pretty mode must return null"
    cleanup $tmp
}

# ── C2: --select shorthand path normalization ─────────────────────────────────

def test-c2-select-body-field [] {
    let tmp = (make-temp-dir "c2-body")
    $env.API_ROOT = $tmp
    let id = (api get "https://jsonplaceholder.typicode.com/posts/1" --select body.id --no-history)
    assert equal ($id | describe) "int" "--select body.id should return int"
    assert equal $id 1
    cleanup $tmp
}

def test-c2-select-body-userid [] {
    let tmp = (make-temp-dir "c2-userid")
    $env.API_ROOT = $tmp
    let uid = (api get "https://jsonplaceholder.typicode.com/posts/1" --select body.userId --no-history)
    assert equal ($uid | describe) "int"
    assert equal $uid 1
    cleanup $tmp
}

def test-c2-select-status [] {
    let tmp = (make-temp-dir "c2-status")
    $env.API_ROOT = $tmp
    let s = (api get "https://jsonplaceholder.typicode.com/posts/1" --select status --no-history)
    assert equal ($s | describe) "int" "--select status should return int"
    assert equal $s 200
    cleanup $tmp
}

def test-c2-select-headers [] {
    let tmp = (make-temp-dir "c2-headers")
    $env.API_ROOT = $tmp
    let ct = (api get "https://jsonplaceholder.typicode.com/posts/1" --select "headers.Content-Type" --no-history)
    assert ($ct != null) "--select headers.Content-Type should return a value"
    assert (($ct | describe) == "string") "Content-Type should be a string"
    assert ($ct | str contains "application/json") "Content-Type should be JSON"
    cleanup $tmp
}

def test-c2-select-missing-path-no-crash [] {
    # A missing --select path must NOT crash; it should return null
    let tmp = (make-temp-dir "c2-missing")
    $env.API_ROOT = $tmp
    # This should not throw; it should return null (with a printed warning)
    let v = (api get "https://jsonplaceholder.typicode.com/posts/1" --select body.doesNotExist --no-history)
    assert ($v == null) "missing --select path should return null, not crash"
    cleanup $tmp
}

def test-c2-select-full-path [] {
    # Full response.body.id path should also work
    let tmp = (make-temp-dir "c2-full")
    $env.API_ROOT = $tmp
    let id = (api get "https://jsonplaceholder.typicode.com/posts/1" --select response.body.id --no-history)
    assert equal $id 1
    cleanup $tmp
}

# ── C3: --verbose and --include ───────────────────────────────────────────────

def test-c3-verbose-shows-request-headers [] {
    # Subprocess test: verify --verbose prints request line (> GET) and response headers (< Header)
    require-network
    let api_path = ($env.NURL_REPO_ROOT | path join "api.nu")
    let nu_exe = $nu.current-exe
    let out = (^$nu_exe -c $"source '($api_path)'; api get 'https://jsonplaceholder.typicode.com/posts/1' --no-history --verbose" | complete)
    let stdout = ($out.stdout | ansi strip)
    assert ($stdout | str contains "> GET") "--verbose should print request line starting with '> GET'"
    assert ($stdout | str contains "< ") "--verbose should print response headers starting with '< '"
}

def test-c3-include-shows-response-headers [] {
    # Subprocess test: verify --include prints response headers above the body
    require-network
    let api_path = ($env.NURL_REPO_ROOT | path join "api.nu")
    let nu_exe = $nu.current-exe
    let out = (^$nu_exe -c $"source '($api_path)'; api get 'https://jsonplaceholder.typicode.com/posts/1' --no-history --include" | complete)
    let stdout = ($out.stdout | ansi strip)
    # Response headers should appear (Content-Type is always present)
    assert ($stdout | str contains "< Content-Type") "--include should show Content-Type response header"
    # JSON body should also appear
    assert ($stdout | str contains "userId") "--include should still show JSON body"
}

# ── Suite runner ──────────────────────────────────────────────────────────────

def run-suite-output [net_ok: bool]: nothing -> list<record> {
    print $"\n(ansi yellow)── C1-C3: Output Contract ──(ansi reset)"
    if not $net_ok {
        return [(skip-test "C1-C3-Output" "network unavailable")]
    }
    [
        (run-test "C1: --raw returns record"                    { test-c1-raw-describe })
        (run-test "C1: --output status returns int"             { test-c1-output-status-returns-int })
        (run-test "C1: --output body returns parsed value"      { test-c1-output-body-returns-value })
        (run-test "C1: --output headers returns record"         { test-c1-output-headers-returns-record })
        (run-test "C1: --output json returns string"            { test-c1-output-json-returns-string })
        (run-test "C1: --output none returns null"              { test-c1-output-none-returns-null })
        (run-test "C1: pretty mode returns null"                { test-c1-pretty-returns-null })
        (run-test "C2: --select body.id returns int"            { test-c2-select-body-field })
        (run-test "C2: --select body.userId returns int"        { test-c2-select-body-userid })
        (run-test "C2: --select status returns int"             { test-c2-select-status })
        (run-test "C2: --select headers.Content-Type works"     { test-c2-select-headers })
        (run-test "C2: missing --select path does not crash"    { test-c2-select-missing-path-no-crash })
        (run-test "C2: full response.body.* path also works"    { test-c2-select-full-path })
        (run-test "C3: --verbose prints request + response headers" { test-c3-verbose-shows-request-headers })
        (run-test "C3: --include prints response headers above body"  { test-c3-include-shows-response-headers })
    ]
}
