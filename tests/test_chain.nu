# Chain tests — chain.nu (api chain run)
# Exercises the internal --raw caller path: chain.nu calls api request --raw
# so the result is a record. These tests need network.

use test-assert.nu [assert "assert equal" "assert not"]

# ── Chain: persisted compatibility ────────────────────────────────────────────

def test-chain-list-valued-files [] {
    let tmp = (make-temp-dir "chain-list-value")
    let failure = try {
        $env.API_ROOT = $tmp
        api init | ignore
        let chains_dir = ($tmp | path join "chains")
        mkdir $chains_dir
        let homogeneous_path = ($chains_dir | path join "homogeneous.nuon")
        let heterogeneous_path = ($chains_dir | path join "heterogeneous.nuon")
        let explicit_path = ($tmp | path join "explicit-list.nuon")
        let homogeneous = [{request: "nested/missing-request", use: {}}]
        let heterogeneous = [
            {request: "nested/missing-request", use: {}}
            {request: "another/missing-request", delay_ms: 0}
        ]
        let runtime_minor = (version | get version | split row "." | get 1 | into int)
        assert ($homogeneous | describe | str starts-with "table<") "homogeneous sequence no longer exercises raw table spelling"
        if $runtime_minor < 100 {
            assert equal ($heterogeneous | describe) "list<any>" "minimum-runtime heterogeneous fixture no longer exercises raw list spelling"
        } else {
            assert ($heterogeneous | describe | str starts-with "table<") "current-runtime heterogeneous fixture no longer exercises raw table spelling"
        }
        let homogeneous_detailed = ($homogeneous | describe --detailed)
        let heterogeneous_detailed = ($heterogeneous | describe --detailed)
        let homogeneous_type = ($homogeneous_detailed | get type)
        let heterogeneous_type = ($heterogeneous_detailed | get type)
        assert equal $homogeneous_type list "homogeneous detailed type did not normalize to list"
        assert equal $heterogeneous_type list "heterogeneous detailed type did not normalize to list"
        $homogeneous | to nuon | save $homogeneous_path
        $heterogeneous | to nuon | save $heterogeneous_path
        $heterogeneous | to nuon | save $explicit_path

        let homogeneous_show = (api chain show homogeneous)
        assert equal ($homogeneous_show | length) 1 "homogeneous populated list-valued chain show changed"
        assert equal ($homogeneous_show | first | get request) "nested/missing-request"
        let heterogeneous_show = (api chain show heterogeneous)
        assert equal ($heterogeneous_show | length) 2 "heterogeneous populated list-valued chain show changed"
        let listed = (api chain list)
        assert equal ($listed | where name == homogeneous | first | get steps) 1 "chain list did not count a homogeneous table-form chain"
        assert equal ($listed | where name == heterogeneous | first | get steps) 2 "chain list did not count a heterogeneous list-form chain"

        let homogeneous_result = (api chain exec homogeneous --quiet)
        assert equal $homogeneous_result.success false "homogeneous populated list-valued chain did not execute"
        assert ($homogeneous_result.error | str contains "Request not found") "homogeneous populated list chain returned the wrong execution result"

        let heterogeneous_result = (api chain exec heterogeneous --quiet)
        assert equal $heterogeneous_result.success false "heterogeneous populated list-valued chain did not execute"
        assert equal ($heterogeneous_result.results | length) 0 "heterogeneous missing-request chain unexpectedly reached the network"
        assert ($heterogeneous_result.error | str contains "Request not found") "heterogeneous populated list chain returned the wrong execution result"

        let explicit_result = (api chain exec $explicit_path --quiet)
        assert equal $explicit_result.success false "explicit-path populated list-valued chain did not execute"
        assert equal ($explicit_result.results | length) 0 "explicit-path missing-request chain unexpectedly reached the network"
        assert ($explicit_result.error | str contains "Request not found") "explicit-path populated list chain returned the wrong execution result"

        let explicit_show = (run-command-process $tmp $"api chain show ($explicit_path | to nuon) | ignore")
        assert ($explicit_show.exit_code != 0) "explicit-path chain show became supported"
        assert equal ($explicit_show.stdout | str trim) "" "rejected explicit-path chain show wrote stdout"
        assert ($explicit_show.stderr | str contains "Invalid chain name") "explicit-path chain show rejection changed"
        null
    } catch {|error| $error}
    cleanup $tmp
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def test-chain-list-preserves-corrupt-placeholder [] {
    let tmp = (make-temp-dir "chain-list-corrupt")
    let failure = try {
        $env.API_ROOT = $tmp
        api init | ignore
        let chains_dir = ($tmp | path join "chains")
        mkdir $chains_dir
        [] | to nuon | save ($chains_dir | path join "list-form.nuon")
        "{secret: CHAIN-LIST-SENTINEL" | save ($chains_dir | path join "corrupt.nuon")
        "42" | save ($chains_dir | path join "wrong-shape.nuon")

        let result = (run-command-process $tmp "api chain list | to json --raw")
        assert equal $result.exit_code 0 $"chain list no longer tolerates one corrupt file: ($result.stderr)"
        assert equal ($result.stderr | str trim) "" "chain list wrote a corruption error"
        assert (not ($result.stdout | str contains "CHAIN-LIST-SENTINEL")) "chain list leaked corrupt content"
        let rows = ($result.stdout | from json)
        assert equal ($rows | where name == list-form | first | get steps) 0
        assert equal ($rows | where name == corrupt | first | get steps) 0
        assert equal ($rows | where name == wrong-shape | first | get steps) 0
        null
    } catch {|error| $error}
    cleanup $tmp
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

# ── Chain: sequential requests with body and extraction ───────────────────────

def test-chain-post-and-get [] {
    # Two-step chain: POST then GET
    let tmp = (make-temp-dir "chain-basic")
    $env.API_ROOT = $tmp
    let steps = [
        {
            method: "POST"
            url: "https://jsonplaceholder.typicode.com/posts"
            body: {content: {title: "chain test" userId: 1 body: "hello"}}
        }
        {
            method: "GET"
            url: "https://jsonplaceholder.typicode.com/posts/1"
        }
    ]
    let result = (api chain run $steps)
    assert ($result != null) "chain result should not be null"
    assert equal $result.success true "chain should succeed"
    assert equal ($result.results | length) 2 "chain should have 2 step results"
    cleanup $tmp
}

def test-chain-string-body-works [] {
    # Passes a pre-serialized JSON string as body (exercises --body: any)
    let tmp = (make-temp-dir "chain-strbody")
    $env.API_ROOT = $tmp
    let body_str = '{"title":"hello","userId":1,"body":"test"}'
    let steps = [
        {
            method: "POST"
            url: "https://jsonplaceholder.typicode.com/posts"
            body: {content: $body_str}
        }
    ]
    let result = (api chain run $steps)
    assert ($result != null)
    assert equal $result.success true "chain with string body should succeed"
    cleanup $tmp
}

def test-chain-extraction [] {
    # Chain with variable extraction from first response into context
    let tmp = (make-temp-dir "chain-extract")
    $env.API_ROOT = $tmp
    let steps = [
        {
            method: "GET"
            url: "https://jsonplaceholder.typicode.com/posts/1"
            extract: {post_user_id: "body.userId"}
        }
        {
            method: "GET"
            url: "https://jsonplaceholder.typicode.com/posts/2"
        }
    ]
    let result = (api chain run $steps)
    assert ($result != null)
    assert equal $result.success true "chain with extraction should succeed"
    # Context should have the extracted variable
    assert (($result.context | get post_user_id? | default null) != null) "extracted variable should be in context"
    assert equal $result.context.post_user_id 1 "extracted userId should be 1"
    cleanup $tmp
}

def test-chain-stop-on-error [] {
    # Chain that stops on the first 4xx error when --stop-on-error
    let tmp = (make-temp-dir "chain-stop")
    $env.API_ROOT = $tmp
    let steps = [
        {method: "GET" url: "https://jsonplaceholder.typicode.com/posts/99999"}  # 404
        {method: "GET" url: "https://jsonplaceholder.typicode.com/posts/1"}
    ]
    let result = (api chain run $steps --stop-on-error)
    assert ($result != null)
    assert equal $result.success false "chain should fail on 404 with --stop-on-error"
    # Step 1 causes an early return before appending to results, so results is empty
    assert equal ($result.results | length) 0 "chain should have 0 completed results (stopped on error before append)"
    cleanup $tmp
}

# ── Suite runner ──────────────────────────────────────────────────────────────

def run-suite-chain [net_ok: bool]: nothing -> list<record> {
    print $"\n(ansi yellow)── Chain: api chain run ──(ansi reset)"
    mut results = [
        (run-test "chain: list/table persisted definitions remain compatible" { test-chain-list-valued-files })
        (run-test "chain: list preserves placeholders for corrupt files" { test-chain-list-preserves-corrupt-placeholder })
    ]
    if not $net_ok {
        $results = ($results | append (skip-test "Chain network" "network unavailable"))
        return $results
    }
    $results | append [
        (run-test "chain: POST + GET succeeds end-to-end"           { test-chain-post-and-get })
        (run-test "chain: pre-serialized string body works"         { test-chain-string-body-works })
        (run-test "chain: extraction populates context"             { test-chain-extraction })
        (run-test "chain: --stop-on-error halts on 4xx"            { test-chain-stop-on-error })
    ]
}
