# Variable interpolation tests — vars.nu
# These tests are OFFLINE: they exercise the pure interpolation/extraction
# logic without making HTTP requests.

use test-assert.nu [assert "assert equal" "assert not"]

# ── api vars interpolate ──────────────────────────────────────────────────────

def test-vars-simple-substitution [] {
    let tmp = (make-temp-dir "vars-simple")
    $env.API_ROOT = $tmp
    init-workspace
    api vars set base_url "https://api.example.com"
    let result = (api vars interpolate "{{base_url}}/users")
    assert equal $result "https://api.example.com/users"
    cleanup $tmp
}

def test-vars-multiple-vars [] {
    let tmp = (make-temp-dir "vars-multi")
    $env.API_ROOT = $tmp
    init-workspace
    api vars set host "api.example.com"
    api vars set version "v2"
    let result = (api vars interpolate "https://{{host}}/{{version}}/posts")
    assert equal $result "https://api.example.com/v2/posts"
    cleanup $tmp
}

def test-vars-no-substitution [] {
    let tmp = (make-temp-dir "vars-none")
    $env.API_ROOT = $tmp
    init-workspace
    let result = (api vars interpolate "https://example.com/static")
    assert equal $result "https://example.com/static"
    cleanup $tmp
}

def test-vars-builtin-uuid [] {
    let tmp = (make-temp-dir "vars-uuid")
    $env.API_ROOT = $tmp
    init-workspace
    let result = (api vars interpolate "id={{$uuid}}")
    # Should NOT contain the literal {{$uuid}}
    assert (not ($result | str contains "{{$uuid}}")) "uuid builtin should be substituted"
    # Should have "id=" followed by a UUID-like value
    assert ($result | str starts-with "id=")
    let id_part = ($result | str replace "id=" "")
    # UUID has dashes, 36 chars total
    assert (($id_part | str length) >= 32) "uuid should be reasonably long"
    cleanup $tmp
}

def test-vars-builtin-timestamp [] {
    let tmp = (make-temp-dir "vars-ts")
    $env.API_ROOT = $tmp
    init-workspace
    let result = (api vars interpolate "ts={{$timestamp}}")
    assert (not ($result | str contains "{{$timestamp}}")) "timestamp builtin should be substituted"
    assert ($result | str starts-with "ts=")
    let ts_part = ($result | str replace "ts=" "")
    # Should be a numeric timestamp
    assert (($ts_part | str length) > 0) "timestamp should be non-empty"
    cleanup $tmp
}

def test-vars-request-level-overrides-global [] {
    let tmp = (make-temp-dir "vars-precedence")
    $env.API_ROOT = $tmp
    init-workspace
    api vars set host "global.example.com"
    # Request-level var should override global
    let result = (api vars interpolate "https://{{host}}/api" -v {host: "request.example.com"})
    assert equal $result "https://request.example.com/api"
    cleanup $tmp
}

def test-vars-interpolate-record [] {
    let tmp = (make-temp-dir "vars-rec")
    $env.API_ROOT = $tmp
    init-workspace
    api vars set env_prefix "prod"
    let tpl = {url: "https://{{env_prefix}}.api.com" method: "GET" tag: "v{{env_prefix}}"}
    let result = (api vars interpolate-record $tpl)
    assert equal $result.url "https://prod.api.com"
    assert equal $result.tag "vprod"
    cleanup $tmp
}

# ── api vars extract ──────────────────────────────────────────────────────────

def test-vars-extract-simple-field [] {
    let data = {response: {status: 200 body: {id: 42 name: "Alice"}}}
    let v = (api vars extract $data "response.status")
    assert equal $v 200
}

def test-vars-extract-nested-field [] {
    let data = {response: {body: {user: {id: 7 email: "a@b.com"}}}}
    let v = (api vars extract $data "response.body.user.id")
    assert equal $v 7
}

def test-vars-extract-array-index [] {
    let data = {response: {body: [{id: 1} {id: 2} {id: 3}]}}
    let v = (api vars extract $data "response.body.1.id")
    assert equal $v 2
}

def test-vars-extract-heterogeneous-list [] {
    let data = [{name: "a"} {other: 1}]
    let v = (api vars extract $data "name")
    assert equal $v ["a" null]
}

def test-vars-extract-missing-returns-null [] {
    let data = {response: {body: {id: 1}}}
    let v = (api vars extract $data "response.body.nonexistent")
    assert ($v == null) "missing path should return null"
}

def test-vars-extract-shallow [] {
    let data = {foo: "bar" num: 42}
    let v = (api vars extract $data "foo")
    assert equal $v "bar"
}

# ── Suite runner ──────────────────────────────────────────────────────────────

def run-suite-vars []: nothing -> list<record> {
    print $"\n(ansi yellow)── Vars: Variable Interpolation ──(ansi reset)"
    [
        (run-test "vars: simple {{var}} substitution"                 { test-vars-simple-substitution })
        (run-test "vars: multiple {{var}} in one string"              { test-vars-multiple-vars })
        (run-test "vars: string without {{}} passes through"          { test-vars-no-substitution })
        (run-test "vars: {{$uuid}} builtin substituted"               { test-vars-builtin-uuid })
        (run-test "vars: {{$timestamp}} builtin substituted"          { test-vars-builtin-timestamp })
        (run-test "vars: request-level -v overrides global"           { test-vars-request-level-overrides-global })
        (run-test "vars: interpolate-record handles nested template"  { test-vars-interpolate-record })
        (run-test "extract: top-level field"                          { test-vars-extract-simple-field })
        (run-test "extract: deeply nested field"                      { test-vars-extract-nested-field })
        (run-test "extract: array index access"                       { test-vars-extract-array-index })
        (run-test "extract: heterogeneous list preserves missing rows" { test-vars-extract-heterogeneous-list })
        (run-test "extract: missing path returns null"                { test-vars-extract-missing-returns-null })
        (run-test "extract: shallow single key"                       { test-vars-extract-shallow })
    ]
}
