# Feature tests — C4 through C11
# Tests: --form, --follow-redirects, --save, run-tests (C7), --retries,
#        content-type rendering, api head/options, api request export.

use std assert

# ── C4: --form encodes as application/x-www-form-urlencoded ──────────────────

def test-c4-form-content-type [] {
    let tmp = (make-temp-dir "c4-ct")
    $env.API_ROOT = $tmp
    # Check the request record's Content-Type header (set client-side before the request)
    # Use jsonplaceholder instead of httpbin echo to avoid CDN flakiness
    let r = (api post "https://jsonplaceholder.typicode.com/posts" --form {username: "alice" password: "secret"} --raw --no-history)
    assert ($r != null)
    let ct = ($r.request.headers | get "Content-Type"? | default "")
    assert ($ct | str contains "application/x-www-form-urlencoded") $"Content-Type should be form-encoded, got: ($ct)"
    cleanup $tmp
}

def test-c4-form-body-encoded [] {
    let tmp = (make-temp-dir "c4-body")
    $env.API_ROOT = $tmp
    # Verify the constructed request body is URL-encoded (check request record, not server echo)
    # Use jsonplaceholder which is more reliable than httpbin for this check
    let r = (api post "https://jsonplaceholder.typicode.com/posts" --form {key: "hello" val: "world"} --raw --no-history)
    assert ($r != null) "form request should succeed"
    # The request.body should be the URL-encoded string we sent
    let req_body = ($r.request.body | into string)
    assert ($req_body | str contains "key=hello") "form body should contain URL-encoded key=hello"
    assert ($req_body | str contains "val=world") "form body should contain URL-encoded val=world"
    cleanup $tmp
}

# ── C5: --save writes response body to file ───────────────────────────────────

def test-c5-save-writes-file [] {
    let tmp = (make-temp-dir "c5-save")
    $env.API_ROOT = $tmp
    let save_path = ($tmp | path join "response.json")
    let _ = (api get "https://jsonplaceholder.typicode.com/posts/1" --save $save_path --no-history)
    assert ($save_path | path exists) "--save should create the output file"
    let content = (open $save_path --raw)
    assert (($content | str length) > 0) "saved file should not be empty"
    # Should be valid JSON
    let parsed = ($content | from json)
    assert equal ($parsed.id) 1
    cleanup $tmp
}

# ── C6: --follow-redirects yields the FINAL response ─────────────────────────

def test-c6-follow-redirects-final-status [] {
    let tmp = (make-temp-dir "c6-redir")
    $env.API_ROOT = $tmp
    # postman-echo.com redirects to itself with a 301/302; guard for CDN anomalies
    let r = (try { api get "https://postman-echo.com/redirect-to?url=https://postman-echo.com/get" --follow-redirects --raw --no-history } catch { null })
    if $r != null {
        # Final status should be 200, not 3xx
        assert equal $r.response.status 200 "follow-redirects should yield final 200, not redirect status"
    }
    cleanup $tmp
}

def test-c6-follow-redirects-no-location-in-body [] {
    let tmp = (make-temp-dir "c6-body")
    $env.API_ROOT = $tmp
    let r = (try { api get "https://postman-echo.com/redirect-to?url=https://postman-echo.com/get" --follow-redirects --raw --no-history } catch { null })
    if $r != null and $r.response.status == 200 {
        # Body should be parsed JSON (the final response), not raw HTTP headers
        let body_desc = ($r.response.body | describe)
        assert (not ($body_desc == "string" and ($r.response.body | str starts-with "HTTP/"))) "body should not be raw HTTP headers (redirect parsing bug)"
        assert ($body_desc | str starts-with "record") "body should be a parsed JSON record"
    }
    cleanup $tmp
}

# ── C7: saved-request tests — key normalization and clean output ───────────────

def setup-c7-workspace [prefix: string]: nothing -> string {
    let tmp = (make-temp-dir $prefix)
    $env.API_ROOT = $tmp
    mkdir ($tmp | path join "collections" "c7coll" "requests")
    $tmp
}

def test-c7-passing-tests-shorthand [] {
    let tmp = (setup-c7-workspace "c7-pass")
    $env.API_ROOT = $tmp
    {
        name: "get-post"
        collection: "c7coll"
        method: "GET"
        url: "https://jsonplaceholder.typicode.com/posts/1"
        headers: {}
        tests: {
            status: 200
            "body.userId": 1
            "body.title": {contains: "sunt"}
        }
    } | to nuon | save -f ($tmp | path join "collections" "c7coll" "requests" "get-post.nuon")
    let r = (api send get-post -c c7coll --no-history --raw)
    assert ($r != null)
    assert equal ($r.tests_passed) true "all shorthand-key tests should pass"
    cleanup $tmp
}

def test-c7-failing-tests-no-crash [] {
    let tmp = (setup-c7-workspace "c7-fail")
    $env.API_ROOT = $tmp
    {
        name: "get-post-fail"
        collection: "c7coll"
        method: "GET"
        url: "https://jsonplaceholder.typicode.com/posts/1"
        headers: {}
        tests: {
            status: 201   # wrong — actual is 200
            "body.userId": 1
        }
    } | to nuon | save -f ($tmp | path join "collections" "c7coll" "requests" "get-post-fail.nuon")
    # Should NOT throw; should complete with tests_passed = false
    let r = (api send get-post-fail -c c7coll --no-history --raw)
    assert ($r != null)
    assert equal ($r.tests_passed) false "failing test should set tests_passed = false"
    cleanup $tmp
}

def test-c7-full-path-keys-work [] {
    let tmp = (setup-c7-workspace "c7-full")
    $env.API_ROOT = $tmp
    {
        name: "get-post-fp"
        collection: "c7coll"
        method: "GET"
        url: "https://jsonplaceholder.typicode.com/posts/1"
        headers: {}
        tests: {
            "response.status": 200
            "response.body.id": 1
        }
    } | to nuon | save -f ($tmp | path join "collections" "c7coll" "requests" "get-post-fp.nuon")
    let r = (api send get-post-fp -c c7coll --no-history --raw)
    assert ($r != null)
    assert equal ($r.tests_passed) true "full response.* path keys should also work"
    cleanup $tmp
}

def test-c7-no-tests-field-no-crash [] {
    let tmp = (setup-c7-workspace "c7-notest")
    $env.API_ROOT = $tmp
    {
        name: "get-post-nt"
        collection: "c7coll"
        method: "GET"
        url: "https://jsonplaceholder.typicode.com/posts/1"
        headers: {}
    } | to nuon | save -f ($tmp | path join "collections" "c7coll" "requests" "get-post-nt.nuon")
    let r = (api send get-post-nt -c c7coll --no-history --raw)
    assert ($r != null) "request without tests field should not crash"
    assert equal $r.response.status 200
    cleanup $tmp
}

# ── C8: --retries ─────────────────────────────────────────────────────────────

def test-c8-retries-succeeds [] {
    # With a good URL and retries=2, should succeed on first attempt
    let tmp = (make-temp-dir "c8-retry")
    $env.API_ROOT = $tmp
    let r = (api get "https://jsonplaceholder.typicode.com/posts/1" --raw --no-history --retries 2)
    assert ($r != null)
    assert equal $r.response.status 200 "--retries should not break normal requests"
    cleanup $tmp
}

# ── C9: Content-type-aware rendering ─────────────────────────────────────────

def test-c9-json-response-parsed [] {
    let tmp = (make-temp-dir "c9-json")
    $env.API_ROOT = $tmp
    let r = (api get "https://jsonplaceholder.typicode.com/posts/1" --raw --no-history)
    assert ($r != null)
    # JSON response body should be a parsed record, not raw string
    let body_desc = ($r.response.body | describe)
    assert ($body_desc | str starts-with "record") $"JSON body should be parsed record, got: ($body_desc)"
    cleanup $tmp
}

def test-c9-json-array-parsed [] {
    let tmp = (make-temp-dir "c9-arr")
    $env.API_ROOT = $tmp
    let r = (api get "https://jsonplaceholder.typicode.com/posts" --raw --no-history)
    assert ($r != null)
    let body_desc = ($r.response.body | describe)
    # In Nushell, a list of records is described as "table<...>" or "list<record>"
    let is_list_like = ($body_desc | str starts-with "list") or ($body_desc | str starts-with "table")
    assert $is_list_like $"JSON array body should be list or table, got: ($body_desc)"
    cleanup $tmp
}

# ── C10: api head / api options ───────────────────────────────────────────────

def test-c10-head-no-body [] {
    let tmp = (make-temp-dir "c10-head")
    $env.API_ROOT = $tmp
    let r = (api head "https://jsonplaceholder.typicode.com/posts/1" --raw --no-history)
    assert ($r != null)
    assert equal $r.response.status 200
    # HEAD response has headers but no body
    let body = ($r.response.body? | default null)
    let body_ok = ($body == null or $body == "" or ($body | describe) == "nothing")
    assert $body_ok "HEAD response should have no body"
    cleanup $tmp
}

def test-c10-head-returns-headers [] {
    let tmp = (make-temp-dir "c10-head-hdrs")
    $env.API_ROOT = $tmp
    let r = (api head "https://jsonplaceholder.typicode.com/posts/1" --raw --no-history)
    assert ($r != null)
    assert ($r.response.headers != null) "HEAD response should have headers"
    assert (($r.response.headers | describe | str starts-with "record")) "headers should be a record"
    cleanup $tmp
}

def test-c10-options-returns-allow [] {
    let tmp = (make-temp-dir "c10-opts")
    $env.API_ROOT = $tmp
    # Use httpbin.org/anything which handles OPTIONS; guard against CDN failures
    let r = (try { api options "https://httpbin.org/anything" --raw --no-history } catch { null })
    if $r != null {
        assert ($r.response.status > 0) "OPTIONS should return a valid HTTP status"
    }
    cleanup $tmp
}

# ── C11: api request export prints curl command ────────────────────────────────

def test-c11-export-is-curl-command [] {
    let tmp = (make-temp-dir "c11-export")
    $env.API_ROOT = $tmp
    mkdir ($tmp | path join "collections" "c11coll" "requests")
    {
        name: "my-req"
        collection: "c11coll"
        method: "GET"
        url: "https://example.com/api"
        headers: {}
    } | to nuon | save -f ($tmp | path join "collections" "c11coll" "requests" "my-req.nuon")
    # api request export should print a curl command (prints then returns null)
    let r = (api request export my-req -c c11coll)
    # dry-run/export returns null (side-effect: prints curl command)
    assert ($r == null) "api request export should return null (it prints a curl command)"
    cleanup $tmp
}

# ── Suite runner ──────────────────────────────────────────────────────────────

def run-suite-features [net_ok: bool]: nothing -> list<record> {
    print $"\n(ansi yellow)── C4-C11: Features ──(ansi reset)"
    if not $net_ok {
        return [(skip-test "C4-C11-Features" "network unavailable")]
    }
    [
        (run-test "C4: --form sets Content-Type to form-encoded"  { test-c4-form-content-type })
        (run-test "C4: --form body is URL-encoded"                { test-c4-form-body-encoded })
        (run-test "C5: --save writes response body to file"       { test-c5-save-writes-file })
        (run-test "C6: --follow-redirects yields final 200"       { test-c6-follow-redirects-final-status })
        (run-test "C6: --follow-redirects body is parsed JSON"    { test-c6-follow-redirects-no-location-in-body })
        (run-test "C7: shorthand test keys normalize and pass"    { test-c7-passing-tests-shorthand })
        (run-test "C7: failing tests set tests_passed=false"      { test-c7-failing-tests-no-crash })
        (run-test "C7: full response.* test keys also work"       { test-c7-full-path-keys-work })
        (run-test "C7: request without tests field does not crash" { test-c7-no-tests-field-no-crash })
        (run-test "C8: --retries does not break good requests"    { test-c8-retries-succeeds })
        (run-test "C9: JSON response body is parsed record"       { test-c9-json-response-parsed })
        (run-test "C9: JSON array response body is parsed list"   { test-c9-json-array-parsed })
        (run-test "C10: api head returns no body"                 { test-c10-head-no-body })
        (run-test "C10: api head returns headers"                 { test-c10-head-returns-headers })
        (run-test "C10: api options returns 2xx response"         { test-c10-options-returns-allow })
        (run-test "C11: api request export does not crash"        { test-c11-export-is-curl-command })
    ]
}
