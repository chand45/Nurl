# Chain tests — chain.nu (api chain run)
# Exercises the internal --raw caller path: chain.nu calls api request --raw
# so the result is a record. These tests need network.

use std assert

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
    if not $net_ok {
        return [(skip-test "Chain" "network unavailable")]
    }
    [
        (run-test "chain: POST + GET succeeds end-to-end"           { test-chain-post-and-get })
        (run-test "chain: pre-serialized string body works"         { test-chain-string-body-works })
        (run-test "chain: extraction populates context"             { test-chain-extraction })
        (run-test "chain: --stop-on-error halts on 4xx"            { test-chain-stop-on-error })
    ]
}
