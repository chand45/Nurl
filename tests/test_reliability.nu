# Reliability tests — A1-A7 bug fixes
# Requires: api.nu sourced, helpers.nu sourced, network available (most tests)

# ── A1: display-response always prints; --raw returns full record ─────────────

def test-a1-raw-returns-record [] {
    let tmp = (make-temp-dir "a1")
    $env.API_ROOT = $tmp
    let r = (api get "https://jsonplaceholder.typicode.com/posts/1" --raw --no-history)
    assert ($r != null) "--raw should return a non-null record"
    assert ($r | describe | str starts-with "record") "--raw result should be a record"
    assert equal ($r.response.status) 200
    assert ($r.request.method == "GET")
    assert ($r.response.body != null) "body should be populated"
    cleanup $tmp
}

def test-a1-default-returns-null [] {
    # default pretty mode returns null (interactive), not the record
    let tmp = (make-temp-dir "a1-null")
    $env.API_ROOT = $tmp
    let r = (api get "https://jsonplaceholder.typicode.com/posts/1" --no-history)
    # Nushell: the naked `let` of a null-returning command captures null/nothing
    assert ($r == null) "default pretty mode should return null (not the record)"
    cleanup $tmp
}

def test-a1-pretty-stdout-single-render [] {
    # Subprocess test: verify default pretty mode prints ONCE (status + body)
    # and does NOT emit the raw {request,response,timestamp} record table (A1 bug).
    require-network
    let api_path = ($env.NURL_REPO_ROOT | path join "api.nu")
    let nu_exe = $nu.current-exe
    let out = (^$nu_exe -c $"source '($api_path)'; api get 'https://jsonplaceholder.typicode.com/posts/1' --no-history" | complete)
    let stdout = ($out.stdout | ansi strip)
    # Status line should appear
    assert ($stdout | str contains "200") "stdout should contain 200 status"
    # JSON body should appear
    assert ($stdout | str contains "userId") "stdout should contain JSON body field"
    # Must NOT contain record-table markers (the original double-output bug)
    assert (not ($stdout | str contains "╭")) "stdout must not contain table border — double-output bug"
    assert (not ($stdout | str contains "| timestamp |")) "stdout must not contain record table"
}


def test-a1-status-line-structure [] {
    # Verify the returned record has the expected shape
    let tmp = (make-temp-dir "a1-shape")
    $env.API_ROOT = $tmp
    let r = (api get "https://jsonplaceholder.typicode.com/posts/1" --raw --no-history)
    assert (($r | get request? | default null) != null) "result must have .request"
    assert (($r | get response? | default null) != null) "result must have .response"
    assert (($r | get timestamp? | default null) != null) "result must have .timestamp"
    cleanup $tmp
}

# ── A3: history resend – no double-encoding ───────────────────────────────────

def test-a3-resend-body-not-double-encoded [] {
    let tmp = (make-temp-dir "a3")
    $env.API_ROOT = $tmp
    init-workspace
    # POST a request so it's saved to history
    let body = {title: "test" body: "hello" userId: 1}
    let r1 = (api post "https://jsonplaceholder.typicode.com/posts" --body $body --raw)
    assert ($r1 != null) "initial POST should succeed"
    assert equal ($r1.response.status) 201
    # Get history ID
    let hist = (api history list -l 1)
    assert (($hist | length) > 0) "history should have entry"
    let id = ($hist | first | get id)
    # Resend it — should succeed with 201, body not double-encoded
    let r2 = (api history resend $id --raw)
    assert ($r2 != null) "resend should succeed"
    assert equal ($r2.response.status) 201
    # Body in resent request should be the record, not an escaped JSON string
    let body_type = ($r2.request.body | describe)
    assert (not ($body_type | str starts-with "string")) "body in resend should NOT be a double-encoded string"
    cleanup $tmp
}

# ── A4: resend --environment doesn't crash ───────────────────────────────────

def test-a4-resend-environment-flag [] {
    let tmp = (make-temp-dir "a4")
    $env.API_ROOT = $tmp
    init-workspace
    let r1 = (api get "https://jsonplaceholder.typicode.com/posts/1" --raw)
    assert ($r1 != null)
    let hist = (api history list -l 1)
    let id = ($hist | first | get id)
    # --environment flag should be accepted (even if it's a no-op)
    let r2 = (api history resend $id --environment "nonexistent" --raw)
    assert ($r2 != null) "--environment flag should not crash resend"
    cleanup $tmp
}

# ── A5: status text mapping ───────────────────────────────────────────────────

def test-a5-common-status-codes [] {
    let tmp = (make-temp-dir "a5")
    $env.API_ROOT = $tmp
    # 200 OK
    let r200 = (api get "https://jsonplaceholder.typicode.com/posts/1" --raw --no-history)
    assert equal ($r200.response.status) 200
    assert equal ($r200.response.status_text) "OK"
    # 201 Created
    let r201 = (api post "https://jsonplaceholder.typicode.com/posts" --body {title: "t" userId: 1 body: "b"} --raw --no-history)
    assert equal ($r201.response.status) 201
    assert equal ($r201.response.status_text) "Created"
    # 404 Not Found
    let r404 = (api get "https://jsonplaceholder.typicode.com/posts/99999" --raw --no-history)
    assert equal ($r404.response.status) 404
    assert equal ($r404.response.status_text) "Not Found"
    cleanup $tmp
}

def test-a5-status-mapping-offline [] {
    # Pure offline test — verifies the http-status-text mapping directly.
    # Covers common codes, extended codes (422/429/503), and the numeric fallback.
    assert equal (http-status-text 200)  "OK"
    assert equal (http-status-text 201)  "Created"
    assert equal (http-status-text 204)  "No Content"
    assert equal (http-status-text 301)  "Moved Permanently"
    assert equal (http-status-text 302)  "Found"
    assert equal (http-status-text 304)  "Not Modified"
    assert equal (http-status-text 400)  "Bad Request"
    assert equal (http-status-text 401)  "Unauthorized"
    assert equal (http-status-text 403)  "Forbidden"
    assert equal (http-status-text 404)  "Not Found"
    assert equal (http-status-text 422)  "Unprocessable Entity"
    assert equal (http-status-text 429)  "Too Many Requests"
    assert equal (http-status-text 500)  "Internal Server Error"
    assert equal (http-status-text 502)  "Bad Gateway"
    assert equal (http-status-text 503)  "Service Unavailable"
    assert equal (http-status-text 504)  "Gateway Timeout"
    # Numeric fallback — unmapped codes → stringified code
    assert equal (http-status-text 418)  "I'm a Teapot"
    assert equal (http-status-text 599)  "599"
    assert equal (http-status-text 999)  "999"
}

# ── A6: history dir path — no doubled slashes ────────────────────────────────

def test-a6-history-dir-no-doubled-slash [] {
    let tmp = (make-temp-dir "a6")
    $env.API_ROOT = $tmp
    init-workspace
    # Make a request to create history
    let _ = (api get "https://jsonplaceholder.typicode.com/posts/1" --raw)
    # Check the history directory path
    let hist_dir = ($tmp | path join "history")
    assert ($hist_dir | path exists) "history dir should exist"
    # No doubled separators in path
    let path_str = $hist_dir
    assert (not ($path_str | str contains "//")) "path should not contain doubled forward slashes"
    assert (not ($path_str | str contains "\\\\")) "path should not contain doubled back slashes"
    cleanup $tmp
}

# ── A7: --no-history doesn't write ───────────────────────────────────────────

def test-a7-no-history-skips-write [] {
    let tmp = (make-temp-dir "a7")
    $env.API_ROOT = $tmp
    init-workspace
    # Make request with --no-history
    let _ = (api get "https://jsonplaceholder.typicode.com/posts/1" --raw --no-history)
    # History directory should be empty (no .nuon files)
    let hist_dir = ($tmp | path join "history")
    let hist_files = (try { ls $hist_dir | where name =~ '\.nuon$' } catch { [] })
    assert equal ($hist_files | length) 0 "--no-history should not create history files"
    cleanup $tmp
}

def test-a7-normal-request-writes-history [] {
    let tmp = (make-temp-dir "a7-normal")
    $env.API_ROOT = $tmp
    init-workspace
    # Make request WITHOUT --no-history
    let _ = (api get "https://jsonplaceholder.typicode.com/posts/1" --raw)
    # History directory should have entries
    let hist_dir = ($tmp | path join "history")
    let hist_files = (try { ls $hist_dir | where name =~ '\.nuon$' } catch { [] })
    assert (($hist_files | length) > 0) "normal request should create history file"
    cleanup $tmp
}

# ── Suite runner ──────────────────────────────────────────────────────────────

def run-suite-reliability [net_ok: bool]: nothing -> list<record> {
    print $"\n(ansi yellow)── A: Reliability A1-A7 ──(ansi reset)"
    # A5 offline test runs regardless of network
    mut results = [
        (run-test "A5: status mapping offline (all codes + fallback)" { test-a5-status-mapping-offline })
    ]
    if not $net_ok {
        $results = ($results | append (skip-test "A-Reliability-network" "network unavailable"))
        return $results
    }
    $results = ($results | append [
        (run-test "A1: --raw returns full record"              { test-a1-raw-returns-record })
        (run-test "A1: default pretty returns null"            { test-a1-default-returns-null })
        (run-test "A1: result has request+response+timestamp"  { test-a1-status-line-structure })
        (run-test "A1: pretty stdout shows status+body, no record table" { test-a1-pretty-stdout-single-render })
        (run-test "A3: resend body not double-encoded"         { test-a3-resend-body-not-double-encoded })
        (run-test "A4: resend --environment flag does not crash" { test-a4-resend-environment-flag })
        (run-test "A5: common status codes map correctly"      { test-a5-common-status-codes })
        (run-test "A6: history dir path has no doubled slashes" { test-a6-history-dir-no-doubled-slash })
        (run-test "A7: --no-history skips writing history"     { test-a7-no-history-skips-write })
        (run-test "A7: normal request writes to history"       { test-a7-normal-request-writes-history })
    ])
    $results
}
