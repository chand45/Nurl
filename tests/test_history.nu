# History index tests -- B1
# All core tests are OFFLINE using api history save with synthetic records.
# No live network needed; append/list/search/rebuild are pure file-system operations.

# -- Synthetic record helpers ---------------------------------------------------------

# Minimal synthetic request record (no network required)
def synth-req [url: string, method: string = "GET"] {
    {method: $method, url: $url, headers: {}, body: null}
}

# Minimal synthetic response record (no network required)
def synth-res [status: int = 200] {
    {status: $status, status_text: (http-status-text $status), headers: {}, body: null, time_ms: 100, size_bytes: 50}
}

# -- B1: history index is maintained --------------------------------------------------

def test-b1-index-created-on-save [] {
    let tmp = (make-temp-dir "b1-idx")
    $env.API_ROOT = $tmp
    init-workspace
    api history save (synth-req "https://example.com/posts/1") (synth-res 200)
    let index_path = ($tmp | path join "history" "index.nuon")
    assert ($index_path | path exists) "index.nuon should be created after first save"
    cleanup $tmp
}

def test-b1-index-has-entry [] {
    let tmp = (make-temp-dir "b1-entry")
    $env.API_ROOT = $tmp
    init-workspace
    api history save (synth-req "https://example.com/posts/1") (synth-res 200)
    let index_path = ($tmp | path join "history" "index.nuon")
    let index = (open $index_path)
    assert (($index | length) > 0) "index should have at least one entry"
    let entry = ($index | first)
    assert (($entry | get id? | default null) != null) "index entry must have id"
    assert (($entry | get method? | default null) != null) "index entry must have method"
    assert (($entry | get url? | default null) != null) "index entry must have url"
    assert (($entry | get timestamp? | default null) != null) "index entry must have timestamp"
    cleanup $tmp
}

def test-b1-history-list-newest-first [] {
    let tmp = (make-temp-dir "b1-order")
    $env.API_ROOT = $tmp
    init-workspace
    api history save (synth-req "https://example.com/posts/1") (synth-res 200)
    sleep 1sec
    api history save (synth-req "https://example.com/posts/2") (synth-res 200)
    let hist = (api history list -l 5)
    assert (($hist | length) >= 2) "should have at least 2 history entries"
    let first_url = ($hist | first | get url)
    assert ($first_url | str ends-with "/posts/2") ("Newest entry should be /posts/2, got: " + $first_url)
    cleanup $tmp
}

def test-b1-history-list-limit [] {
    let tmp = (make-temp-dir "b1-limit")
    $env.API_ROOT = $tmp
    init-workspace
    api history save (synth-req "https://example.com/a") (synth-res 200)
    api history save (synth-req "https://example.com/b") (synth-res 200)
    api history save (synth-req "https://example.com/c") (synth-res 200)
    let hist = (api history list -l 2)
    assert equal ($hist | length) 2 "--limit should respect the count"
    cleanup $tmp
}

def test-b1-history-search-by-url [] {
    let tmp = (make-temp-dir "b1-search")
    $env.API_ROOT = $tmp
    init-workspace
    api history save (synth-req "https://example.com/posts/1") (synth-res 200)
    api history save (synth-req "https://example.com/users/1") (synth-res 200)
    let results = (api history search "posts")
    assert (($results | length) > 0) "search for 'posts' should return results"
    let found = ($results | where url =~ "posts" | length)
    assert ($found > 0) "search results should include the posts URL"
    let wrong = ($results | where url =~ "users" | length)
    assert equal $wrong 0 "search for 'posts' should not return 'users' entry"
    cleanup $tmp
}

def test-b1-history-method-filter-treats-token-literally [] {
    let tmp = (make-temp-dir "b1-method-token")
    $env.API_ROOT = $tmp
    init-workspace
    api history save (synth-req "https://example.com/literal" "M+SEARCH") (synth-res 200)
    api history save (synth-req "https://example.com/near-match" "MSEARCH") (synth-res 200)
    let results = (api history list --filter "method:m+search")
    assert equal ($results | length) 1 "method filter must not interpret token metacharacters as regex"
    assert equal ($results | first | get method) "M+SEARCH" "method filter should remain ASCII case-insensitive"
    cleanup $tmp
}

def test-b1-rebuild-index [] {
    let tmp = (make-temp-dir "b1-rebuild")
    $env.API_ROOT = $tmp
    init-workspace
    api history save (synth-req "https://example.com/posts/1") (synth-res 200)
    api history save (synth-req "https://example.com/posts/2") (synth-res 201)
    let index_path = ($tmp | path join "history" "index.nuon")
    rm $index_path
    assert (not ($index_path | path exists)) "index should be deleted"
    api history rebuild-index
    assert ($index_path | path exists) "rebuild should recreate index.nuon"
    let index = (open $index_path)
    assert (($index | length) >= 2) "rebuilt index should have all entries"
    cleanup $tmp
}

def test-b1-index-sorted-after-rebuild [] {
    let tmp = (make-temp-dir "b1-sorted")
    $env.API_ROOT = $tmp
    init-workspace
    api history save (synth-req "https://example.com/posts/1") (synth-res 200)
    sleep 1sec
    api history save (synth-req "https://example.com/posts/2") (synth-res 200)
    api history rebuild-index
    let hist = (api history list -l 5)
    assert (($hist | length) >= 2)
    let first_url = ($hist | first | get url)
    let msg = "After rebuild, newest should be /posts/2, got: " + $first_url
    assert ($first_url | str ends-with "/posts/2") $msg
    cleanup $tmp
}

# -- Suite runner ---------------------------------------------------------------

def run-suite-history [net_ok: bool]: nothing -> list<record> {
    print $"\n(ansi yellow)-- B1: History Index --(ansi reset)"
    # All B1 tests are offline -- they run regardless of network
    [
        (run-test "B1: index.nuon created on first save"            { test-b1-index-created-on-save })
        (run-test "B1: index entry has required fields"             { test-b1-index-has-entry })
        (run-test "B1: history list newest-first"                   { test-b1-history-list-newest-first })
        (run-test "B1: history list respects --limit"               { test-b1-history-list-limit })
        (run-test "B1: history search by URL fragment"              { test-b1-history-search-by-url })
        (run-test "B1: method token filtering is literal and case-insensitive" { test-b1-history-method-filter-treats-token-literally })
        (run-test "B1: rebuild-index recreates index.nuon"          { test-b1-rebuild-index })
        (run-test "B1: rebuilt index preserves newest-first order"  { test-b1-index-sorted-after-rebuild })
    ]
}
