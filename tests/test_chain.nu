# Chain tests — chain.nu (api chain run)
# Exercises the internal --raw caller path: chain.nu calls api request --raw
# so the result is a record. These tests need network.

use test-assert.nu [assert "assert equal" "assert not"]

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

def setup-saved-request-chain-workspace [tmp: string] {
    $env.API_ROOT = $tmp
    api init | ignore
    for collection in ["alpha" "beta"] {
        api collection create $collection | ignore
        api collection env create $collection default --activate | ignore
        api collection env set $collection base_url "https://jsonplaceholder.typicode.com" | ignore
        api collection env set $collection resource_id 1 | ignore
    }
    api request create deploy GET "{{base_url}}/posts/{{resource_id}}" --collection alpha | ignore
    api request create deploy GET "{{base_url}}/comments/{{resource_id}}" --collection beta | ignore
    api request create alpha-only GET "{{base_url}}/posts/{{resource_id}}" --collection alpha | ignore
    api request create beta-only GET "{{base_url}}/comments/{{resource_id}}" --collection beta | ignore
}

def test-chain-saved-request-ambiguity-is-soft [] {
    let tmp = (make-temp-dir "chain-ambiguity")
    setup-saved-request-chain-workspace $tmp
    $env.API_ROOT = $tmp
    let failure = try {

        let quiet = (run-command-process $tmp "let result = (api chain run [{request: deploy}] --quiet); print ($result | to json --raw)")
        assert equal $quiet.exit_code 0 "quiet ambiguous chain should fail softly"
        assert equal ($quiet.stderr | str trim) "" "quiet ambiguous chain wrote stderr"
        let expected_error = "Request 'deploy' is ambiguous: alpha, beta. Set the step collection or use api chain run --collection."
        let quiet_result = ($quiet.stdout | from json)
        assert equal $quiet_result.error $expected_error "quiet chain returned the wrong ambiguity guidance"
        assert (not ($quiet.stdout | str contains "jsonplaceholder.typicode.com")) "quiet ambiguity leaked a candidate request URL"

        let stopped = (api chain run [{request: deploy}] --stop-on-error --quiet)
        assert equal $stopped.success false "ambiguous chain step unexpectedly succeeded"
        assert equal ($stopped.results | length) 0 "stop-on-error appended the failed ambiguity result"
        assert equal $stopped.error $expected_error "stop-on-error returned the wrong ambiguity guidance"

        let continued = (api chain run [
            {request: deploy}
            {method: "GET", url: "https://jsonplaceholder.typicode.com/posts/1"}
        ] --quiet)
        assert equal $continued.success false "continued chain lost its ambiguity failure"
        assert equal ($continued.results | length) 1 "continued chain did not execute the later inline step"
        assert equal ($continued.results | first | get status) 200 "later inline step did not complete"

        let noisy = (run-command-process $tmp "let result = (api chain run [{request: deploy}] --stop-on-error); print ($result | to json --raw)")
        assert equal $noisy.exit_code 0 "non-quiet ambiguity should retain the soft failure contract"
        assert ($noisy.stderr | str contains $expected_error) "non-quiet ambiguity omitted actionable stderr"
        null
    } catch {|error| $error }
    cleanup $tmp
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def test-chain-saved-request-collection-precedence [] {
    let tmp = (make-temp-dir "chain-collection")
    setup-saved-request-chain-workspace $tmp
    $env.API_ROOT = $tmp
    let failure = try {

        let strict_beta = (api chain run [{request: deploy}] --collection beta --quiet)
        assert equal $strict_beta.success true "strict beta request failed"
        assert equal ($strict_beta.results.0.response.body.postId) 1 "chain run -c did not select beta's request and variables"
        assert equal ($strict_beta.results.0.response.body.name | is-empty) false "beta comment response was not selected"

        let step_override = (api chain run [{request: deploy, collection: alpha}] --collection beta --quiet)
        assert equal $step_override.success true "step collection override failed"
        assert equal ($step_override.results.0.response.body.userId) 1 "step collection did not override chain run -c"

        let step_beta = (api chain run [{request: deploy, collection: beta}] --quiet)
        assert equal $step_beta.success true "unscoped per-step collection failed"
        assert equal ($step_beta.results.0.response.body.postId) 1 "per-step collection selected the wrong request"

        let strict_missing = (api chain run [{request: alpha-only}] --collection beta --quiet)
        assert equal $strict_missing.success false "chain run -c fell back to another collection"
        assert equal ($strict_missing.results | length) 0 "strict missing request appended a result"
        assert equal $strict_missing.error "Request not found: alpha-only" "strict missing request changed the soft error"

        let cross_collection = (api chain run [{request: alpha-only} {request: beta-only}] --quiet)
        assert equal $cross_collection.success true "unique unscoped cross-collection chain failed"
        assert equal ($cross_collection.results | length) 2 "unique unscoped chain did not run both collections"
        assert equal ($cross_collection.results.0.response.body.userId) 1 "alpha unique request used the wrong collection"
        assert equal ($cross_collection.results.1.response.body.postId) 1 "beta unique request used the wrong collection"

        api chain create scoped-chain | ignore
        {
            name: "scoped-chain"
            steps: [{request: deploy, collection: beta}]
        } | to nuon --indent 4 | save -f ($tmp | path join "chains" "scoped-chain.nuon")
        let named = (api chain exec scoped-chain --quiet)
        assert equal $named.success true "named chain per-step collection failed"
        assert equal ($named.results.0.response.body.postId) 1 "named chain selected the wrong collection"

        let inline = (api chain run [{
            method: "GET"
            url: "https://jsonplaceholder.typicode.com/comments/1"
            collection: alpha
        }] --quiet)
        assert equal $inline.success true "inline request was affected by its extra collection key"
        assert equal ($inline.results.0.response.body.postId) 1 "inline collection key leaked into request resolution"
        null
    } catch {|error| $error }
    cleanup $tmp
    if $failure != null {
        error make {msg: $failure.msg}
    }
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
        (run-test "chain: ambiguous saved requests fail softly"      { test-chain-saved-request-ambiguity-is-soft })
        (run-test "chain: saved request collection precedence"       { test-chain-saved-request-collection-precedence })
    ]
}
