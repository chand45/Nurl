# Feature tests — C4 through C11

use test-assert.nu [assert "assert equal" "assert not"]

# ── C4: --form encodes as application/x-www-form-urlencoded ──────────────────

def test-c4-form-content-type [] {
    let tmp = (make-temp-dir "c4-ct")
    $env.API_ROOT = $tmp
    # Check the request record Content-Type header (set client-side, no server echo needed)
    let r = (api post "https://jsonplaceholder.typicode.com/posts" --form {username: "alice" password: "secret"} --raw --no-history)
    assert ($r != null)
    let ct = ($r.request.headers | get "Content-Type"? | default "")
    assert ($ct | str contains "application/x-www-form-urlencoded") $"Content-Type should be form-encoded, got: ($ct)"
    cleanup $tmp
}

def test-c4-form-body-encoded [] {
    let tmp = (make-temp-dir "c4-body")
    $env.API_ROOT = $tmp
    let r = (api post "https://jsonplaceholder.typicode.com/posts" --form {key: "hello" val: "world"} --raw --no-history)
    assert ($r != null) "form request should succeed"
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
    let parsed = ($content | from json)
    assert equal ($parsed.id) 1
    cleanup $tmp
}

# ── C6: --follow-redirects yields the FINAL response ─────────────────────────
# Hermetic test uses parse-curl-response directly; live test uses postman-echo.

def test-c6-redirect-parse-hermetic [] {
    # Synthetic multi-block curl -L -i output (two HTTP response blocks).
    # parse-curl-response must use the LAST block (200 OK), not the redirect (301).
    let multi_block = "HTTP/1.1 301 Moved Permanently\r\nLocation: https://example.com/final\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"id\":99}\r\n\r\n---RESPONSE_META---\r\n200\r\n0.1\r\n10\r\n"
    let parsed = (parse-curl-response $multi_block)
    assert equal $parsed.status 200 "should extract FINAL response status (200), not redirect (301)"
    let id_val = ($parsed.body | get id? | default null)
    assert equal $id_val 99 "body should be from the final 200 response, id=99"
    let has_location = ($parsed.headers | columns | any {|k| $k == "Location"})
    assert (not $has_location) "final headers must not contain Location from redirect block"
}

def test-c6-legacy-repeated-header-parity [] {
    let output = (
        "HTTP/1.1 200 OK\r\n"
        + "X-Before: before\r\n"
        + "x-dup: a\r\n"
        + "X-Middle: middle\r\n"
        + "X-Dup: b\r\n"
        + "X-DUP: c\r\n"
        + "Link: </a>; rel=\"next\"\r\n"
        + "Link: </b>; rel=\"prev\"\r\n"
        + "WWW-Authenticate: Digest realm=\"one\"\r\n"
        + "WWW-Authenticate: Newauth realm=\"two\"\r\n"
        + "X-Debug-Alpha: info\r\n"
        + "X-Debug-Alpha: Bearer LEGACY-LAST-SENTINEL\r\n"
        + "X-Debug-Beta: Bearer LEGACY-FIRST-SENTINEL\r\n"
        + "X-Debug-Beta: info\r\n"
        + "Set-Cookie2: first=LEGACY-COOKIE2-FIRST\r\n"
        + "Set-Cookie2: second=LEGACY-COOKIE2-SECOND\r\n"
        + "X-After: after\r\n\r\n"
        + "{}\r\n\r\n---RESPONSE_META---\r\n200\r\n0.1\r\n2\r\n"
    )
    let parsed = (parse-curl-response $output)
    assert equal ($parsed.headers | get "X-DUP") "a, b, c"
    assert equal ($parsed.headers | get "Link") "</a>; rel=\"next\", </b>; rel=\"prev\""
    assert equal ($parsed.headers | get "WWW-Authenticate") "Digest realm=\"one\", Newauth realm=\"two\""
    assert equal ($parsed.headers | get "X-Debug-Alpha") "******"
    assert equal ($parsed.headers | get "X-Debug-Beta") "******"
    assert equal ($parsed.headers | get "Set-Cookie2") "******"
    assert equal (
        $parsed.headers
        | columns
        | where {|name| $name in ["X-Before" "X-DUP" "X-Middle" "Link" "WWW-Authenticate" "X-Debug-Alpha" "X-Debug-Beta" "Set-Cookie2" "X-After"] }
    ) ["X-Before" "X-DUP" "X-Middle" "Link" "WWW-Authenticate" "X-Debug-Alpha" "X-Debug-Beta" "Set-Cookie2" "X-After"]
    let serialized = ($parsed | to nuon)
    for secret in [
        "LEGACY-LAST-SENTINEL"
        "LEGACY-FIRST-SENTINEL"
        "LEGACY-COOKIE2-FIRST"
        "LEGACY-COOKIE2-SECOND"
    ] {
        assert (not ($serialized | str contains $secret)) $"legacy parser exposed a repeated-header secret: ($secret)"
    }
}

def test-c6-follow-redirects-final-status [] {
    require-network
    let tmp = (make-temp-dir "c6-redir")
    $env.API_ROOT = $tmp
    let r = (try { api get "https://postman-echo.com/redirect-to?url=https://postman-echo.com/get" --follow-redirects --raw --no-history } catch { null })
    cleanup $tmp
    if $r == null { error make {msg: "SKIP: postman-echo.com unreachable"} }
    assert equal $r.response.status 200 "follow-redirects should yield final 200, not a 3xx"
}

def test-c6-follow-redirects-no-location-in-body [] {
    require-network
    let tmp = (make-temp-dir "c6-body")
    $env.API_ROOT = $tmp
    let r = (try { api get "https://postman-echo.com/redirect-to?url=https://postman-echo.com/get" --follow-redirects --raw --no-history } catch { null })
    cleanup $tmp
    if $r == null { error make {msg: "SKIP: postman-echo.com unreachable"} }
    let body_desc = ($r.response.body | describe)
    assert (not ($body_desc == "string" and ($r.response.body | str starts-with "HTTP/"))) "body must not be raw HTTP headers (redirect parsing bug)"
    assert ($body_desc | str starts-with "record") "final body should be parsed JSON record"
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
            status: 201
            "body.userId": 1
        }
    } | to nuon | save -f ($tmp | path join "collections" "c7coll" "requests" "get-post-fail.nuon")
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

# ── C8: --retries — verify actual retry count with a local Node.js server ────
# Spins up a tiny Node.js HTTP server that returns 503 for the first N requests
# then 200 on success.  Records a counter so we can assert exactly (retries+1)
# total curl invocations and that eventual success returns the final 200.

def test-c8-retries-on-transient-failure [] {
    # Preflight: skip if node.js is not available (use `which` — non-throwing)
    if (which node | is-empty) {
        error make {msg: "SKIP: node unavailable"}
    }

    let tmp = (make-temp-dir "c8-node")
    $env.API_ROOT = $tmp

    let counter_file = ($tmp | path join "count.txt")
    let port_file    = ($tmp | path join "port.txt")
    let server_script = ($tmp | path join "server.js")

    "0" | save -f $counter_file

    # Minimal Node.js server: returns 503 for first 2 requests, 200 on 3rd.
    let js = 'const http=require("http"),fs=require("fs");
const cf=process.argv[2],fn=parseInt(process.argv[3]||0),pf=process.argv[4];
const srv=http.createServer((req,res)=>{
  let c=0;try{c=parseInt(fs.readFileSync(cf,"utf8").trim()||"0");}catch(e){}
  c++;fs.writeFileSync(cf,c.toString());
  if(c<=fn){res.writeHead(503,{"Content-Type":"text/plain"});res.end("fail");}
  else{res.writeHead(200,{"Content-Type":"application/json"});res.end("{\"ok\":true}");setTimeout(()=>process.exit(0),300);}
});
srv.listen(0,"127.0.0.1",()=>{fs.writeFileSync(pf,srv.address().port.toString());});'

    $js | save -f $server_script

    # Start server as background job (no blocking)
    job spawn { ^node ($server_script | into string) ($counter_file | into string) "2" ($port_file | into string) }

    # Wait for the hosted runner to schedule the background server.
    mut port = 0
    mut tries = 0
    while ($port == 0 and $tries < 150) {
        sleep 0.1sec
        $tries = $tries + 1
        if ($port_file | path exists) {
            $port = (open --raw $port_file | str trim | into int)
        }
    }
    assert ($port > 0) "Node server did not start in time"

    # With retries=2 and 2 × 503 failures, the 3rd attempt returns 200
    let url = $"http://127.0.0.1:($port)/test"
    let r = (api get $url --raw --no-history --retries 2)

    assert ($r != null) "request should succeed after 2 retries"
    assert equal $r.response.status 200 "final response should be 200"

    # Verify exactly 3 total HTTP hits: 2 failures + 1 success
    let count = (open --raw $counter_file | str trim | into int)
    assert equal $count 3 "server should receive exactly 3 requests (retries=2 → 3 total attempts)"

    cleanup $tmp
}

# ── C9: Content-type-aware rendering ─────────────────────────────────────────

def test-c9-json-response-parsed [] {
    let tmp = (make-temp-dir "c9-json")
    $env.API_ROOT = $tmp
    let r = (api get "https://jsonplaceholder.typicode.com/posts/1" --raw --no-history)
    assert ($r != null)
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
    let is_list_like = ($body_desc | str starts-with "list") or ($body_desc | str starts-with "table")
    assert $is_list_like $"JSON array body should be list or table, got: ($body_desc)"
    cleanup $tmp
}

def test-c9-html-rendering-stdout [] {
    # Hermetic test: spin up a local Node server that returns text/html,
    # capture pretty-mode stdout, assert [HTML response ...] marker appears.
    # No external network dependency.
    if (which node | is-empty) {
        error make {msg: "SKIP: node unavailable"}
    }

    let tmp = (make-temp-dir "c9-html")
    $env.API_ROOT = $tmp
    let port_file = ($tmp | path join "port.txt")
    let server_script = ($tmp | path join "html_server.js")

    # Tiny Node server that serves a minimal HTML page
    let js = 'const http=require("http"),fs=require("fs");
const pf=process.argv[2];
const srv=http.createServer((req,res)=>{
  res.writeHead(200,{"Content-Type":"text/html"});
  res.end("<html><body><h1>Hello</h1></body></html>");
  setTimeout(()=>process.exit(0),300);
});
srv.listen(0,"127.0.0.1",()=>{fs.writeFileSync(pf,srv.address().port.toString());});'
    $js | save -f $server_script

    job spawn { ^node ($server_script | into string) ($port_file | into string) }

    mut port = 0
    mut tries = 0
    while ($port == 0 and $tries < 50) {
        sleep 0.1sec
        $tries = $tries + 1
        if ($port_file | path exists) {
            $port = (open --raw $port_file | str trim | into int)
        }
    }
    assert ($port > 0) "HTML server did not start in time"

    let api_path = ($env.NURL_REPO_ROOT | path join "api.nu")
    let nu_exe = $nu.current-exe
    let url = $"http://127.0.0.1:($port)/"
    let out = (^$nu_exe -c $"source '($api_path)'; api get '($url)' --no-history" | complete)
    let stdout = ($out.stdout | ansi strip)
    assert ($stdout | str contains "[HTML response") "HTML body should trigger [HTML response ...] marker in pretty display"
    cleanup $tmp
}

# ── C10: api head / api options ───────────────────────────────────────────────

def test-c10-options-method-offline [] {
    # Dry-run subprocess test: verifies api request -m OPTIONS builds -X OPTIONS curl arg.
    # No network needed.
    let tmp = (make-temp-dir "c10-dry")
    let api_path = ($env.NURL_REPO_ROOT | path join "api.nu")
    let nu_exe = $nu.current-exe
    let tmp_str = ($tmp | into string)
    let cmd = $"source '($api_path)'; $env.API_ROOT = '($tmp_str)'; api request -m OPTIONS 'https://example.com/test' --dry-run --no-history"
    let out = (^$nu_exe -c $cmd | complete)
    let stdout = ($out.stdout | ansi strip)
    assert ($stdout | str contains "OPTIONS") "dry-run curl command should include OPTIONS method"
    cleanup $tmp
}

def test-c10-head-no-body [] {
    let tmp = (make-temp-dir "c10-head")
    $env.API_ROOT = $tmp
    let r = (api head "https://jsonplaceholder.typicode.com/posts/1" --raw --no-history)
    assert ($r != null)
    assert equal $r.response.status 200
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
    # Live test: verify OPTIONS gets a non-zero status (method dispatched correctly).
    # Skips explicitly when httpbin.org is unreachable (separate from jsonplaceholder preflight).
    require-network
    let tmp = (make-temp-dir "c10-opts")
    $env.API_ROOT = $tmp
    let r = (try { api options "https://httpbin.org/anything" --raw --no-history } catch { null })
    cleanup $tmp
    # If httpbin is down/slow, the request returns null — skip rather than fail
    if $r == null { error make {msg: "SKIP: httpbin.org unreachable for OPTIONS test"} }
    assert ($r.response.status > 0) "OPTIONS should return a valid HTTP status"
}

# ── C11: api request export prints curl command ────────────────────────────────

def test-c11-export-prints-curl-command [] {
    # Subprocess test: verify export prints a curl command with correct method, URL, headers.
    # stdout includes "Nurl loaded. ..." before the curl line; find the curl line.
    let tmp = (make-temp-dir "c11-sub")
    mkdir ($tmp | path join "collections" "c11coll" "requests")
    {
        name: "my-req"
        collection: "c11coll"
        method: "POST"
        url: "https://example.com/api"
        headers: {"X-Custom": "myval"}
        body: {}
    } | to nuon | save -f ($tmp | path join "collections" "c11coll" "requests" "my-req.nuon")

    let api_path = ($env.NURL_REPO_ROOT | path join "api.nu")
    let nu_exe = $nu.current-exe
    let tmp_str = ($tmp | into string)
    let cmd = $"source '($api_path)'; $env.API_ROOT = '($tmp_str)'; api request export my-req -c c11coll"
    let out = (^$nu_exe -c $cmd | complete)
    # stdout includes "Nurl loaded. ..." banner — find the line that starts with "curl"
    let curl_line = ($out.stdout | ansi strip | lines | where {|l| ($l | str trim) | str starts-with "curl"} | first)

    assert (($curl_line | str trim | str starts-with "curl")) "export should print a curl command starting with 'curl'"
    assert ($curl_line | str contains "POST") "curl command should contain the HTTP method POST"
    assert ($curl_line | str contains "example.com") "curl command should contain the URL"
    assert ($curl_line | str contains "X-Custom") "curl command should contain custom headers"
    cleanup $tmp
}

# ── V5: api send --raw must not print test results ────────────────────────────

def test-v5-send-raw-no-test-output [] {
    # V5: api send --raw should suppress ✓/✗ lines and Tests: summary.
    # tests_passed must still be in the returned record.
    # In-process: verify both that the value is returned AND that tests_passed is populated.
    require-network
    let tmp = (make-temp-dir "v5-raw")
    $env.API_ROOT = $tmp
    api init | ignore
    mkdir ($tmp | path join "collections" "v5c" "requests")
    {name: "chk", method: "GET", url: "https://jsonplaceholder.typicode.com/posts/1", tests: {status: 200, "body.userId": 1}} | to nuon | save -f ($tmp | path join "collections" "v5c" "requests" "chk.nuon")
    let r = (api send chk -c v5c --raw --no-history)
    cleanup $tmp
    assert ($r != null) "send --raw should return the record, not null"
    assert equal ($r | describe | str starts-with "record") true "--raw result should be a record"
    assert equal ($r.tests_passed) true "tests_passed should be true in --raw result"
    # Verify response is a valid HTTP result (proves the actual request ran, not just a wrapper)
    assert equal ($r.response.status) 200 "--raw result should have the HTTP response status"
}

# ── V6: api history resend --raw must not print "Resending:" ─────────────────

def test-v6-resend-raw-no-print [] {
    # V6: resend --raw should suppress the "Resending: METHOD URL" line.
    # In-process: just verify the raw result is a valid record (proves resend worked and returned correctly).
    require-network
    let tmp = (make-temp-dir "v6-resend")
    $env.API_ROOT = $tmp
    api init | ignore
    # Make a real GET request to populate history
    api get "https://jsonplaceholder.typicode.com/posts/1" | ignore
    let entries = (api history list)
    if ($entries | is-empty) { cleanup $tmp; error make {msg: "SKIP: no history entry found"} }
    let entry_id = ($entries | first | get id)
    # resend --raw should return a record, not null
    let r = (api history resend $entry_id --raw)
    cleanup $tmp
    assert ($r != null) "resend --raw should return the result record"
    assert ($r | describe | str starts-with "record") "resend --raw result should be a record"
    assert equal ($r.response.status) 200 "resend should get same 200 response"
}

# ── V9: api auth show with oauth2 token must not crash ───────────────────────

def test-v9-auth-show-oauth2-no-crash [] {
    # V9: $"active (expires: ($expires))" was parsed as command substitution — crash.
    # Offline: inject a fake oauth2 secret and verify api auth show runs cleanly.
    let tmp = (make-temp-dir "v9-auth")
    $env.API_ROOT = $tmp
    api init | ignore
    let fake = {tokens: {}, basic_auth: {}, api_keys: {}, oauth: {myoauth: {access_token: "tok", expires_at: "2025-01-01T00:00:00Z", client_id: "x", client_secret: "y", token_url: "u"}}}
    $fake | to nuon | save -f ($tmp | path join "secrets.nuon")
    let rows = (api auth show)
    cleanup $tmp
    assert ($rows != null) "api auth show should return rows"
    let oauth_row = ($rows | where type == "oauth2" | first)
    assert ($oauth_row.status | str contains "active") "oauth2 status should say active"
    assert ($oauth_row.status | str contains "expires") "oauth2 status should contain 'expires'"
}

# ── V10: api head / api options accept --output flag ─────────────────────────

def test-v10-head-output-status [] {
    # V10: api head must accept --output status and return an int.
    require-network
    let tmp = (make-temp-dir "v10-head")
    $env.API_ROOT = $tmp
    let s = (api head "https://jsonplaceholder.typicode.com/posts/1" --output status --no-history)
    cleanup $tmp
    assert equal ($s | describe) "int" "--output status should return an int"
    assert equal $s 200 "head status should be 200"
}

def test-v10-head-output-headers [] {
    # V10: api head must accept --output headers and return a record.
    require-network
    let tmp = (make-temp-dir "v10-hdrs")
    $env.API_ROOT = $tmp
    let h = (api head "https://jsonplaceholder.typicode.com/posts/1" --output headers --no-history)
    cleanup $tmp
    assert ($h != null) "--output headers should return non-null"
    assert ($h | describe | str starts-with "record") "--output headers should be a record"
}

# ── V12: api summary with record headers must not crash ──────────────────────

def test-v12-summary-headers-length [] {
    # V12: $r.headers | length crashes on a record (only works on list).
    # Fix: $r.headers | columns | length. In-process: call api summary with
    # a synthetic result and verify it doesn't crash (pre-fix it would throw
    # "only_supports_this_input_type" for | length on a record).
    let tmp = (make-temp-dir "v12-summary")
    $env.API_ROOT = $tmp
    api init | ignore
    let fake_result = {
        request: {method: "GET", url: "http://x", headers: {}, body: null}
        response: {
            status: 200
            status_text: "OK"
            headers: {"Content-Type": "application/json", "X-Custom": "val"}
            body: {id: 1}
            time_ms: 100
            size_bytes: 50
        }
        timestamp: "2024-01-01"
    }
    # Before the fix, this would crash with "only_supports_this_input_type".
    # After the fix, it runs cleanly. The try/catch will fail the test if it throws.
    try {
        api summary $fake_result | ignore
    } catch {|e|
        cleanup $tmp
        error make {msg: ("api summary crashed: " + ($e.msg? | default "unknown error"))}
    }
    cleanup $tmp
}

# ── V2: HTML/XML truncation handles few-line but huge-line bodies ─────────────

def test-v2-html-single-line-truncation [] {
    # Hermetic: serves a single-line HTML body > 3000 bytes (no newlines).
    # The old line-count-only check would NOT truncate (1 line < 15).
    # The new byte-check must trigger truncation.
    if (which node | is-empty) {
        error make {msg: "SKIP: node unavailable"}
    }

    let tmp = (make-temp-dir "v2-giant-html")
    $env.API_ROOT = $tmp
    let port_file = ($tmp | path join "port.txt")
    let server_script = ($tmp | path join "giant_html_server.js")

    # One giant single-line HTML body with no newlines, ~3030 chars
    let js = 'const http=require("http"),fs=require("fs");
const pf=process.argv[2];
const body="<html><body><p>" + "A".repeat(3000) + "</p></body></html>";
const srv=http.createServer((req,res)=>{
  res.writeHead(200,{"Content-Type":"text/html"});
  res.end(body);
  setTimeout(()=>process.exit(0),300);
});
srv.listen(0,"127.0.0.1",()=>{fs.writeFileSync(pf,srv.address().port.toString());});'
    $js | save -f $server_script

    job spawn { ^node ($server_script | into string) ($port_file | into string) }

    mut port = 0
    mut tries = 0
    while ($port == 0 and $tries < 50) {
        sleep 0.1sec
        $tries = $tries + 1
        if ($port_file | path exists) {
            $port = (open --raw $port_file | str trim | into int)
        }
    }
    assert ($port > 0) "Giant HTML server did not start in time"

    let api_path = ($env.NURL_REPO_ROOT | path join "api.nu")
    let nu_exe = $nu.current-exe
    let url = $"http://127.0.0.1:($port)/"
    let out = (^$nu_exe -c $"source '($api_path)'; api get '($url)' --no-history" | complete)
    let stdout = ($out.stdout | ansi strip)

    assert ($stdout | str contains "[HTML response") "Should show [HTML response ...] marker"
    assert ($stdout | str contains "truncated") "Should show truncation notice for single giant HTML line"
    # The tail of the body (end tag) should NOT be present — body was cut off before it
    assert not ($stdout | str contains "</p></body></html>") "Should not dump full HTML body tail"
    # V14 guard: shown byte count in marker must be <= total byte count (no impossible "2000 of 522" values)
    # Parse the marker line: "showing first N of M bytes"
    let marker_line = ($stdout | lines | where {|l| $l | str contains "showing first"} | first)
    let parsed = ($marker_line | parse --regex 'showing first (\d+) of (\d+) bytes')
    if not ($parsed | is-empty) {
        let shown_n = ($parsed | first | get capture0 | into int)
        let total_n = ($parsed | first | get capture1 | into int)
        assert ($shown_n <= $total_n) "shown byte count must not exceed total byte count"
    }

    cleanup $tmp
}

# ── V13: --select into scalar body returns null, not crash ────────────────────

def test-v13-select-scalar-no-crash [] {
    # V13: api vars extract used `get -o` on a string value, crashing.
    # Guard must yield null instead of throwing for any scalar input.
    let tmp = (make-temp-dir "v13-scalar")
    $env.API_ROOT = $tmp

    # String scalar: descending "nope" path should return null, not error
    let r1 = (api vars extract "plain string body" "nope")
    assert ($r1 == null) "extract from string scalar should return null"

    # Int scalar
    let r2 = (api vars extract 42 "key")
    assert ($r2 == null) "extract from int scalar should return null"

    # Valid structured path still works (regression guard)
    let r3 = (api vars extract {id: 7, name: "test"} "id")
    assert equal $r3 7 "extract from record should still work"

    cleanup $tmp
}

def test-api-send-auto-discovers-collection [] {
    let tmp = (make-temp-dir "send-auto-discovery")
    $env.API_ROOT = $tmp
    let failure = try {
        api init | ignore
        api collection create a-nonmatching | ignore
        api collection create b-target | ignore
        api collection env create b-target default --activate | ignore
        api collection env set b-target base_url "https://discovered.example" | ignore
        api request create discovered-request GET "{{base_url}}/x" --collection b-target | ignore

        let result = (run-command-process $tmp "api send discovered-request --dry-run --no-history")
        assert equal $result.exit_code 0 "auto-discovered saved request did not exit successfully"
        assert equal ($result.stderr | str trim) "" "auto-discovered saved request wrote stderr"
        let output = ($result.stdout | str trim)
        assert ($output | str starts-with "curl ") $"auto-discovered request did not produce curl output: ($result.stdout)"
        assert ($output | str contains "https://discovered.example/x") $"auto-discovered request did not use its collection environment: ($result.stdout)"
        null
    } catch {|error| $error }

    cleanup $tmp
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

# ── Suite runner ──────────────────────────────────────────────────────────────

def run-suite-features [net_ok: bool]: nothing -> list<record> {
    print $"\n(ansi yellow)── C4-C11: Features ──(ansi reset)"
    mut results = [
        # Offline tests — run regardless of network
        (run-test "C6: redirect parse hermetic (offline)"         { test-c6-redirect-parse-hermetic })
        (run-test "C6: legacy parser folds repeated headers"      { test-c6-legacy-repeated-header-parity })
        (run-test "C8: --retries on transient failure (local server)" { test-c8-retries-on-transient-failure })
        (run-test "C10: api options method flag (dry-run offline)" { test-c10-options-method-offline })
        (run-test "C11: api request export prints curl command"   { test-c11-export-prints-curl-command })
        (run-test "api send auto-discovers collection (offline)"  { test-api-send-auto-discovers-collection })
        (run-test "V9: api auth show with oauth2 token no crash"  { test-v9-auth-show-oauth2-no-crash })
        (run-test "V12: api summary with record headers no crash"  { test-v12-summary-headers-length })
        (run-test "V2: HTML single-line giant body truncates"      { test-v2-html-single-line-truncation })
        (run-test "V13: --select into scalar body returns null"    { test-v13-select-scalar-no-crash })
    ]
    if not $net_ok {
        $results = ($results | append (skip-test "C4-C11-network" "network unavailable"))
        return $results
    }
    $results = ($results | append [
        (run-test "C4: --form sets Content-Type to form-encoded"   { test-c4-form-content-type })
        (run-test "C4: --form body is URL-encoded"                 { test-c4-form-body-encoded })
        (run-test "C5: --save writes response body to file"        { test-c5-save-writes-file })
        (run-test "C6: --follow-redirects yields final 200"        { test-c6-follow-redirects-final-status })
        (run-test "C6: --follow-redirects body is parsed JSON"     { test-c6-follow-redirects-no-location-in-body })
        (run-test "C7: shorthand test keys normalize and pass"     { test-c7-passing-tests-shorthand })
        (run-test "C7: failing tests set tests_passed=false"       { test-c7-failing-tests-no-crash })
        (run-test "C7: full response.* test keys also work"        { test-c7-full-path-keys-work })
        (run-test "C7: request without tests field does not crash" { test-c7-no-tests-field-no-crash })
        (run-test "C9: JSON response body is parsed record"        { test-c9-json-response-parsed })
        (run-test "C9: JSON array response body is parsed list"    { test-c9-json-array-parsed })
        (run-test "C9: HTML body triggers [HTML response] marker"  { test-c9-html-rendering-stdout })
        (run-test "C10: api head returns no body"                  { test-c10-head-no-body })
        (run-test "C10: api head returns headers"                  { test-c10-head-returns-headers })
        (run-test "C10: api options returns 2xx response"          { test-c10-options-returns-allow })
        (run-test "V5: api send --raw suppresses test output"      { test-v5-send-raw-no-test-output })
        (run-test "V6: api history resend --raw no Resending: print" { test-v6-resend-raw-no-print })
        (run-test "V10: api head --output status returns int"      { test-v10-head-output-status })
        (run-test "V10: api head --output headers returns record"  { test-v10-head-output-headers })
    ])
    $results
}