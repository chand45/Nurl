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

def history-fixture [id: string, timestamp: any, url: string] {
    let entry = {
        id: $id
        timestamp: $timestamp
        environment: null
        request: {method: "GET", url: $url, headers: {}, body: null}
        response: {status: 200, status_text: "OK", headers: {}, body: {fixture: $id}, time_ms: 1, size_bytes: 1}
    }
    if $timestamp == null {
        $entry | reject timestamp
    } else {
        $entry
    }
}

def save-history-fixture [root: string, date_dir: string, entry: record] {
    let dir = ($root | path join "history" $date_dir)
    if not ($dir | path exists) { mkdir $dir }
    $entry | to nuon | save -f ($dir | path join $"($entry.id).nuon")
}

def history-summary [entry: record, date_dir: string] {
    {
        id: $entry.id
        timestamp: ($entry.timestamp? | default "")
        method: $entry.request.method
        url: $entry.request.url
        status: $entry.response.status
        time_ms: $entry.response.time_ms
        date_dir: $date_dir
    }
}

def create-history-directory-link [link_path: string, target_path: string] {
    if $nu.os-info.name == "windows" {
        let command = $"New-Item -ItemType Junction -Path ($link_path | to nuon) -Target ($target_path | to nuon) | Out-Null"
        (^powershell.exe -NoProfile -NonInteractive -Command $command | complete).exit_code == 0
    } else {
        (^ln -s $target_path $link_path | complete).exit_code == 0
    }
}

def create-history-file-link [
    link_path: string
    target_path: string
    force_unavailable: bool = false
] {
    if $force_unavailable {
        return {
            created: false
            unavailable: true
            detail: "forced unavailable for capability-skip regression"
        }
    }

    let result = if $nu.os-info.name == "windows" {
        ^cmd.exe /d /c mklink $link_path $target_path | complete
    } else {
        ^ln -s $target_path $link_path | complete
    }
    if $result.exit_code == 0 {
        return {created: true, unavailable: false, detail: ""}
    }

    let detail = (
        [$result.stdout $result.stderr]
        | str join "\n"
        | str trim
    )
    let capability_denied = (
        ($detail | str contains -i "sufficient privilege")
        or ($detail | str contains -i "operation not permitted")
        or ($detail | str contains -i "not supported")
        or ($detail | str contains -i "function not implemented")
        or ($detail | str contains -i "read-only file system")
    )
    if $capability_denied {
        return {created: false, unavailable: true, detail: $detail}
    }

    error make {
        msg: $"History file-link fixture creation failed: ($detail | default 'unknown link command failure')"
    }
}

def remove-history-file-link [link_path: string] {
    if $nu.os-info.name == "windows" {
        ^cmd.exe /d /c del $link_path | complete
    } else {
        ^rm -f $link_path | complete
    }
}

def cleanup-history-alias-fixture [root: string, alias_path: string, alias_created: bool] {
    if $alias_created {
        remove-history-file-link $alias_path | ignore
    }
    cleanup $root
    if ($root | path exists) {
        error make {msg: $"History alias fixture cleanup left '($root)'"}
    }
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
    let first_id = (api history save (synth-req "https://example.com/posts/1") (synth-res 200))
    let second_id = (api history save (synth-req "https://example.com/posts/2") (synth-res 200))
    let hist = (api history list -l 5)
    assert (($hist | length) >= 2) "should have at least 2 history entries"
    assert equal ($hist | get id | first) $second_id "newest entry should be the final persisted ID"
    assert equal ($hist | get id | last) $first_id "oldest entry should be the first persisted ID"
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
    let first_id = (api history save (synth-req "https://example.com/posts/1") (synth-res 200))
    let second_id = (api history save (synth-req "https://example.com/posts/2") (synth-res 200))
    api history rebuild-index
    let hist = (api history list -l 5)
    assert (($hist | length) >= 2)
    assert equal ($hist | get id) [$second_id $first_id] "rebuild should preserve persistence order"
    cleanup $tmp
}

def test-b1-burst-order-is-deterministic [] {
    let tmp = (make-temp-dir "b1-burst")
    $env.API_ROOT = $tmp
    init-workspace
    let config_path = ($tmp | path join "config.nuon")
    open $config_path | upsert default_environment "burst-env" | to nuon | save -f $config_path

    let ids = 1..10 | each {|n|
        let response = (
            synth-res 200
            | upsert body {search_marker: "burst-body-fragment", sequence: $n}
        )
        api history save (synth-req $"https://example.com/request-($n)") $response
    }
    let expected = ($ids | reverse)
    let entries = $ids | each {|id| api history get $id }
    let instants = $entries | each {|entry| $entry.timestamp | into datetime | into int }
    let index_path = ($tmp | path join "history" "index.nuon")
    let index_before = (open $index_path --raw)

    assert equal ($instants | uniq | length) 10 "burst timestamps must be unique"
    assert equal $instants ($instants | sort) "burst timestamps must increase with persistence order"
    assert ($entries | all {|entry| $entry.timestamp =~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{9}Z$' }) "new timestamps must be nanosecond RFC3339 UTC"
    assert ($entries | all {|entry| $entry.environment == "burst-env" }) "isolated default environment was not captured"

    for entry in $entries {
        let instant = ($entry.timestamp | into datetime | date to-timezone UTC)
        let expected_date = ($instant | format date "%Y-%m-%d")
        let expected_id_prefix = ($instant | format date "%Y%m%d-%H%M%S")
        assert ($entry.id | str starts-with $expected_id_prefix) "ID time component did not use the persisted instant"
        assert (($tmp | path join "history" $expected_date $"($entry.id).nuon") | path exists) "date directory did not use the persisted instant"
    }

    assert equal (api history list --limit 1 | get id | first) ($ids | last) "--limit 1 did not select the final persisted entry"
    assert equal (api history list --limit 10 | get id) $expected "list order differs from reverse insertion order"
    assert equal (api history list --limit 1000 | get id) $expected "overlarge list limit did not return all entries"
    assert equal (api history list --limit 0 | length) 0 "zero list limit must select no entries"
    let search_results = (api history search "request-" --limit 10)
    assert equal ($search_results | get id) $expected "search order differs from list order"
    assert ($search_results | all {|entry| $entry.timestamp =~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$' }) "search timestamps must remain well-formed RFC3339"
    assert equal (api history search "request-" --limit 1 | get id | first) ($ids | last) "search --limit 1 did not select the final entry"
    assert equal (api history search "request-" --limit 1000 | get id) $expected "overlarge search limit did not return all entries"
    assert equal (api history search "request-" --limit 0 | length) 0 "zero search limit must select no entries"
    assert equal (api history search "burst-body-fragment" --limit 10 | get id) $expected "body search order differs from list order"
    assert equal (open $index_path | get id) $expected "index order differs from list order"
    assert equal (open $index_path --raw) $index_before "list/search unexpectedly rewrote the index"

    rm $index_path
    assert (not ($index_path | path exists)) "burst rebuild test did not remove the index"
    api history rebuild-index | ignore
    assert equal (api history list --limit 10 | get id) $expected "rebuild changed burst list order"
    assert equal (api history search "request-" --limit 10 | get id) $expected "rebuild changed burst search order"
    assert equal (api history search "burst-body-fragment" --limit 10 | get id) $expected "rebuild changed body-search order"
    cleanup $tmp
}

def test-b1-clock-collision-boundary-consistency [] {
    let tmp = (make-temp-dir "b1-boundary")
    $env.API_ROOT = $tmp
    init-workspace
    let existing = (history-fixture "20991231-235959-existing" "2099-12-31T23:59:59.999999999Z" "https://example.com/boundary-existing")
    save-history-fixture $tmp "2099-12-31" $existing
    api history rebuild-index | ignore

    let id = (api history save (synth-req "https://example.com/boundary-new") (synth-res 200))
    let entry = (api history get $id)
    assert equal $entry.timestamp "2100-01-01T00:00:00.000000000Z" "colliding/backward clock did not advance by one nanosecond"
    assert ($id | str starts-with "21000101-000000-") "boundary ID did not use the advanced persistence instant"
    assert (($tmp | path join "history" "2100-01-01" $"($id).nuon") | path exists) "boundary entry used an inconsistent date directory"
    assert equal (api history list --limit 1 | get id | first) $id "boundary entry was not newest"
    cleanup $tmp
}

def test-b1-mixed-and-malformed-timestamps [] {
    let tmp = (make-temp-dir "b1-mixed")
    $env.API_ROOT = $tmp
    init-workspace
    let date_dir = "2026-01-01"
    let fixtures = [
        (history-fixture "fractional-newest" "2026-01-01T00:00:01.100000000Z" "https://example.com/mixed/fractional-newest")
        (history-fixture "legacy-newest" "2026-01-01T00:00:01Z" "https://example.com/mixed/legacy-newest")
        (history-fixture "fractional-older" "2026-01-01T00:00:00.900000000Z" "https://example.com/mixed/fractional-older")
        (history-fixture "tied-z" "2026-01-01T00:00:00Z" "https://example.com/mixed/tied-z")
        (history-fixture "tied-a" "2026-01-01T00:00:00Z" "https://example.com/mixed/tied-a")
        (history-fixture "date-only-z" "2026-01-01" "https://example.com/mixed/date-only-z")
        (history-fixture "invalid-z" "not-a-timestamp" "https://example.com/mixed/invalid-z")
        (history-fixture "invalid-a" null "https://example.com/mixed/invalid-a")
    ]
    for entry in $fixtures { save-history-fixture $tmp $date_dir $entry }

    let preferred = ["fractional-newest" "legacy-newest" "fractional-older" "tied-z" "tied-a" "date-only-z" "invalid-z" "invalid-a"]
    ($preferred | append "tied-z")
    | each {|id| history-summary ($fixtures | where id == $id | first) $date_dir }
    | append {
        id: "stale-index-only"
        timestamp: "2026-01-01T00:00:02Z"
        method: "GET"
        url: "https://example.com/mixed/stale"
        status: 200
        time_ms: 1
        date_dir: $date_dir
    }
    | to nuon
    | save -f ($tmp | path join "history" "index.nuon")

    api history rebuild-index | ignore
    assert equal (api history list --limit 20 | get id) $preferred "rebuild did not preserve existing order for tied timestamps"
    assert equal (api history search "mixed" --limit 20 | get id) $preferred "mixed timestamp search order differed from list"
    assert equal (open ($tmp | path join "history" "index.nuon") | get id) $preferred "rebuild retained stale or duplicate index hints"
    assert equal (api history show "invalid-z").id "invalid-z" "malformed timestamp entry was not readable"
    assert equal (api history get "invalid-a").id "invalid-a" "missing timestamp entry was not readable"
    assert equal (api history list --limit 20 | where id == "invalid-a" | first | get timestamp) "" "missing timestamp did not render safely"

    let index_path = ($tmp | path join "history" "index.nuon")
    rm $index_path
    api history rebuild-index | ignore
    let fallback = ["fractional-newest" "legacy-newest" "fractional-older" "tied-a" "tied-z" "date-only-z" "invalid-a" "invalid-z"]
    assert equal (api history list --limit 20 | get id) $fallback "index-free rebuild fallback was not deterministic"
    assert equal (api history search "mixed" --limit 20 | get id) $fallback "fallback search order differed from list"
    cleanup $tmp
}

def test-b1-history-id-resolution [] {
    let tmp = (make-temp-dir "b1-resolution")
    $env.API_ROOT = $tmp
    init-workspace
    let fixtures = [
        (history-fixture "shared" "2026-01-01T00:00:03Z" "https://example.com/exact")
        (history-fixture "prefix-shared-suffix" "2026-01-01T00:00:02Z" "https://example.com/partial")
        (history-fixture "prefix-unique-target-suffix" "2026-01-01T00:00:01Z" "https://example.com/unique")
        (history-fixture "history-shared-one" "2026-01-01T00:00:00Z" "https://example.com/ambiguous-one")
        (history-fixture "history-shared-two" "2026-01-01T00:00:00Z" "https://example.com/ambiguous-two")
    ]
    for entry in $fixtures { save-history-fixture $tmp "2026-01-01" $entry }

    assert equal (api history get "shared").id "shared" "exact ID did not win over partial matches"
    assert equal (api history show "prefix-unique").id "prefix-unique-target-suffix" "unique prefix lookup changed"
    assert equal (api history get "unique-target").id "prefix-unique-target-suffix" "unique middle lookup changed"
    assert equal (api history show "target-suffix").id "prefix-unique-target-suffix" "unique suffix lookup changed"

    let ambiguity = try {
        api history get "history-shared" | ignore
        null
    } catch {|error| $error.msg }
    assert ($ambiguity | str contains "is ambiguous (2 matches); use a longer or exact ID") "internal get did not reject ambiguity actionably"
    cleanup $tmp
}

def test-b1-index-order-equivalence [] {
    let tmp = (make-temp-dir "b1-order-equivalence")
    $env.API_ROOT = $tmp
    init-workspace
    let date_dir = "2026-01-01"
    let fixtures = [
        (history-fixture "order-newest" "2026-01-01T00:00:03.000000003Z" "https://example.com/order/newest")
        (history-fixture "order-middle" "2026-01-01T02:00:02+02:00" "https://example.com/order/middle")
        (history-fixture "order-oldest" "2026-01-01T00:00:01Z" "https://example.com/order/oldest")
    ]
    for entry in $fixtures { save-history-fixture $tmp $date_dir $entry }
    let summaries = ($fixtures | each {|entry| history-summary $entry $date_dir })
    let expected = ($fixtures | get id)
    let index_path = ($tmp | path join "history" "index.nuon")

    for variant in [
        {name: "canonical", entries: $summaries}
        {name: "reverse", entries: ($summaries | reverse)}
        {name: "shuffled", entries: [($summaries | get 1) ($summaries | get 2) ($summaries | get 0)]}
    ] {
        $variant.entries | to nuon | save -f $index_path
        let before = (open $index_path --raw)
        assert equal (api history list --limit 20 | get id) $expected $"($variant.name) list order changed"
        assert equal (api history search "order/" --limit 20 | get id) $expected $"($variant.name) search order changed"

        let json_export = (run-command-process $tmp "api history export --format json --limit 20")
        let csv_export = (run-command-process $tmp "api history export --format csv --limit 20")
        assert equal $json_export.exit_code 0 $"($variant.name) JSON export failed"
        assert equal $csv_export.exit_code 0 $"($variant.name) CSV export failed"
        assert equal ($json_export.stdout | from json | get id) $expected $"($variant.name) JSON export order changed"
        assert equal ($csv_export.stdout | from csv | get id) $expected $"($variant.name) CSV export order changed"
        assert equal (open $index_path --raw) $before $"($variant.name) read surfaces rewrote index bytes"
    }
    cleanup $tmp
}

def test-b1-legacy-ordering-equivalence [] {
    let tmp = (make-temp-dir "b1-legacy-ordering")
    $env.API_ROOT = $tmp
    init-workspace
    let date_dir = "2026-01-01"
    mut fixtures = [
        (history-fixture "fractional-newest" "2026-01-01T00:00:01.100000000Z" "https://example.com/legacy/fractional")
        (history-fixture "legacy-second-only" "2026-01-01T00:00:01Z" "https://example.com/legacy/second")
        (history-fixture "offset-entry" "2026-01-01T02:00:00+02:00" "https://example.com/legacy/offset")
        (history-fixture "tied-entry" "2026-01-01T00:00:00Z" "https://example.com/legacy/tied")
        (history-fixture "date-only" "2026-01-01" "https://example.com/legacy/date")
        (history-fixture "malformed" "not-a-timestamp" "https://example.com/legacy/malformed")
        (history-fixture "missing-timestamp" null "https://example.com/legacy/missing")
        (history-fixture "leap-second" "2026-06-30T23:59:60Z" "https://example.com/legacy/leap")
    ]
    let runtime_minor = (version | get version | split row "." | get 1 | into int)
    if $runtime_minor != 89 {
        $fixtures = ($fixtures | append (
            history-fixture "out-of-range" "2026-13-45T00:00:00Z" "https://example.com/legacy/range"
        ))
    }
    for entry in $fixtures { save-history-fixture $tmp $date_dir $entry }
    let expected = if $runtime_minor == 89 {
        ["leap-second"] | append ($fixtures | where id != "leap-second" | get id)
    } else {
        $fixtures | get id
    }
    let index_path = ($tmp | path join "history" "index.nuon")
    ($fixtures | each {|entry| history-summary $entry $date_dir }) | to nuon | save -f $index_path

    assert equal (api history list --limit 20 | get id) $expected "legacy fallback order changed"
    assert equal (api history search "legacy/" --limit 20 | get id) $expected "legacy fallback search order changed"
    api history rebuild-index | ignore
    assert equal (api history list --limit 20 | get id) $expected "rebuild changed legacy fallback order"
    cleanup $tmp
}

def test-b1-unusable-index-equivalence [] {
    let tmp = (make-temp-dir "b1-unusable-index")
    $env.API_ROOT = $tmp
    init-workspace
    let newer = (history-fixture "unusable-newer" "2026-01-02T00:00:02Z" "https://example.com/unusable/newer")
    let older = (history-fixture "unusable-older" "2026-01-01T00:00:01Z" "https://example.com/unusable/older")
    save-history-fixture $tmp "2026-01-02" $newer
    save-history-fixture $tmp "2026-01-01" $older
    let index_path = ($tmp | path join "history" "index.nuon")
    let expected = [$newer.id $older.id]

    for state in [
        {name: "absent", raw: null}
        {name: "corrupt", raw: "[{id:"}
        {name: "wrong-shape", raw: "{not: 'a list'}"}
        {name: "empty-id", raw: "[{id: '', date_dir: '2026-01-01'}]"}
        {name: "missing-column", raw: "[{id: 'missing-date-dir'}]"}
    ] {
        if ($index_path | path exists) { rm $index_path }
        if $state.raw != null { $state.raw | save -f $index_path }
        assert equal (api history list --limit 20 | get id) $expected $"($state.name) index did not rebuild equivalently"
        assert equal (open $index_path | get id) $expected $"($state.name) rebuilt index bytes were not canonical"
    }
    cleanup $tmp
}

def test-b1-resolution-workspace-equivalence [] {
    let tmp = (make-temp-dir "b1-resolution-workspace")
    $env.API_ROOT = $tmp
    init-workspace
    let fixtures = [
        {date_dir: "2026-01-01", entry: (history-fixture "duplicate-id" "2026-01-01T00:00:01Z" "https://example.com/duplicate/one")}
        {date_dir: "2026-01-02", entry: (history-fixture "duplicate-id" "2026-01-02T00:00:01Z" "https://example.com/duplicate/two")}
        {date_dir: "2026-01-02", entry: (history-fixture "only-on-disk" "2026-01-02T00:00:02Z" "https://example.com/unindexed")}
        {date_dir: "2026-01-02", entry: (history-fixture "CaseSensitive" "2026-01-02T00:00:03Z" "https://example.com/case")}
        {date_dir: "2026-01-02", entry: (history-fixture "exact" "2026-01-02T00:00:04Z" "https://example.com/exact")}
        {date_dir: "2026-01-02", entry: (history-fixture "prefix-exact-suffix" "2026-01-02T00:00:05Z" "https://example.com/partial")}
    ]
    for fixture in $fixtures {
        save-history-fixture $tmp $fixture.date_dir $fixture.entry
    }
    let index_path = ($tmp | path join "history" "index.nuon")
    [
        (history-summary ($fixtures | get 0 | get entry) "2026-01-01")
        {id: "stale-row", timestamp: "2026-01-03T00:00:00Z", method: "GET", url: "https://example.com/stale", status: 200, time_ms: 1, date_dir: "2026-01-03"}
    ] | to nuon | save -f $index_path
    let before = (open $index_path --raw)

    assert equal (api history get "exact" | get id) "exact" "exact ID did not win over a containing fragment"
    assert equal (api history show "only-on" | get id) "only-on-disk" "file absent from the index was not resolved"
    assert equal (api history get "stale-row") null "stale index row resolved without an entry file"
    assert equal (api history get "casesensitive") null "wrong-case ID unexpectedly resolved"
    let ambiguity = try {
        api history get "duplicate-id" | ignore
        null
    } catch {|error| $error.msg }
    assert ($ambiguity | str contains "is ambiguous (2 matches); use a longer or exact ID") "duplicate exact IDs did not preserve ambiguity"
    assert equal (open $index_path --raw) $before "ID resolution mutated index bytes"

    rm $index_path
    assert equal (api history get "only-on-disk" | get id) "only-on-disk" "index-free resolution changed"
    cleanup $tmp
}

def test-b1-monotonic-unsorted-index [] {
    let tmp = (make-temp-dir "b1-monotonic-unsorted")
    $env.API_ROOT = $tmp
    init-workspace
    let old = (history-fixture "old-entry" "2026-01-01T00:00:01Z" "https://example.com/old")
    let malformed = (history-fixture "malformed-entry" "not-a-timestamp" "https://example.com/malformed")
    let future = (history-fixture "future-entry" "2099-12-31T23:59:59.999999999Z" "https://example.com/future")
    save-history-fixture $tmp "2026-01-01" $old
    save-history-fixture $tmp "2026-01-01" $malformed
    save-history-fixture $tmp "2099-12-31" $future
    let index_path = ($tmp | path join "history" "index.nuon")
    [
        (history-summary $old "2026-01-01")
        (history-summary $malformed "2026-01-01")
        (history-summary $future "2099-12-31")
    ] | to nuon | save -f $index_path

    let ids = 1..3 | each {|n|
        api history save (synth-req $"https://example.com/monotonic/($n)") (synth-res 200)
    }
    let instants = $ids | each {|id| api history get $id | get timestamp | into datetime | into int }
    let future_ns = ($future.timestamp | into datetime | into int)
    assert equal ($instants | uniq | length) 3 "unsorted-index burst timestamps were not unique"
    assert equal $instants ($instants | sort) "unsorted-index burst was not strictly increasing"
    assert (($instants | math min) > $future_ns) "save did not advance past every comparable index entry"
    cleanup $tmp
}

def test-b1-save-loads-index-once [] {
    let source = (open ($env.NURL_REPO_ROOT | path join "nu_modules" "history.nu") --raw)
    let save_source = (
        $source
        | split row 'export def "api history save"'
        | get 1
        | split row '# List history entries'
        | first
    )
    let load_count = (($save_source | split row "load-history-index-entries" | length) - 1)
    assert equal $load_count 1 "api history save must load the index exactly once"
    assert (not ($save_source | str contains "ensure-history-index")) "api history save retained the old ensure read"
    assert (not ($save_source | str contains "(load-history-index)")) "api history save retained a direct index read"
}

def test-b1-history-lock-path-compatibility [] {
    let tmp = (make-temp-dir "b1-lock-path")
    let root = ($tmp | path join "literal%PATH%segment")
    mkdir $root
    $env.API_ROOT = $root

    assert equal (api history rebuild-index | length) 0 "index-free rebuild changed its result"
    assert (not (($root | path join ".history-index.lock") | path exists)) "index-free rebuild left the history lock behind"

    init-workspace
    let id = (api history save (synth-req "https://example.com/lock-path") (synth-res 200))
    assert equal (api history get $id | get id) $id "history lock changed a percent-bearing API_ROOT"
    assert (not (($root | path join ".history-index.lock") | path exists)) "save left the history lock behind"
    cleanup $tmp
}

def test-b1-concurrent-saves-preserve-index [] {
    let tmp = (make-temp-dir "b1-concurrent-saves")
    $env.API_ROOT = $tmp
    init-workspace
    let count = 12
    let response = (synth-res 200)
    let outcomes = 1..$count | par-each {|n|
        let request = (synth-req $"https://example.com/concurrent/($n)")
        run-command-process $tmp $"api history save ($request | to nuon) ($response | to nuon)"
    }
    let failed = ($outcomes | where exit_code != 0)
    assert ($failed | is-empty) $"a concurrent history save failed: ($failed | select exit_code stderr | to nuon)"

    let index = (open ($tmp | path join "history" "index.nuon"))
    let files = (
        ls ($tmp | path join "history")
        | where type == "dir"
        | each {|subdir| ls $subdir.name | where type == "file" and name =~ '\.nuon$' }
        | flatten
    )
    assert equal ($index | length) $count "concurrent saves dropped index rows"
    assert equal ($index | get id | uniq | length) $count "concurrent saves produced duplicate index IDs"
    assert equal ($files | length) $count "concurrent saves dropped entry files"
    assert (not (($tmp | path join ".history-index.lock") | path exists)) "concurrent saves left the index lock behind"
    assert (
        ls -a $tmp
        | where {|entry| ($entry.name | path basename) | str starts-with ".history-index.lock.release-" }
        | is-empty
    ) "concurrent saves left a released lock directory behind"
    cleanup $tmp
}

def test-b1-api-root-environment-scoping [] {
    let first_root = (make-temp-dir "b1-root-first")
    let second_root = (make-temp-dir "b1-root-second")

    $env.API_ROOT = $first_root
    init-workspace
    let first_config = ($first_root | path join "config.nuon")
    open $first_config | upsert default_environment "first-env" | to nuon | save -f $first_config
    let first_id = (api history save (synth-req "https://example.com/first-root") (synth-res 200))
    let first_index_before = (open ($first_root | path join "history" "index.nuon") --raw)

    $env.API_ROOT = $second_root
    init-workspace
    let second_config = ($second_root | path join "config.nuon")
    open $second_config | upsert default_environment "second-env" | to nuon | save -f $second_config
    let second_id = (api history save (synth-req "https://example.com/second-root") (synth-res 200))
    assert equal (api history get $second_id | get environment) "second-env"
    assert equal (api history get $first_id) null "second API_ROOT exposed first-root history"
    assert equal (open ($second_root | path join "history" "index.nuon") | get id) [$second_id]

    $env.API_ROOT = $first_root
    assert equal (api history get $first_id | get environment) "first-env"
    assert equal (api history get $second_id) null "first API_ROOT exposed second-root history"
    assert equal (open ($first_root | path join "history" "index.nuon") --raw) $first_index_before "second-root save mutated first-root history"
    cleanup $first_root
    cleanup $second_root
}

def clear-fixture [id: string, date: string, group: string] {
    {
        id: $id
        timestamp: $"($date)T00:00:00Z"
        environment: null
        request: {
            method: "GET"
            url: $"https://example.com/clear-index-consistency/($group)/($id)"
            headers: {}
            body: null
        }
        response: {
            status: 200
            status_text: "OK"
            headers: {}
            body: {marker: "clear-body-consistency", group: $group, id: $id}
            time_ms: 1
            size_bytes: 1
        }
    }
}

def assert-clear-surfaces [root: string, expected_ids: list, removed_ids: list, label: string] {
    let index_path = ($root | path join "history" "index.nuon")
    assert ($index_path | path exists) $"($label): index.nuon is missing"
    let index_ids = (open $index_path | get id)
    assert equal $index_ids $expected_ids $"($label): expected index IDs ($expected_ids | to nuon), got ($index_ids | to nuon)"
    assert equal (api history list --limit 100 | get id) $expected_ids $"($label): list IDs differ from index"
    assert equal (api history search "clear-index-consistency" --limit 100 | get id) $expected_ids $"($label): URL search IDs differ from index"
    assert equal (api history search "clear-body-consistency" --limit 100 | get id) $expected_ids $"($label): body search IDs differ from entry files"

    for id in $expected_ids {
        assert equal (api history get $id | get id) $id $"($label): retained ID '($id)' is unreadable"
    }
    for id in $removed_ids {
        assert equal (api history get $id) null $"($label): removed ID '($id)' remains readable"
    }

    for format in ["json" "csv"] {
        let result = (run-command-process $root $"api history export --format ($format) --limit 100")
        assert equal $result.exit_code 0 $"($label): ($format) export failed"
        assert equal ($result.stderr | str trim) "" $"($label): ($format) export wrote stderr"
        assert equal $result.stdout ($result.stdout | ansi strip) $"($label): ($format) export contained ANSI"
        if $format == "csv" {
            assert equal ($result.stdout | lines | first) "id,timestamp,method,url,status,time_ms" $"($label): CSV header changed"
        }
        let rows = if $format == "json" {
            $result.stdout | from json
        } else {
            $result.stdout | from csv
        }
        assert equal ($rows | get id) $expected_ids $"($label): ($format) export IDs are inconsistent"
    }
}

def assert-valid-history-index [root: string, expected_ids: list, label: string] {
    let index_path = ($root | path join "history" "index.nuon")
    let index = (open $index_path)
    let index_type = ($index | describe)
    assert (($index_type | str starts-with "list") or ($index_type | str starts-with "table")) $"($label): index top-level shape is invalid"
    assert ($index | all {|entry| ($entry | describe) | str starts-with "record" }) $"($label): index contains a non-record row"
    assert equal ($index | get id) $expected_ids $"($label): index IDs are not canonical"
    if not ($index | is-empty) {
        assert equal (
            $index | first | columns
        ) ["id" "timestamp" "method" "url" "status" "time_ms" "date_dir"] $"($label): index summary schema changed"
    }
}

def prepare-clear-fixtures [
    root: string
    group: string
    removed_date: string
    retained_older_date: string
    retained_newer_date: string
] {
    let removed = (clear-fixture $"($group)-removed" $removed_date $group)
    let retained_older = (clear-fixture $"($group)-retained-older" $retained_older_date $group)
    let retained_newer = (clear-fixture $"($group)-retained-newer" $retained_newer_date $group)
    save-history-fixture $root $removed_date $removed
    save-history-fixture $root $retained_older_date $retained_older
    save-history-fixture $root $retained_newer_date $retained_newer
    api history rebuild-index | ignore

    let index_path = ($root | path join "history" "index.nuon")
    assert ($index_path | path exists) $"($group): setup did not create index.nuon"
    assert equal (open $index_path | get id) [$retained_newer.id $retained_older.id $removed.id] $"($group): indexed setup order changed"
    {removed: $removed, retained_older: $retained_older, retained_newer: $retained_newer}
}

def test-b1-invalid-index-shapes-recover [] {
    let tmp = (make-temp-dir "b1-index-shapes")
    $env.API_ROOT = $tmp
    init-workspace
    let fixtures = (prepare-clear-fixtures $tmp "shape" "2000-01-01" "2000-01-02" "2000-01-03")
    let expected = [$fixtures.retained_newer.id $fixtures.retained_older.id $fixtures.removed.id]
    let index_path = ($tmp | path join "history" "index.nuon")

    for invalid in ["{}" "\"scalar-index\"" "[1 \"invalid-row\"]"] {
        $invalid | save -f $index_path
        let result = (run-command-process $tmp "api history rebuild-index | ignore")
        assert equal $result.exit_code 0 $"explicit rebuild failed for index shape ($invalid)"
        assert equal ($result.stderr | str trim) "" $"explicit rebuild wrote stderr for index shape ($invalid)"
        assert ($result.stdout | str contains "Index rebuilt: 3 entries") $"explicit rebuild output changed for index shape ($invalid)"
        assert-valid-history-index $tmp $expected $"explicit rebuild ($invalid)"
    }

    "{}" | save -f $index_path
    assert equal (api history list --limit 100 | get id) $expected "automatic ensure did not rebuild a record-shaped index"
    assert-clear-surfaces $tmp $expected [] "automatic shape recovery"

    "[1]" | save -f $index_path
    let saved_id = (api history save (synth-req "https://example.com/shape/save") (synth-res 200))
    assert-valid-history-index $tmp ([$saved_id] | append $expected) "save after invalid index"
    cleanup $tmp
}

def test-b1-clear-before-keeps-index-consistent [] {
    let tmp = (make-temp-dir "b1-clear-before")
    $env.API_ROOT = $tmp
    init-workspace
    let fixtures = (prepare-clear-fixtures $tmp "before" "2000-01-01" "2000-01-02" "2000-01-03")
    let index_path = ($tmp | path join "history" "index.nuon")
    "{}" | save -f $index_path

    let result = (run-command-process $tmp "api history clear --before 2000-01-02 --force")
    assert equal $result.exit_code 0 $"--before clear failed: ($result.stderr)"
    assert equal ($result.stderr | str trim) "" "--before clear wrote stderr"
    assert ($result.stdout | str contains "Cleared 1 days of history before 2000-01-02") "--before clear output changed"
    assert (not (($tmp | path join "history" "2000-01-01") | path exists)) "--before retained the removed directory"
    assert (($tmp | path join "history" "2000-01-02" $"($fixtures.retained_older.id).nuon") | path exists) "--before removed the older retained entry file"
    assert (($tmp | path join "history" "2000-01-03" $"($fixtures.retained_newer.id).nuon") | path exists) "--before removed the newer retained entry file"
    let retained_ids = [$fixtures.retained_newer.id $fixtures.retained_older.id]
    assert-clear-surfaces $tmp $retained_ids [$fixtures.removed.id] "--before"

    let empty_result = (run-command-process $tmp "api history clear --before 2000-01-04 --force")
    assert equal $empty_result.exit_code 0 "--before clear to empty failed"
    assert equal ($empty_result.stderr | str trim) "" "--before clear to empty wrote stderr"
    assert-valid-history-index $tmp [] "--before clear to empty"
    assert equal (api history list --limit 100 | length) 0 "--before clear to empty left list rows"
    assert equal (api history search "clear-index-consistency" --limit 100 | length) 0 "--before clear to empty left URL-search rows"
    assert equal (api history search "clear-body-consistency" --limit 100 | length) 0 "--before clear to empty left body-search rows"
    assert equal (api history get $fixtures.retained_newer.id) null "--before clear to empty retained an entry"
    let json_empty = (run-command-process $tmp "api history export --format json --limit 100")
    let csv_empty = (run-command-process $tmp "api history export --format csv --limit 100")
    assert equal $json_empty.exit_code 0 "--before clear to empty JSON export failed"
    assert equal $csv_empty.exit_code 0 "--before clear to empty CSV export failed"
    assert equal ($json_empty.stderr | str trim) "" "--before clear to empty JSON export wrote stderr"
    assert equal ($csv_empty.stderr | str trim) "" "--before clear to empty CSV export wrote stderr"
    assert equal ($json_empty.stdout | from json | length) 0 "--before clear to empty left JSON rows"
    assert equal ($csv_empty.stdout | lines | first) "id,timestamp,method,url,status,time_ms" "--before clear to empty CSV header changed"
    assert equal ($csv_empty.stdout | from csv | length) 0 "--before clear to empty left CSV rows"
    cleanup $tmp
}

def test-b1-clear-retention-keeps-index-consistent [] {
    let tmp = (make-temp-dir "b1-clear-retention")
    $env.API_ROOT = $tmp
    init-workspace
    let captured_date = (date now)
    let removed_date = ($captured_date - 15day | format date "%Y-%m-%d")
    let retained_older_date = ($captured_date - 2day | format date "%Y-%m-%d")
    let retained_newer_date = ($captured_date - 1day | format date "%Y-%m-%d")
    let config_path = ($tmp | path join "config.nuon")
    open $config_path | upsert history_retention_days 7 | to nuon | save -f $config_path
    let fixtures = (prepare-clear-fixtures $tmp "retention" $removed_date $retained_older_date $retained_newer_date)

    let result = (run-command-process $tmp "api history clear --force")
    assert equal $result.exit_code 0 "configured-retention clear failed"
    assert equal ($result.stderr | str trim) "" "configured-retention clear wrote stderr"
    assert ($result.stdout | str contains "Cleared 1 days of history older than 7 days") "configured-retention clear output changed"
    assert (not (($tmp | path join "history" $removed_date) | path exists)) "configured retention retained the expired directory"
    assert (($tmp | path join "history" $retained_older_date $"($fixtures.retained_older.id).nuon") | path exists) "configured retention removed the older retained entry file"
    assert (($tmp | path join "history" $retained_newer_date $"($fixtures.retained_newer.id).nuon") | path exists) "configured retention removed the newer retained entry file"
    assert-clear-surfaces $tmp [$fixtures.retained_newer.id $fixtures.retained_older.id] [$fixtures.removed.id] "configured retention"
    cleanup $tmp
}

def start-history-delete-blocker [root: string, target: string] {
    let directory = ($target | path dirname)
    if $nu.os-info.name != "windows" {
        ^chmod 000 $target
        ^chmod 500 $directory
        return {mode: "permissions-delete", directory: $directory, target: $target}
    }

    let holder_script = ($root | path join "delete-block-holder.ps1")
    let launcher_script = ($root | path join "delete-block-launcher.ps1")
    let ready_file = ($root | path join "delete-block-ready.txt")
    let holder_source = "param($Target, $ReadyFile)
$stream = [System.IO.File]::Open(
    $Target,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
[System.IO.FileShare]::None
)
try {
    [System.IO.File]::WriteAllText($ReadyFile, 'ready')
    [System.Threading.ManualResetEvent]::new($false).WaitOne() | Out-Null
} finally {
    $stream.Dispose()
}"
    let launcher_source = "param($HolderScript, $Target, $ReadyFile)
$arguments = @(
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    ('\"{0}\"' -f $HolderScript),
    ('\"{0}\"' -f $Target),
    ('\"{0}\"' -f $ReadyFile)
)
$process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -PassThru -WindowStyle Hidden
if (-not [System.Threading.SpinWait]::SpinUntil({ Test-Path -LiteralPath $ReadyFile }, 10000)) {
    Stop-Process -Id $process.Id -Force
    throw 'Delete blocker did not reach the ready barrier'
}
$process.Id"
    $holder_source | save -f $holder_script
    $launcher_source | save -f $launcher_script
    let launched = (
        do {
            ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcher_script $holder_script $target $ready_file
        }
        | complete
    )
    assert equal $launched.exit_code 0 $"delete blocker failed to lock the entry file: ($launched.stderr)"
    {
        mode: "lock"
        pid: ($launched.stdout | str trim | into int)
    }
}

def start-history-read-blocker [root: string, target: string] {
    if $nu.os-info.name != "windows" {
        ^chmod 000 $target
        return {mode: "permissions-read", target: $target}
    }

    let holder_script = ($root | path join "read-block-holder.ps1")
    let launcher_script = ($root | path join "read-block-launcher.ps1")
    let ready_file = ($root | path join "read-block-ready.txt")
    let holder_source = "param($Target, $ReadyFile)
$stream = [System.IO.File]::Open(
    $Target,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::None
)
try {
    [System.IO.File]::WriteAllText($ReadyFile, 'ready')
    [System.Threading.ManualResetEvent]::new($false).WaitOne() | Out-Null
} finally {
    $stream.Dispose()
}"
    let launcher_source = "param($HolderScript, $Target, $ReadyFile)
$arguments = @(
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    ('\"{0}\"' -f $HolderScript),
    ('\"{0}\"' -f $Target),
    ('\"{0}\"' -f $ReadyFile)
)
$process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -PassThru -WindowStyle Hidden
if (-not [System.Threading.SpinWait]::SpinUntil({ Test-Path -LiteralPath $ReadyFile }, 10000)) {
    Stop-Process -Id $process.Id -Force
    throw 'Read blocker did not reach the ready barrier'
}
$process.Id"
    $holder_source | save -f $holder_script
    $launcher_source | save -f $launcher_script
    let launched = (
        do {
            ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcher_script $holder_script $target $ready_file
        }
        | complete
    )
    assert equal $launched.exit_code 0 $"read blocker failed to lock the entry file: ($launched.stderr)"
    {
        mode: "lock"
        pid: ($launched.stdout | str trim | into int)
    }
}

def stop-history-delete-blocker [blocker: record] {
    if $blocker.mode == "permissions-delete" {
        ^chmod 700 $blocker.directory
        ^chmod 600 $blocker.target
        return
    }
    if $blocker.mode == "permissions-read" {
        ^chmod 600 $blocker.target
        return
    }
    let stopped = (test-complete-result (
        ^powershell.exe -NoProfile -NonInteractive -Command (
            "Stop-Process -Id " + ($blocker.pid | into string) + " -Force -ErrorAction SilentlyContinue"
        )
        | complete
    ))
    assert equal $stopped.exit_code 0 $"delete blocker failed to release the file lock: ($stopped.stderr)"
}

def run-partial-clear-failure-case [mode: string] {
    if $nu.os-info.name != "windows" and ((^id -u | into int) == 0) {
        error make {msg: "SKIP: permission-based delete failure cannot be induced as root"}
    }

    let tmp = (make-temp-dir $"b1-clear-failure-($mode)")
    $env.API_ROOT = $tmp
    init-workspace
    let captured_date = (date now)
    let dates = if $mode == "before" {
        {first: "2000-01-01", blocked: "2000-01-02", retained: "2000-01-03"}
    } else {
        {first: ($captured_date - 16day | format date "%Y-%m-%d"), blocked: ($captured_date - 15day | format date "%Y-%m-%d"), retained: ($captured_date - 1day | format date "%Y-%m-%d")}
    }
    if $mode == "retention" {
        let config_path = ($tmp | path join "config.nuon")
        open $config_path | upsert history_retention_days 7 | to nuon | save -f $config_path
    }

    let first = (clear-fixture $"($mode)-first" $dates.first $"failure-($mode)")
    let blocked = (clear-fixture $"($mode)-blocked" $dates.blocked $"failure-($mode)")
    let retained = (clear-fixture $"($mode)-retained" $dates.retained $"failure-($mode)")
    save-history-fixture $tmp $dates.first $first
    save-history-fixture $tmp $dates.blocked $blocked
    save-history-fixture $tmp $dates.retained $retained
    api history rebuild-index | ignore
    let blocked_path = ($tmp | path join "history" $dates.blocked $"($blocked.id).nuon")
    let blocker = (start-history-delete-blocker $tmp $blocked_path)
    let command = if $mode == "before" {
        "api history clear --before 2000-01-03 --force"
    } else {
        "api history clear --force"
    }
    let result = (run-command-process $tmp $command)
    let stop_failure = try { stop-history-delete-blocker $blocker; null } catch {|error| $error }
    if $stop_failure != null {
        cleanup $tmp
        error make {msg: $stop_failure.msg}
    }

    let failure = try {
        assert ($result.exit_code != 0) $"($mode): partial deletion failure exited zero"
        assert equal ($result.stdout | str trim) "" $"($mode): partial deletion failure wrote stdout"
        assert equal $result.stderr ($result.stderr | ansi strip) $"($mode): deletion error contained ANSI"
        assert (not ($result.stderr | str trim | is-empty)) $"($mode): deletion error was empty"
        assert ($result.stderr | str contains $dates.blocked) $"($mode): deletion error did not identify the blocked directory"
        assert (not ($result.stderr | str contains "Cleared ")) $"($mode): deletion failure printed misleading success text"

        assert (not (($tmp | path join "history" $dates.first) | path exists)) $"($mode): first committed deletion was rolled back"
        assert ($blocked_path | path exists) $"($mode): blocked entry file was removed"
        assert (($tmp | path join "history" $dates.retained $"($retained.id).nuon") | path exists) $"($mode): retained entry file was removed"
        assert-clear-surfaces $tmp [$retained.id $blocked.id] [$first.id] $"($mode) delete failure"
        null
    } catch {|error| $error }

    cleanup $tmp
    if $failure != null { error make {msg: $failure.msg} }
}

def run-partial-entry-delete-failure-case [mode: string] {
    if $nu.os-info.name != "windows" and ((^id -u | into int) == 0) {
        error make {msg: "SKIP: permission-based delete failure cannot be induced as root"}
    }

    let tmp = (make-temp-dir $"b1-partial-entry-failure-($mode)")
    $env.API_ROOT = $tmp
    init-workspace
    let captured_date = (date now)
    let dates = if $mode == "before" {
        {target: "2000-01-01", retained: "2000-01-02"}
    } else {
        {target: ($captured_date - 15day | format date "%Y-%m-%d"), retained: ($captured_date - 1day | format date "%Y-%m-%d")}
    }
    if $mode == "retention" {
        let config_path = ($tmp | path join "config.nuon")
        open $config_path | upsert history_retention_days 7 | to nuon | save -f $config_path
    }

    let ordinary = (clear-fixture $"a-($mode)-ordinary" $dates.target $"partial-entry-($mode)")
    let blocked = (clear-fixture $"z-($mode)-blocked" $dates.target $"partial-entry-($mode)")
    let retained = (clear-fixture $"($mode)-retained" $dates.retained $"partial-entry-($mode)")
    save-history-fixture $tmp $dates.target $ordinary
    save-history-fixture $tmp $dates.target $blocked
    save-history-fixture $tmp $dates.retained $retained
    api history rebuild-index | ignore

    let ordinary_path = ($tmp | path join "history" $dates.target $"($ordinary.id).nuon")
    let blocked_path = ($tmp | path join "history" $dates.target $"($blocked.id).nuon")
    let retained_path = ($tmp | path join "history" $dates.retained $"($retained.id).nuon")
    let blocked_before = (open $blocked_path --raw)
    let retained_before = (open $retained_path --raw)
    let config_path = ($tmp | path join "config.nuon")
    let config_before = (open $config_path --raw)

    # POSIX permits unlinking an open file. Remove the ordinary file first,
    # then use permissions to reproduce the same partially committed state.
    if $nu.os-info.name != "windows" {
        rm $ordinary_path
    }
    let blocker = (start-history-delete-blocker $tmp $blocked_path)
    let command = if $mode == "before" {
        "api history clear --before 2000-01-02 --force"
    } else {
        "api history clear --force"
    }
    let result = (run-command-process $tmp $command)
    let stop_failure = try { stop-history-delete-blocker $blocker; null } catch {|error| $error }
    if $stop_failure != null {
        cleanup $tmp
        error make {msg: $stop_failure.msg}
    }

    let failure = try {
        assert ($result.exit_code != 0) $"($mode): first-directory partial deletion exited zero"
        assert equal ($result.stdout | str trim) "" $"($mode): first-directory partial deletion wrote stdout"
        assert equal $result.stderr ($result.stderr | ansi strip) $"($mode): first-directory deletion error contained ANSI"
        assert (not ($result.stderr | str trim | is-empty)) $"($mode): first-directory deletion error was empty"
        assert ($result.stderr | str contains $dates.target) $"($mode): first-directory deletion error did not identify the blocked target"
        assert (not ($result.stderr | str contains "Cleared ")) $"($mode): first-directory deletion failure printed success text"

        assert (not ($ordinary_path | path exists)) $"($mode): ordinary entry was not deleted before the failure"
        assert ($blocked_path | path exists) $"($mode): blocked entry file was removed"
        assert ($retained_path | path exists) $"($mode): retained entry file was removed"
        assert equal (open $blocked_path --raw) $blocked_before $"($mode): blocked entry bytes changed"
        assert equal (open $retained_path --raw) $retained_before $"($mode): retained entry bytes changed"
        assert equal (open $config_path --raw) $config_before $"($mode): config changed"
        assert-valid-history-index $tmp [$retained.id $blocked.id] $"($mode) first-directory delete failure"
        assert-clear-surfaces $tmp [$retained.id $blocked.id] [$ordinary.id] $"($mode) first-directory delete failure"
        null
    } catch {|error| $error }

    cleanup $tmp
    if $failure != null { error make {msg: $failure.msg} }
}

def test-b1-clear-before-first-directory-failure-reconciles-index [] {
    run-partial-entry-delete-failure-case "before"
}

def test-b1-clear-retention-first-directory-failure-reconciles-index [] {
    run-partial-entry-delete-failure-case "retention"
}

def test-b1-rebuild-entry-io-failure-preserves-index [] {
    if $nu.os-info.name != "windows" and ((^id -u | into int) == 0) {
        error make {msg: "SKIP: unreadable entry-file failure cannot be induced as root"}
    }

    let tmp = (make-temp-dir "b1-rebuild-entry-io")
    $env.API_ROOT = $tmp
    init-workspace
    let readable = (clear-fixture "rebuild-readable" "2000-01-01" "rebuild-io")
    let blocked = (clear-fixture "rebuild-blocked" "2000-01-02" "rebuild-io")
    save-history-fixture $tmp "2000-01-01" $readable
    save-history-fixture $tmp "2000-01-02" $blocked
    api history rebuild-index | ignore

    let index_path = ($tmp | path join "history" "index.nuon")
    let readable_path = ($tmp | path join "history" "2000-01-01" $"($readable.id).nuon")
    let blocked_path = ($tmp | path join "history" "2000-01-02" $"($blocked.id).nuon")
    let index_before = (open $index_path --raw)
    let readable_before = (open $readable_path --raw)
    let blocked_before = (open $blocked_path --raw)
    let blocker = (start-history-read-blocker $tmp $blocked_path)

    let explicit = (run-command-process $tmp "api history rebuild-index | ignore")
    let index_after_explicit = (open $index_path --raw)
    "{}" | save -f $index_path
    let invalid_index_before = (open $index_path --raw)
    let automatic = (run-command-process $tmp "api history list --limit 100 | ignore")
    let invalid_index_after = (open $index_path --raw)

    let stop_failure = try { stop-history-delete-blocker $blocker; null } catch {|error| $error }
    if $stop_failure != null {
        cleanup $tmp
        error make {msg: $stop_failure.msg}
    }

    let failure = try {
        for result in [$explicit $automatic] {
            assert ($result.exit_code != 0) "unreadable entry rebuild exited zero"
            assert equal ($result.stdout | str trim) "" "unreadable entry rebuild wrote stdout or success text"
            assert equal $result.stderr ($result.stderr | ansi strip) "unreadable entry rebuild error contained ANSI"
            assert (not ($result.stderr | str trim | is-empty)) "unreadable entry rebuild error was empty"
            assert ($result.stderr | str contains $blocked.id) "unreadable entry rebuild error did not identify the blocked entry"
            assert (not ($result.stderr | str contains "Index rebuilt")) "failed rebuild printed success text"
        }
        assert equal $index_after_explicit $index_before "explicit failed rebuild replaced the valid index"
        assert equal $invalid_index_after $invalid_index_before "automatic failed rebuild replaced the invalid index"
        assert equal (open $readable_path --raw) $readable_before "failed rebuild changed the readable entry"
        assert equal (open $blocked_path --raw) $blocked_before "failed rebuild changed the blocked entry"

        "{not valid nuon" | save -f ($tmp | path join "history" "2000-01-01" "corrupt-syntax.nuon")
        "42" | save -f ($tmp | path join "history" "2000-01-01" "corrupt-shape.nuon")
        0x[ff fe 00] | save -f ($tmp | path join "history" "2000-01-01" "corrupt-binary.nuon")
        let recovered = (run-command-process $tmp "api history rebuild-index | ignore")
        assert equal $recovered.exit_code 0 "content-invalid entries made rebuild fail"
        assert equal ($recovered.stderr | str trim) "" "content-invalid entry rebuild wrote stderr"
        assert ($recovered.stdout | str contains "Index rebuilt: 2 entries") "content-invalid entry rebuild output/count changed"
        assert-valid-history-index $tmp [$blocked.id $readable.id] "content-invalid entry rebuild"
        null
    } catch {|error| $error }

    cleanup $tmp
    if $failure != null { error make {msg: $failure.msg} }
}

def test-b1-partial-clear-rebuild-failure-reconciles-index [] {
    if $nu.os-info.name != "windows" and ((^id -u | into int) == 0) {
        error make {msg: "SKIP: unreadable entry-file failure cannot be induced as root"}
    }

    let tmp = (make-temp-dir "b1-clear-rebuild-failure")
    $env.API_ROOT = $tmp
    init-workspace
    let removed = (clear-fixture "rebuild-failure-removed" "2000-01-01" "clear-rebuild-failure")
    let retained = (clear-fixture "rebuild-failure-retained" "2000-01-02" "clear-rebuild-failure")
    save-history-fixture $tmp "2000-01-01" $removed
    save-history-fixture $tmp "2000-01-02" $retained
    api history rebuild-index | ignore

    let removed_dir = ($tmp | path join "history" "2000-01-01")
    let retained_path = ($tmp | path join "history" "2000-01-02" $"($retained.id).nuon")
    let retained_before = (open $retained_path --raw)
    let blocker = (start-history-read-blocker $tmp $retained_path)
    let result = (run-command-process $tmp "api history clear --before 2000-01-02 --force")
    let observation = try {
        {
            index_ids: (open ($tmp | path join "history" "index.nuon") | get id)
            list_ids: (api history list --limit 100 | get id)
            url_ids: (api history search "clear-index-consistency" --limit 100 | get id)
        }
    } catch {|error| {error: $error} }
    let stop_failure = try { stop-history-delete-blocker $blocker; null } catch {|error| $error }
    if $stop_failure != null {
        cleanup $tmp
        error make {msg: $stop_failure.msg}
    }

    let failure = try {
        assert ($result.exit_code != 0) "post-delete rebuild failure exited zero"
        assert equal ($result.stdout | str trim) "" "post-delete rebuild failure wrote stdout"
        assert equal $result.stderr ($result.stderr | ansi strip) "post-delete rebuild error contained ANSI"
        assert (
            ($result.stderr | str contains "rebuild-failure-")
            and ($result.stderr | str contains "retained.nuon")
        ) "post-delete rebuild error omitted the unreadable survivor"
        assert (not ($result.stderr | str contains "Cleared ")) "post-delete rebuild failure printed success text"
        assert equal ($observation.error? | default null) null "index-backed readers failed while survivor was locked"
        assert equal $observation.index_ids [$retained.id] "post-delete rebuild recovery kept a deleted ID"
        assert equal $observation.list_ids [$retained.id] "list disagreed with recovered index while survivor was locked"
        assert equal $observation.url_ids [$retained.id] "URL search disagreed with recovered index while survivor was locked"
        assert (not ($removed_dir | path exists)) "successful date-directory deletion was rolled back"
        assert ($retained_path | path exists) "unreadable retained entry was removed"
        assert equal (open $retained_path --raw) $retained_before "retained entry bytes changed"
        assert-clear-surfaces $tmp [$retained.id] [$removed.id] "post-delete rebuild failure"
        null
    } catch {|error| $error }

    cleanup $tmp
    if $failure != null { error make {msg: $failure.msg} }
}

def test-b1-clear-all-failure-reconciles-index [] {
    if $nu.os-info.name != "windows" and ((^id -u | into int) == 0) {
        error make {msg: "SKIP: permission-based delete failure cannot be induced as root"}
    }

    let tmp = (make-temp-dir "b1-clear-all-failure")
    $env.API_ROOT = $tmp
    init-workspace
    let ordinary = (clear-fixture "a-all-ordinary" "2000-01-01" "all-failure")
    let blocked = (clear-fixture "z-all-blocked" "2000-01-01" "all-failure")
    save-history-fixture $tmp "2000-01-01" $ordinary
    save-history-fixture $tmp "2000-01-01" $blocked
    api history rebuild-index | ignore

    let history_dir = ($tmp | path join "history")
    let ordinary_path = ($history_dir | path join "2000-01-01" $"($ordinary.id).nuon")
    let blocked_path = ($history_dir | path join "2000-01-01" $"($blocked.id).nuon")
    let blocked_before = (open $blocked_path --raw)
    if $nu.os-info.name != "windows" {
        rm $ordinary_path
    }
    let blocker = (start-history-delete-blocker $tmp $blocked_path)
    let result = (run-command-process $tmp "api history clear --all --force")
    let observation = try {
        {
            index_ids: (open ($history_dir | path join "index.nuon") | get id)
            list_ids: (api history list --limit 100 | get id)
            url_ids: (api history search "clear-index-consistency" --limit 100 | get id)
        }
    } catch {|error| {error: $error} }
    let stop_failure = try { stop-history-delete-blocker $blocker; null } catch {|error| $error }
    if $stop_failure != null {
        cleanup $tmp
        error make {msg: $stop_failure.msg}
    }

    let failure = try {
        assert ($result.exit_code != 0) "--all partial deletion failure exited zero"
        assert equal ($result.stdout | str trim) "" "--all partial deletion failure wrote stdout"
        assert equal $result.stderr ($result.stderr | ansi strip) "--all partial deletion error contained ANSI"
        assert ($result.stderr | str contains "history") "--all partial deletion error omitted the history target"
        assert (not ($result.stderr | str contains "All history cleared")) "--all partial deletion printed success text"
        assert equal ($observation.error? | default null) null "--all recovery did not recreate a readable index"
        assert equal $observation.index_ids [$blocked.id] "--all recovery did not retain exactly the survivor"
        assert equal $observation.list_ids [$blocked.id] "--all list disagreed with recovered index"
        assert equal $observation.url_ids [$blocked.id] "--all URL search disagreed with recovered index"
        assert (not ($ordinary_path | path exists)) "--all ordinary entry was not deleted before failure"
        assert ($blocked_path | path exists) "--all blocked survivor was removed"
        assert equal (open $blocked_path --raw) $blocked_before "--all survivor bytes changed"
        assert-valid-history-index $tmp [$blocked.id] "--all partial deletion failure"
        assert-clear-surfaces $tmp [$blocked.id] [$ordinary.id] "--all partial deletion failure"
        null
    } catch {|error| $error }

    cleanup $tmp
    if $failure != null { error make {msg: $failure.msg} }
}

def test-b1-clear-recovery-canonicalizes-duplicate-hints [] {
    if $nu.os-info.name != "windows" and ((^id -u | into int) == 0) {
        error make {msg: "SKIP: permission-based delete failure cannot be induced as root"}
    }

    let tmp = (make-temp-dir "b1-clear-duplicate-hints")
    $env.API_ROOT = $tmp
    init-workspace
    let ordinary = (clear-fixture "a-duplicate-ordinary" "2000-01-01" "duplicate-hints")
    let blocked = (clear-fixture "z-duplicate-blocked" "2000-01-01" "duplicate-hints")
    let retained = (clear-fixture "duplicate-retained" "2000-01-02" "duplicate-hints")
    save-history-fixture $tmp "2000-01-01" $ordinary
    save-history-fixture $tmp "2000-01-01" $blocked
    save-history-fixture $tmp "2000-01-02" $retained
    let index_path = ($tmp | path join "history" "index.nuon")
    let blocked_hint = (history-summary $blocked "2000-01-01")
    let retained_hint = (history-summary $retained "2000-01-02")
    let retained_path = ($tmp | path join "history" "2000-01-02" $"($retained.id).nuon")
    let retained_alias = ($tmp | path join "history" "2000-01-01" $"($retained.id).nuon")
    let retained_alias_created = (
        create-history-file-link $retained_alias $retained_path
        | get created
    )
    let retained_recovery_hints = if $retained_alias_created {
        let alias_hint = ($retained_hint | update date_dir "2000-01-01")
        [($alias_hint | merge {injected: "first"}) $alias_hint]
    } else {
        [($retained_hint | merge {injected: "first"}) $retained_hint]
    }
    let link_target = ($tmp | path join "history" "2000-01-02" "linked-target")
    let link_path = ($tmp | path join "history" "2000-01-02" "linked-directory.nuon")
    mkdir $link_target
    let link_created = (create-history-directory-link $link_path $link_target)
    let linked = (clear-fixture "linked-directory" "2000-01-02" "duplicate-hints")
    let linked_hint = (history-summary $linked "2000-01-02")
    let stale_hint = (
        history-summary $ordinary "1999-12-31"
        | update id "stale-duplicate-hint"
    )
    let unsafe_id = "unsafe-outside-hint"
    let unsafe_entry = (clear-fixture $unsafe_id "2000-01-01" "duplicate-hints")
    let unsafe_hint = (history-summary $unsafe_entry "..")
    let unsafe_path = ($tmp | path join $"($unsafe_id).nuon")
    "outside-history-marker" | save -f $unsafe_path
    let unsafe_before = (open $unsafe_path --raw)
    let ordinary_hint = (history-summary $ordinary "2000-01-01")
    let removed_conflict = ($ordinary_hint | update url "https://example.com/deleted-conflict")
    let hints = [
        $unsafe_hint
        $ordinary_hint
        $removed_conflict
        ...$retained_recovery_hints
        ($blocked_hint | merge {injected: "second"})
        $blocked_hint
        $stale_hint
    ]
    (
        if $link_created { $hints | append $linked_hint } else { $hints }
        | to nuon
        | save -f $index_path
    )

    let ordinary_path = ($tmp | path join "history" "2000-01-01" $"($ordinary.id).nuon")
    let blocked_path = ($tmp | path join "history" "2000-01-01" $"($blocked.id).nuon")
    if $nu.os-info.name != "windows" {
        rm $ordinary_path
    }
    let blocker = (start-history-delete-blocker $tmp $blocked_path)
    let result = (run-command-process $tmp "api history clear --before 2000-01-02 --force")
    let stop_failure = try { stop-history-delete-blocker $blocker; null } catch {|error| $error }
    if $stop_failure != null {
        cleanup $tmp
        error make {msg: $stop_failure.msg}
    }

    let failure = try {
        assert ($result.exit_code != 0) "duplicate-hint clear failure exited zero"
        assert equal ($result.stdout | str trim) "" "duplicate-hint clear failure wrote stdout"
        assert equal $result.stderr ($result.stderr | ansi strip) "duplicate-hint clear error contained ANSI"
        assert ($result.stderr | str contains "2000-01-01") "duplicate-hint clear lost the original deletion error"
        assert (not ($result.stderr | str contains "reconciliation after failed clear also failed")) "deleted or unsafe hints poisoned otherwise safe recovery"
        assert (not ($result.stderr | str contains "Cleared ")) "duplicate-hint clear failure printed success text"
        assert (not ($ordinary_path | path exists)) $"duplicate-hint ordinary entry survived: ($result.stderr)"
        assert ($blocked_path | path exists) "duplicate-hint blocked entry was removed"
        assert-valid-history-index $tmp [$retained.id $blocked.id] "duplicate-hint recovery"
        assert equal (open $index_path | length) 2 "duplicate-hint recovery retained duplicate rows"
        assert equal (
            open $index_path | where id == $retained.id | get date_dir | first
        ) "2000-01-02" "duplicate-hint recovery retained a stale logical alias"
        assert equal (open $unsafe_path --raw) $unsafe_before "duplicate-hint recovery accessed an unsafe outside target"
        assert-clear-surfaces $tmp [$retained.id $blocked.id] [$ordinary.id $unsafe_id "stale-duplicate-hint"] "duplicate-hint recovery"
        null
    } catch {|error| $error }

    cleanup $tmp
    if $failure != null { error make {msg: $failure.msg} }
}

def test-b1-clear-recovery-drops-dangling-contained-alias [
    force_link_unavailable: bool = false
] {
    if (not $force_link_unavailable) and $nu.os-info.name != "windows" and ((^id -u | into int) == 0) {
        error make {msg: "SKIP: permission-based delete failure cannot be induced as root"}
    }

    let tmp = (make-temp-dir "b1-clear-dangling-alias")
    $env.API_ROOT = $tmp
    init-workspace
    let removed = (clear-fixture "dangling-alias-removed" "2000-01-01" "dangling-alias")
    let blocked = (clear-fixture "dangling-alias-blocked" "2000-01-02" "dangling-alias")
    let retained = (clear-fixture "dangling-alias-retained" "2000-01-03" "dangling-alias")
    save-history-fixture $tmp "2000-01-01" $removed
    save-history-fixture $tmp "2000-01-02" $blocked
    save-history-fixture $tmp "2000-01-03" $retained

    let removed_path = ($tmp | path join "history" "2000-01-01" $"($removed.id).nuon")
    let blocked_path = ($tmp | path join "history" "2000-01-02" $"($blocked.id).nuon")
    let retained_dir = ($tmp | path join "history" "2000-01-03")
    let retained_path = ($retained_dir | path join $"($retained.id).nuon")
    let alias_name = $"($removed.id).nuon"
    let alias_path = ($retained_dir | path join $alias_name)
    let alias_result = try {
        create-history-file-link $alias_path $removed_path $force_link_unavailable
    } catch {|error|
        let cleanup_error = try {
            cleanup-history-alias-fixture $tmp $alias_path false
            null
        } catch {|cleanup_failure|
            $cleanup_failure
        }
        if $cleanup_error != null {
            error make {
                msg: $"($error.msg)\nHistory alias fixture cleanup also failed: ($cleanup_error.msg)"
            }
        }
        error make {msg: $error.msg}
    }
    if $alias_result.unavailable {
        cleanup-history-alias-fixture $tmp $alias_path false
        error make {
            msg: $"SKIP: history file-link creation is unavailable: ($alias_result.detail)"
        }
    }
    let alias_created = $alias_result.created
    let setup_error = try {
        let aliases_before = (
            ls -a $retained_dir
            | where {|entry| ($entry.name | path basename) == $alias_name }
        )
        assert equal ($aliases_before | length) 1 "dangling-alias fixture did not create exactly one alias"
        assert equal ($aliases_before | first | get type) "symlink" "dangling-alias fixture created a direct file instead of an alias"
        assert ($alias_path | path exists) "dangling-alias fixture did not resolve to its direct target before clear"
        api history rebuild-index | ignore
        null
    } catch {|error|
        $error
    }
    if $setup_error != null {
        let cleanup_error = try {
            cleanup-history-alias-fixture $tmp $alias_path $alias_created
            null
        } catch {|error|
            $error
        }
        if $cleanup_error != null {
            error make {
                msg: $"($setup_error.msg)\nHistory alias fixture cleanup also failed: ($cleanup_error.msg)"
            }
        }
        error make {msg: $setup_error.msg}
    }

    let blocked_before = (open $blocked_path --raw)
    let retained_before = (open $retained_path --raw)
    let blocker = (start-history-delete-blocker $tmp $blocked_path)
    let result = (run-command-process $tmp "api history clear --before 2000-01-03 --force")
    let retained_names = try {
        ls -a $retained_dir | get name | each {|path| $path | path basename }
    } catch {
        []
    }
    let stop_failure = try { stop-history-delete-blocker $blocker; null } catch {|error| $error }
    if $stop_failure != null {
        cleanup-history-alias-fixture $tmp $alias_path $alias_created
        error make {msg: $stop_failure.msg}
    }

    let failure = try {
        assert ($result.exit_code != 0) "dangling-alias clear failure exited zero"
        assert equal ($result.stdout | str trim) "" "dangling-alias clear failure wrote stdout"
        assert equal $result.stderr ($result.stderr | ansi strip) "dangling-alias clear error contained ANSI"
        assert ($result.stderr | str contains "2000-01-02") $"dangling-alias clear lost the original blocked-directory error: ($result.stderr)"
        assert (not ($result.stderr | str contains "reconciliation after failed clear also failed")) "dangling alias aborted index reconciliation"
        assert (not ($result.stderr | str contains "Cleared ")) "dangling-alias clear printed success text"
        assert (not ($removed_path | path exists)) "dangling-alias direct target survived the committed deletion"
        assert ($alias_name in $retained_names) "dangling contained alias was unexpectedly removed"
        assert (not ($alias_path | path exists)) "contained alias still resolved after its direct target was deleted"
        assert ($blocked_path | path exists) "dangling-alias blocked survivor was removed"
        assert ($retained_path | path exists) "dangling-alias retained entry was removed"
        assert equal (open $blocked_path --raw) $blocked_before "dangling-alias blocked entry bytes changed"
        assert equal (open $retained_path --raw) $retained_before "dangling-alias retained entry bytes changed"
        assert-valid-history-index $tmp [$retained.id $blocked.id] "dangling-alias recovery"
        assert-clear-surfaces $tmp [$retained.id $blocked.id] [$removed.id] "dangling-alias recovery"
        null
    } catch {|error| $error }

    cleanup-history-alias-fixture $tmp $alias_path $alias_created
    if $failure != null { error make {msg: $failure.msg} }
}

def test-b1-dangling-alias-capability-denial-skips [] {
    let result = run-test "forced unavailable dangling-alias fixture" {
        test-b1-clear-recovery-drops-dangling-contained-alias true
    }
    assert equal $result.status "skip" "forced unavailable alias fixture reported PASS"
    assert (
        $result.error | str contains "history file-link creation is unavailable"
    ) "forced unavailable alias fixture did not report the capability reason"
}

def test-b1-clear-all-restores-conflicting-index-bytes [] {
    if $nu.os-info.name != "windows" and ((^id -u | into int) == 0) {
        error make {msg: "SKIP: permission-based delete failure cannot be induced as root"}
    }

    let tmp = (make-temp-dir "b1-clear-all-restore-index")
    $env.API_ROOT = $tmp
    init-workspace
    let date_dir = "z-survivors"
    let ordinary = (clear-fixture "a-restore-ordinary" "2000-01-01" "restore-index")
    let blocked = (clear-fixture "z-restore-blocked" "2000-01-02" "restore-index")
    save-history-fixture $tmp $date_dir $ordinary
    save-history-fixture $tmp $date_dir $blocked

    let history_dir = ($tmp | path join "history")
    let index_path = ($history_dir | path join "index.nuon")
    let ordinary_path = ($history_dir | path join $date_dir $"($ordinary.id).nuon")
    let blocked_path = ($history_dir | path join $date_dir $"($blocked.id).nuon")
    let blocked_hint = (history-summary $blocked $date_dir)
    let conflicting_hint = ($blocked_hint | update url "https://example.com/conflicting-restore-hint")
    [(history-summary $ordinary $date_dir) $blocked_hint $conflicting_hint] | to nuon | save -f $index_path
    let index_before = (open $index_path --raw)
    let blocked_before = (open $blocked_path --raw)

    if $nu.os-info.name != "windows" {
        rm $ordinary_path
    }
    let blocker = (start-history-delete-blocker $tmp $blocked_path)
    let result = (run-command-process $tmp "api history clear --all --force")
    let index_after = try { open $index_path --raw } catch { null }
    let history_names = try {
        ls -a $history_dir | get name | each {|path| $path | path basename } | sort
    } catch {
        []
    }
    let survivor_names = try {
        ls -a ($history_dir | path join $date_dir) | get name | each {|path| $path | path basename } | sort
    } catch {
        []
    }
    let stop_failure = try { stop-history-delete-blocker $blocker; null } catch {|error| $error }
    if $stop_failure != null {
        cleanup $tmp
        error make {msg: $stop_failure.msg}
    }

    let failure = try {
        assert ($result.exit_code != 0) "conflicting --all clear exited zero"
        assert equal ($result.stdout | str trim) "" "conflicting --all clear wrote stdout"
        assert equal $result.stderr ($result.stderr | ansi strip) "conflicting --all error contained ANSI"
        assert ($result.stderr | str contains "History directory") $"conflicting --all lost the original delete error: ($result.stderr)"
        assert ($result.stderr | str contains "reconciliation") "conflicting --all omitted the reconciliation failure"
        assert (
            ($result.stderr | str contains "Conflicting")
            and ($result.stderr | str contains "history index hints")
        ) "conflicting --all hint error was not actionable"
        assert (not ($result.stderr | str contains "All history cleared")) "conflicting --all printed success text"
        assert (not ($ordinary_path | path exists)) "conflicting --all ordinary entry survived"
        assert ($blocked_path | path exists) "conflicting --all blocked survivor was removed"
        assert equal (open $blocked_path --raw) $blocked_before "conflicting --all changed survivor bytes"
        assert equal $index_after $index_before "conflicting --all did not restore exact prior index bytes"
        assert equal $history_names ["index.nuon" $date_dir] "conflicting --all left a recovery artifact"
        assert equal $survivor_names [$"($blocked.id).nuon"] "conflicting --all left an unexpected survivor artifact"
        null
    } catch {|error| $error }

    cleanup $tmp
    if $failure != null { error make {msg: $failure.msg} }
}

def run-conflicting-history-hint-case [mode: string] {
    if $nu.os-info.name != "windows" and ((^id -u | into int) == 0) {
        error make {msg: "SKIP: permission-based delete failure cannot be induced as root"}
    }

    let tmp = (make-temp-dir $"b1-conflicting-hints-($mode)")
    $env.API_ROOT = $tmp
    init-workspace
    let ordinary = (clear-fixture $"a-conflict-ordinary-($mode)" "2000-01-01" $"conflict-($mode)")
    let blocked = (clear-fixture $"z-conflict-blocked-($mode)" "2000-01-01" $"conflict-($mode)")
    let retained = (clear-fixture $"conflict-retained-($mode)" "2000-01-02" $"conflict-($mode)")
    save-history-fixture $tmp "2000-01-01" $ordinary
    save-history-fixture $tmp "2000-01-01" $blocked
    save-history-fixture $tmp "2000-01-02" $retained
    let blocked_hint = (history-summary $blocked "2000-01-01")
    let retained_hint = (history-summary $retained "2000-01-02")
    let conflict_hint = if $mode == "same-path" {
        $blocked_hint | update url "https://example.com/conflicting-hint"
    } else {
        save-history-fixture $tmp "2000-01-02" $blocked
        history-summary $blocked "2000-01-02"
    }
    let index_path = ($tmp | path join "history" "index.nuon")
    [$retained_hint $blocked_hint $conflict_hint] | to nuon | save -f $index_path
    let index_before = (open $index_path --raw)

    let ordinary_path = ($tmp | path join "history" "2000-01-01" $"($ordinary.id).nuon")
    let blocked_path = ($tmp | path join "history" "2000-01-01" $"($blocked.id).nuon")
    if $nu.os-info.name != "windows" {
        rm $ordinary_path
    }
    let blocker = (start-history-delete-blocker $tmp $blocked_path)
    let result = (run-command-process $tmp "api history clear --before 2000-01-02 --force")
    let stop_failure = try { stop-history-delete-blocker $blocker; null } catch {|error| $error }
    if $stop_failure != null {
        cleanup $tmp
        error make {msg: $stop_failure.msg}
    }

    let failure = try {
        assert ($result.exit_code != 0) $"($mode): conflicting-hint clear exited zero"
        assert equal ($result.stdout | str trim) "" $"($mode): conflicting-hint clear wrote stdout"
        assert equal $result.stderr ($result.stderr | ansi strip) $"($mode): conflicting-hint error contained ANSI"
        assert (
            ($result.stderr | str contains "History directory")
            and ($result.stderr | str contains "2000-01-01")
        ) $"($mode): original delete error was lost"
        assert ($result.stderr | str contains "reconciliation") $"($mode): reconciliation failure was not composed"
        assert (
            ($result.stderr | str contains "Conflicting")
            and ($result.stderr | str contains "history index hints")
        ) $"($mode): hint conflict was not actionable"
        assert (not ($result.stderr | str contains "Cleared ")) $"($mode): conflicting-hint clear printed success text"
        assert equal (open $index_path --raw) $index_before $"($mode): unsafe conflicting hints were rewritten"
        null
    } catch {|error| $error }

    cleanup $tmp
    if $failure != null { error make {msg: $failure.msg} }
}

def test-b1-clear-recovery-rejects-conflicting-hints [] {
    run-conflicting-history-hint-case "same-path"
    run-conflicting-history-hint-case "same-id-distinct-path"
}

def test-b1-clear-before-failure-reconciles-index [] {
    run-partial-clear-failure-case "before"
}

def test-b1-clear-retention-failure-reconciles-index [] {
    run-partial-clear-failure-case "retention"
}

def test-b1-clear-all-removes-entire-history [] {
    let tmp = (make-temp-dir "b1-clear-all")
    $env.API_ROOT = $tmp
    init-workspace
    let fixtures = (prepare-clear-fixtures $tmp "all" "2000-01-01" "2000-01-02" "2000-01-03")
    let index_path = ($tmp | path join "history" "index.nuon")

    let result = (run-command-process $tmp "api history clear --all --force")
    assert equal $result.exit_code 0 "--all clear failed"
    assert equal ($result.stderr | str trim) "" "--all clear wrote stderr"
    assert ($result.stdout | str contains "All history cleared") "--all clear output changed"
    let history_dir = ($tmp | path join "history")
    assert ($history_dir | path exists) "--all did not recreate the history directory"
    assert equal (ls -a $history_dir | length) 0 "--all left history files or directories behind"
    assert (not ($index_path | path exists)) "--all left an index behind"
    assert equal (api history get $fixtures.removed.id) null "--all retained the removed entry"
    assert equal (api history get $fixtures.retained_older.id) null "--all retained the older entry"
    assert equal (api history get $fixtures.retained_newer.id) null "--all retained the newer entry"
    cleanup $tmp
}

# -- Suite runner ---------------------------------------------------------------

def run-suite-history-compatibility []: nothing -> list<record> {
    [
        (run-test "B1: canonical, reverse, and shuffled indexes preserve read surfaces" { test-b1-index-order-equivalence })
        (run-test "B1: legacy, offset, tied, and malformed timestamps preserve fallback order" { test-b1-legacy-ordering-equivalence })
        (run-test "B1: unusable index shapes rebuild equivalently" { test-b1-unusable-index-equivalence })
        (run-test "B1: workspace-derived ID resolution preserves exact, ambiguity, stale, and case behavior" { test-b1-resolution-workspace-equivalence })
        (run-test "B1: unsorted indexes retain monotonic persistence" { test-b1-monotonic-unsorted-index })
        (run-test "B1: history save loads the index exactly once" { test-b1-save-loads-index-once })
        (run-test "B1: history locks support percent-bearing roots and index-free rebuilds" { test-b1-history-lock-path-compatibility })
    ]
}

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
        (run-test "B1: ten-entry burst is deterministic before and after rebuild" { test-b1-burst-order-is-deterministic })
        (run-test "B1: clock collision keeps timestamp, ID, and date directory consistent" { test-b1-clock-collision-boundary-consistency })
        (run-test "B1: mixed and malformed timestamps use canonical deterministic order" { test-b1-mixed-and-malformed-timestamps })
        (run-test "B1: history IDs resolve exact-first and reject ambiguous partials" { test-b1-history-id-resolution })
        ...(run-suite-history-compatibility)
        (run-test "B1: concurrent saves preserve every index row" { test-b1-concurrent-saves-preserve-index })
        (run-test "B1: API_ROOT and default environment stay isolated" { test-b1-api-root-environment-scoping })
        (run-test "B1: structurally invalid indexes rebuild canonically" { test-b1-invalid-index-shapes-recover })
        (run-test "B1: --before clear keeps index-backed surfaces consistent" { test-b1-clear-before-keeps-index-consistent })
        (run-test "B1: configured retention keeps index-backed surfaces consistent" { test-b1-clear-retention-keeps-index-consistent })
        (run-test "B1: --before deletion failure reconciles committed index changes" { test-b1-clear-before-failure-reconciles-index })
        (run-test "B1: retention deletion failure reconciles committed index changes" { test-b1-clear-retention-failure-reconciles-index })
        (run-test "B1: --before first-directory failure reconciles partial file deletion" { test-b1-clear-before-first-directory-failure-reconciles-index })
        (run-test "B1: retention first-directory failure reconciles partial file deletion" { test-b1-clear-retention-first-directory-failure-reconciles-index })
        (run-test "B1: rebuild I/O failures preserve the previous index" { test-b1-rebuild-entry-io-failure-preserves-index })
        (run-test "B1: post-delete rebuild failure reconciles surviving hints" { test-b1-partial-clear-rebuild-failure-reconciles-index })
        (run-test "B1: --all partial deletion failure reconciles surviving hints" { test-b1-clear-all-failure-reconciles-index })
        (run-test "B1: exceptional recovery canonicalizes duplicate hints" { test-b1-clear-recovery-canonicalizes-duplicate-hints })
        (run-test "B1: unavailable dangling-alias capability reports SKIP" { test-b1-dangling-alias-capability-denial-skips })
        (run-test "B1: exceptional recovery drops dangling contained aliases" { test-b1-clear-recovery-drops-dangling-contained-alias })
        (run-test "B1: exceptional recovery rejects conflicting hints" { test-b1-clear-recovery-rejects-conflicting-hints })
        (run-test "B1: failed conflicting --all restores exact index bytes" { test-b1-clear-all-restores-conflicting-index-bytes })
        (run-test "B1: --all removes the entire indexed history state" { test-b1-clear-all-removes-entire-history })
    ]
}
