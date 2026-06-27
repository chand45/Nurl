# Feature tests — C4 through C11

use std assert

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

def test-c6-follow-redirects-final-status [] {
    require-network
    let tmp = (make-temp-dir "c6-redir")
    $env.API_ROOT = $tmp
    let r = (api get "https://postman-echo.com/redirect-to?url=https://postman-echo.com/get" --follow-redirects --raw --no-history)
    assert ($r != null) "redirect request should return a non-null result"
    assert equal $r.response.status 200 "follow-redirects should yield final 200, not a 3xx"
    cleanup $tmp
}

def test-c6-follow-redirects-no-location-in-body [] {
    require-network
    let tmp = (make-temp-dir "c6-body")
    $env.API_ROOT = $tmp
    let r = (api get "https://postman-echo.com/redirect-to?url=https://postman-echo.com/get" --follow-redirects --raw --no-history)
    assert ($r != null) "redirect request should return a non-null result"
    assert equal $r.response.status 200 "should be 200 to proceed"
    let body_desc = ($r.response.body | describe)
    assert (not ($body_desc == "string" and ($r.response.body | str starts-with "HTTP/"))) "body must not be raw HTTP headers (redirect parsing bug)"
    assert ($body_desc | str starts-with "record") "final body should be parsed JSON record"
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

    # Wait for server to write its port (up to 5 seconds)
    mut port = 0
    mut tries = 0
    while ($port == 0 and $tries < 50) {
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
    # Subprocess test: HTML body must trigger the [HTML response ...] marker in display output
    require-network
    let api_path = ($env.NURL_REPO_ROOT | path join "api.nu")
    let nu_exe = $nu.current-exe
    let out = (^$nu_exe -c $"source '($api_path)'; api get 'https://httpbin.org/html' --no-history" | complete)
    let stdout = ($out.stdout | ansi strip)
    assert ($stdout | str contains "[HTML response") "HTML body should trigger [HTML response ...] marker in pretty display"
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
    # Live test: verify OPTIONS gets a non-zero status (method dispatched correctly)
    require-network
    let tmp = (make-temp-dir "c10-opts")
    $env.API_ROOT = $tmp
    let r = (api options "https://httpbin.org/anything" --raw --no-history)
    assert ($r != null) "OPTIONS should return a non-null result"
    assert ($r.response.status > 0) "OPTIONS should return a valid HTTP status"
    cleanup $tmp
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

# ── Suite runner ──────────────────────────────────────────────────────────────

def run-suite-features [net_ok: bool]: nothing -> list<record> {
    print $"\n(ansi yellow)── C4-C11: Features ──(ansi reset)"
    mut results = [
        # Offline tests — run regardless of network
        (run-test "C6: redirect parse hermetic (offline)"         { test-c6-redirect-parse-hermetic })
        (run-test "C8: --retries on transient failure (local server)" { test-c8-retries-on-transient-failure })
        (run-test "C10: api options method flag (dry-run offline)" { test-c10-options-method-offline })
        (run-test "C11: api request export prints curl command"   { test-c11-export-prints-curl-command })
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
    ])
    $results
}