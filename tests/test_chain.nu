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
        let workspace_path = ($chains_dir | path join "list-workflow.nuon")
        let explicit_path = ($tmp | path join "explicit-list.nuon")
        let populated = [{request: "missing-request", use: {}}]
        $populated | to nuon | save $workspace_path
        $populated | to nuon | save $explicit_path

        let workspace_show = (api chain show list-workflow)
        assert equal ($workspace_show | length) 1 "workspace populated list-valued chain show changed"
        assert equal ($workspace_show | first | get request) "missing-request"
        let explicit_show = (api chain show $explicit_path)
        assert equal ($explicit_show | length) 1 "explicit-path populated list-valued chain show changed"
        assert equal ($explicit_show | first | get request) "missing-request"
        assert equal (api chain list | where name == list-workflow | first | get steps) 1 "chain list did not count a populated table-form chain"

        let workspace_result = (api chain exec list-workflow --quiet)
        assert equal $workspace_result.success false "workspace populated list-valued chain did not execute"
        assert ($workspace_result.error | str contains "Request not found") "workspace populated list chain returned the wrong execution result"

        let explicit_result = (api chain exec $explicit_path --quiet)
        assert equal $explicit_result.success false "explicit-path populated list-valued chain did not execute"
        assert ($explicit_result.error | str contains "Request not found") "explicit-path populated list chain returned the wrong execution result"
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
        (run-test "chain: record-or-list persisted definitions remain compatible" { test-chain-list-valued-files })
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
