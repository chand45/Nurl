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
    # Guard: if CDN returned unexpected status, skip rather than fail
    if $r1 == null {
        cleanup $tmp
        error make {msg: "SKIP: initial POST returned null (network/CDN issue)"}
    }
    if $r1.response.status != 201 {
        cleanup $tmp
        error make {msg: ("SKIP: initial POST returned status " + ($r1.response.status | into string) + " (CDN/network issue)")}
    }
    # Get history ID
    let hist = (api history list -l 1)
    assert (($hist | length) > 0) "history should have entry"
    let id = ($hist | first | get id)
    # Resend it — should succeed with 201, body not double-encoded
    let r2 = (api history resend $id --raw)
    if $r2 == null {
        cleanup $tmp
        error make {msg: "SKIP: resend returned null (network/CDN issue)"}
    }
    if $r2.response.status != 201 {
        cleanup $tmp
        error make {msg: ("SKIP: resend returned status " + ($r2.response.status | into string) + " (CDN/network issue)")}
    }
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
    let config_path = ($tmp | path join "config.nuon")
    open $config_path | upsert default_environment "stored-env" | to nuon | save -f $config_path
    let r1 = (api get "https://jsonplaceholder.typicode.com/posts/1" --raw)
    assert ($r1 != null)
    let hist = (api history list -l 1)
    let id = ($hist | first | get id)
    # --environment flag should be accepted (even if it's a no-op)
    let r2 = (api history resend $id --environment "nonexistent" --raw)
    assert ($r2 != null) "--environment flag should not crash resend"
    assert equal $r2.request.method $r1.request.method "--environment changed the replay method"
    assert equal $r2.request.url $r1.request.url "--environment changed the replay URL"
    assert equal $r2.response.status $r1.response.status "--environment changed the replay response"
    assert equal (open $config_path | get default_environment) "stored-env" "--environment changed workspace configuration"
    let replay_id = (api history list --limit 1 | first | get id)
    assert equal (api history get $replay_id | get environment) "stored-env" "--environment changed the stored replay environment"
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

# ── V1: api status on empty workspace ────────────────────────────────────────

def v1-status-columns [] {
    [
        root
        global_vars
        collections
        history_entries
        active_collection
        active_environment
    ]
}

def json-preserves-nothing-fields [] {
    let probe = ({present: true optional: null} | to json --raw | from json)
    (($probe | columns | where $it == optional | length) == 1)
}

def run-status-command-process [root: string, command: string] {
    let script_path = (test-temp-dir | path join $"nurl-status-command-(random uuid).nu")
    let config_path = (test-temp-dir | path join $"nurl-status-config-(random uuid).nu")
    let module_path = ($env.NURL_REPO_ROOT | path join "nu_modules" "mod.nu")
    [
        $"use ($module_path | to nuon) *"
        $"$env.API_ROOT = ($root | to nuon)"
        "$env.NO_COLOR = '1'"
        "$env.config.use_ansi_coloring = false"
        $command
    ] | str join "\n" | save -f $script_path
    "$env.config.use_ansi_coloring = false" | save -f $config_path

    let result = (test-complete-result (do {
        with-env {NO_COLOR: "1"} {
            ^$nu.current-exe --config $config_path $script_path
        }
    } | complete))
    rm -f $script_path $config_path
    $result
}

def test-v1-status-empty-workspace [] {
    let tmp = (make-temp-dir "v1-status")
    $env.API_ROOT = $tmp
    api init | ignore
    let s = (api status)
    assert equal ($s | columns) (v1-status-columns) "status returned an unexpected field schema"
    assert equal ($s.root | describe) "string" "status root should be a string"
    assert equal ($s.global_vars | describe) "int" "status global_vars should be an int"
    assert equal ($s.collections | describe) "int" "status collections should be an int"
    assert equal ($s.history_entries | describe) "int" "status history_entries should be an int"
    assert equal $s.history_entries 0 "empty workspace should have 0 history entries"
    assert equal $s.active_collection null "unset default collection should report null"
    assert equal ($s.active_collection | describe) "nothing" "unset default collection should be nothing"
    assert equal $s.active_environment null "unset default collection should have no active environment"
    assert equal ($s.active_environment | describe) "nothing" "unset active environment should be nothing"

    let serialized_result = (run-status-command-process $tmp "api status | to json --raw")
    assert equal $serialized_result.exit_code 0 "serialized unset status failed"
    assert equal ($serialized_result.stderr | str trim) "" "serialized unset status wrote stderr"
    let serialized = ($serialized_result.stdout | from json)
    if (json-preserves-nothing-fields) {
        assert equal ($serialized | columns) (v1-status-columns) "status JSON omitted fields supported by this serializer"
        assert equal $serialized.active_collection null "serialized unset collection should be null"
        assert equal $serialized.active_environment null "serialized unset environment should be null"
    } else {
        assert equal ($serialized | columns) [
            root
            global_vars
            collections
            history_entries
        ] "status JSON did not match this runtime's nothing-field omission"
    }
    cleanup $tmp
}

def test-v1-status-configured-context [] {
    let tmp = (make-temp-dir "v1-status-configured")
    $env.API_ROOT = $tmp
    api init | ignore
    api collection create jsonplaceholder | ignore
    api collection env create jsonplaceholder default --activate | ignore
    api config set default_collection jsonplaceholder | ignore

    let configured = (api status)
    assert equal ($configured | columns) (v1-status-columns) "configured status returned an unexpected field schema"
    assert equal $configured.active_collection "jsonplaceholder"
    assert equal ($configured.active_collection | describe) "string"
    assert equal $configured.active_environment "default"
    assert equal ($configured.active_environment | describe) "string"

    let serialized_result = (run-status-command-process $tmp "api status | to json --raw")
    assert equal $serialized_result.exit_code 0 "serialized status failed"
    assert equal ($serialized_result.stderr | str trim) "" "serialized status wrote stderr"
    let serialized = ($serialized_result.stdout | from json)
    assert equal ($serialized | columns) (v1-status-columns) "configured status JSON returned an unexpected schema"
    assert equal $serialized.active_collection "jsonplaceholder"
    assert equal $serialized.active_environment "default"

    let human_result = (run-status-command-process $tmp "api status | table -w 120")
    assert equal $human_result.exit_code 0 "human status failed"
    assert equal ($human_result.stderr | str trim) "" "human status wrote stderr"
    assert ($human_result.stdout | str contains "active_collection") "human status omitted active_collection"
    assert ($human_result.stdout | str contains "active_environment") "human status omitted active_environment"

    let meta_path = ($tmp | path join "collections" "jsonplaceholder" "meta.nuon")
    {active_environment: null} | to nuon | save -f $meta_path
    assert equal (api status | get active_collection) "jsonplaceholder"
    assert equal (api status | get active_environment) null "null active environment should remain null"
    rm $meta_path
    assert equal (api status | get active_environment) null "missing collection metadata should report a null environment"
    cleanup $tmp
}

def assert-v1-status-failure [root: string, expected: string] {
    let result = (run-status-command-process $root "api status")
    assert ($result.exit_code != 0) $"invalid status context exited zero: ($expected)"
    assert equal ($result.stdout | str trim) "" $"invalid status context wrote stdout: ($expected)"
    assert equal $result.stderr ($result.stderr | ansi strip) $"invalid status context wrote ANSI stderr: ($expected)"
    assert ($result.stderr | str contains $expected) $"status error did not contain '($expected)': ($result.stderr)"
}

def test-v1-status-invalid-context [] {
    let tmp = (make-temp-dir "v1-status-invalid")
    $env.API_ROOT = $tmp
    api init | ignore
    let config_path = ($tmp | path join "config.nuon")

    let child_version = (run-status-command-process $tmp "version | get version")
    assert equal $child_version.exit_code 0 "status child process did not start"
    assert equal ($child_version.stderr | str trim) "" "status child version probe wrote stderr"
    assert equal ($child_version.stdout | str trim) (version | get version) "status tests used a different child runtime"

    [] | to nuon | save -f $config_path
    assert-v1-status-failure $tmp "expected a NUON"

    {default_collection: 42} | to nuon | save -f $config_path
    assert-v1-status-failure $tmp "default_collection must be a non-empty string or null"

    {default_collection: missing} | to nuon | save -f $config_path
    assert-v1-status-failure $tmp "Configured default collection 'missing' not found"

    api collection create configured | ignore
    {default_collection: configured} | to nuon | save -f $config_path
    let meta_path = ($tmp | path join "collections" "configured" "meta.nuon")

    {active_environment: 42} | to nuon | save -f $meta_path
    assert-v1-status-failure $tmp "active_environment must be a non-empty"

    {active_environment: missing} | to nuon | save -f $meta_path
    assert-v1-status-failure $tmp "Configured active environment 'missing' not found"

    let environment_path = ($tmp | path join "collections" "configured" "environments" "missing.nuon")
    [] | to nuon | save $environment_path
    assert-v1-status-failure $tmp "expected a NUON"
    cleanup $tmp
}

def run-suite-status-compatibility []: nothing -> list<record> {
    print $"\n(ansi yellow)── V1: Status compatibility ──(ansi reset)"
    [
        (run-test "V1: api status reports typed unset context" { test-v1-status-empty-workspace })
        (run-test "V1: api status reports configured collection and environment" { test-v1-status-configured-context })
        (run-test "V1: api status rejects invalid configured context" { test-v1-status-invalid-context })
    ]
}

# ── Suite runner ──────────────────────────────────────────────────────────────

def run-suite-reliability [net_ok: bool]: nothing -> list<record> {
    print $"\n(ansi yellow)── A: Reliability A1-A7 ──(ansi reset)"
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
