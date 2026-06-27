# History index tests — B1
# Tests history index (index.nuon), ordering, search, and rebuild.
# Mostly offline once workspace is initialized; requests use network.

# ── B1: history index is maintained ──────────────────────────────────────────

def test-b1-index-created-on-save [] {
    let tmp = (make-temp-dir "b1-idx")
    $env.API_ROOT = $tmp
    init-workspace
    let _ = (api get "https://jsonplaceholder.typicode.com/posts/1" --raw)
    let index_path = ($tmp | path join "history" "index.nuon")
    assert ($index_path | path exists) "index.nuon should be created after first request"
    cleanup $tmp
}

def test-b1-index-has-entry [] {
    let tmp = (make-temp-dir "b1-entry")
    $env.API_ROOT = $tmp
    init-workspace
    let _ = (api get "https://jsonplaceholder.typicode.com/posts/1" --raw)
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
    # Make two sequential requests; second should appear first in list
    let _ = (api get "https://jsonplaceholder.typicode.com/posts/1" --raw)
    sleep 1sec
    let _ = (api get "https://jsonplaceholder.typicode.com/posts/2" --raw)
    let hist = (api history list -l 5)
    assert (($hist | length) >= 2) "should have at least 2 history entries"
    # First entry should be the NEWER one (posts/2)
    let first_url = ($hist | first | get url)
    assert ($first_url | str ends-with "/posts/2") $"Newest entry should be /posts/2, got: ($first_url)"
    cleanup $tmp
}

def test-b1-history-list-limit [] {
    let tmp = (make-temp-dir "b1-limit")
    $env.API_ROOT = $tmp
    init-workspace
    let _ = (api get "https://jsonplaceholder.typicode.com/posts/1" --raw)
    let _ = (api get "https://jsonplaceholder.typicode.com/posts/2" --raw)
    let _ = (api get "https://jsonplaceholder.typicode.com/posts/3" --raw)
    let hist = (api history list -l 2)
    assert equal ($hist | length) 2 "--limit should respect the count"
    cleanup $tmp
}

def test-b1-history-search-by-url [] {
    let tmp = (make-temp-dir "b1-search")
    $env.API_ROOT = $tmp
    init-workspace
    let _ = (api get "https://jsonplaceholder.typicode.com/posts/1" --raw)
    let _ = (api get "https://jsonplaceholder.typicode.com/users/1" --raw)
    # Search should find the /posts entry
    let results = (api history search "posts")
    assert (($results | length) > 0) "search for 'posts' should return results"
    let found = ($results | where url =~ "posts" | length)
    assert ($found > 0) "search results should include the posts URL"
    cleanup $tmp
}

def test-b1-rebuild-index [] {
    let tmp = (make-temp-dir "b1-rebuild")
    $env.API_ROOT = $tmp
    init-workspace
    let _ = (api get "https://jsonplaceholder.typicode.com/posts/1" --raw)
    let _ = (api get "https://jsonplaceholder.typicode.com/posts/2" --raw)
    # Delete the index to simulate corruption
    let index_path = ($tmp | path join "history" "index.nuon")
    rm $index_path
    assert (not ($index_path | path exists)) "index should be deleted"
    # Rebuild
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
    let _ = (api get "https://jsonplaceholder.typicode.com/posts/1" --raw)
    sleep 1sec
    let _ = (api get "https://jsonplaceholder.typicode.com/posts/2" --raw)
    # Force rebuild
    api history rebuild-index
    let hist = (api history list -l 5)
    assert (($hist | length) >= 2)
    let first_url = ($hist | first | get url)
    let msg = "After rebuild, newest should be /posts/2, got: " + $first_url
    assert ($first_url | str ends-with "/posts/2") $msg
    cleanup $tmp
}

# ── Suite runner ──────────────────────────────────────────────────────────────

def run-suite-history [net_ok: bool]: nothing -> list<record> {
    print $"\n(ansi yellow)── B1: History Index ──(ansi reset)"
    if not $net_ok {
        return [(skip-test "B1-History" "network unavailable")]
    }
    [
        (run-test "B1: index.nuon created on first save"         { test-b1-index-created-on-save })
        (run-test "B1: index entry has required fields"          { test-b1-index-has-entry })
        (run-test "B1: history list newest-first"               { test-b1-history-list-newest-first })
        (run-test "B1: history list respects --limit"           { test-b1-history-list-limit })
        (run-test "B1: history search by URL fragment"          { test-b1-history-search-by-url })
        (run-test "B1: rebuild-index recreates index.nuon"      { test-b1-rebuild-index })
        (run-test "B1: rebuilt index preserves newest-first order" { test-b1-index-sorted-after-rebuild })
    ]
}
