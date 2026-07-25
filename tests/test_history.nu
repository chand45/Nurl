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
        ^chmod 500 $directory
        return {mode: "permissions", directory: $directory}
    }

    let holder_script = ($root | path join "delete-block-holder.ps1")
    let launcher_script = ($root | path join "delete-block-launcher.ps1")
    let ready_file = ($root | path join "delete-block-ready.txt")
    let holder_source = "param($Target, $ReadyFile)
$stream = [System.IO.File]::Open(
    $Target,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read
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

def stop-history-delete-blocker [blocker: record] {
    if $blocker.mode == "permissions" {
        ^chmod 700 $blocker.directory
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
        (run-test "B1: API_ROOT and default environment stay isolated" { test-b1-api-root-environment-scoping })
        (run-test "B1: structurally invalid indexes rebuild canonically" { test-b1-invalid-index-shapes-recover })
        (run-test "B1: --before clear keeps index-backed surfaces consistent" { test-b1-clear-before-keeps-index-consistent })
        (run-test "B1: configured retention keeps index-backed surfaces consistent" { test-b1-clear-retention-keeps-index-consistent })
        (run-test "B1: --before deletion failure reconciles committed index changes" { test-b1-clear-before-failure-reconciles-index })
        (run-test "B1: retention deletion failure reconciles committed index changes" { test-b1-clear-retention-failure-reconciles-index })
        (run-test "B1: --all removes the entire indexed history state" { test-b1-clear-all-removes-entire-history })
    ]
}
