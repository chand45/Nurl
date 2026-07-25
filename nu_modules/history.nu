# History Module
# Saves and manages request/response history

use command-error.nu [fail-command]
use curl-capability.nu [require-curl-capability]
use resource-path.nu [resolve-under-base]
use string-compat.nu [ascii-equal-ignore-case]
use auth.nu [auth-history-projection redact-sensitive-headers sensitive-header validate-secret-safe-url]

# Get history directory
def get-history-dir [] {
    let root = ($env.API_ROOT? | default (pwd))
    $root | path join "history"
}

# Get history index file path (B1)
def get-history-index-path [] {
    (get-history-dir) | path join "index.nuon"
}

# Parse legacy second-only and fractional RFC3339 timestamps to nanoseconds.
# Invalid timestamps sort last but remain available to history readers.
def history-timestamp-instant [timestamp: any] {
    if ($timestamp | describe) != "string" or ($timestamp | str trim | is-empty) {
        return null
    }
    if $timestamp !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$' {
        return null
    }

    try {
        $timestamp | into datetime | into int
    } catch {
        null
    }
}

# Canonical newest-first ordering. Input order is the tie-breaker so an existing
# index preserves the best available chronology for truly tied legacy entries.
def sort-history-entries [] {
    let entries = $in
    let count = ($entries | length)
    $entries
    | enumerate
    | each {|row|
        let instant = (history-timestamp-instant ($row.item.timestamp? | default null))
        $row.item | merge {
            _history_timestamp_valid: ($instant != null)
            _history_timestamp_instant: ($instant | default 0)
            _history_tie_order: ($count - $row.index)
        }
    }
    | sort-by _history_timestamp_valid _history_timestamp_instant _history_tie_order -r
    | reject _history_timestamp_valid _history_timestamp_instant _history_tie_order
}

# Only lists/tables of summaries with stable identity/path fields are usable
# index data. Other parseable NUON shapes are rebuilt from entry files.
def history-index-summary-valid [summary: any] {
    if not (($summary | describe) | str starts-with "record") {
        return false
    }
    let id = ($summary.id? | default null)
    let date_dir = ($summary.date_dir? | default null)
    (($id | describe) == "string") and (not ($id | str trim | is-empty)) and (($date_dir | describe) == "string") and (not ($date_dir | str trim | is-empty))
}

def read-history-index [] {
    let path = (get-history-index-path)
    if not ($path | path exists) {
        return {usable: false, entries: []}
    }

    # Read errors (for example permissions) must remain visible. Only NUON
    # syntax/shape errors make an index unusable and eligible for rebuilding.
    let raw = (open $path --raw)
    let parsed = try {
        {valid_nuon: true, value: ($raw | from nuon)}
    } catch {
        {valid_nuon: false, value: null}
    }
    if not $parsed.valid_nuon {
        return {usable: false, entries: []}
    }

    let value_type = ($parsed.value | describe)
    if not (($value_type | str starts-with "list") or ($value_type | str starts-with "table")) {
        return {usable: false, entries: []}
    }
    if not ($parsed.value | all {|entry| history-index-summary-valid $entry }) {
        return {usable: false, entries: []}
    }

    {usable: true, entries: $parsed.value}
}

# Load history index — list of summary entries (B1)
def load-history-index [] {
    (read-history-index).entries
}

# Append one summary entry to the history index (B1) — keeps index sorted newest-first
def append-to-history-index [summary: record] {
    let path = (get-history-index-path)
    let existing = (load-history-index)
    ($existing | append $summary | sort-history-entries) | to nuon | save -f $path
}

# Convert a persisted history entry to its index summary.
def history-entry-summary [entry: record, date_dir: string] {
    {
        id: ($entry.id? | default "")
        timestamp: ($entry.timestamp? | default "")
        method: ($entry.request?.method? | default "")
        url: ($entry.request?.url? | default "")
        status: ($entry.response?.status? | default 0)
        time_ms: ($entry.response?.time_ms? | default 0)
        date_dir: $date_dir
    }
}

# Scan files in deterministic ID order, preferring an existing index's order
# when it can disambiguate tied legacy timestamps.
def scan-history-summaries [existing: list = []] {
    let dir = (get-history-dir)
    let subdirs = try { ls $dir | where type == dir | get name | sort } catch { [] }
    let scanned = $subdirs | each {|subdir|
        let date_dir = ($subdir | path basename)
        (try { ls $subdir | where name =~ '\.nuon$' | get name | sort } catch { [] })
        | each {|file|
            try {
                history-entry-summary (open $file) $date_dir
            } catch { null }
        }
        | where {|e| $e != null }
    } | flatten | sort-by id

    let existing_ids = $existing | each {|entry|
        let id = ($entry.id? | default "")
        if ($id | describe) == "string" { $id } else { "" }
    } | uniq
    if ($existing_ids | is-empty) {
        return $scanned
    }

    let keyed_scanned = $scanned | each {|entry|
        $entry | merge {_history_id_key: ($entry.id | encode base64)}
    }
    let scanned_by_id = ($keyed_scanned | group-by _history_id_key)
    let hints = $existing_ids | each {|id|
        {_history_id_key: ($id | encode base64)}
    }
    let hinted_ids = ($hints | group-by _history_id_key)
    let preserved = $hints | each {|hint|
        let matches = try {
            $scanned_by_id | get $hint._history_id_key
        } catch {
            []
        }
        if ($matches | is-empty) {
            null
        } else {
            $matches | first | reject _history_id_key
        }
    } | where {|entry| $entry != null }
    let remaining = $keyed_scanned | where {|entry|
        try {
            $hinted_ids | get $entry._history_id_key | is-empty
        } catch {
            true
        }
    } | reject _history_id_key

    $preserved | append $remaining
}

def rebuild-history-index [] {
    let existing = (load-history-index)
    let entries = (
        scan-history-summaries $existing
        | sort-history-entries
    )

    let path = (get-history-index-path)
    $entries | to nuon | save -f $path
    $entries
}

# Rebuild the full history index by scanning all date dirs + files (B1)
export def "api history rebuild-index" [] {
    let dir = (get-history-dir)
    if not ($dir | path exists) { return [] }

    let entries = (rebuild-history-index)
    print $"(ansi green)Index rebuilt: ($entries | length) entries(ansi reset)"
    $entries
}

# Ensure history index exists; auto-rebuild if missing (B1)
def ensure-history-index [] {
    let index = (read-history-index)
    if not $index.usable {
        let dir = (get-history-dir)
        if ($dir | path exists) {
            rebuild-history-index | ignore
        }
    }
}

# Ensure history directory exists
def ensure-history-dir [] {
    let dir = (get-history-dir)
    if not ($dir | path exists) {
        mkdir $dir
    }
    $dir
}

# Generate history entry ID from the same persistence instant as the entry.
def generate-history-id [instant: datetime] {
    let date_part = ($instant | format date "%Y%m%d-%H%M%S")
    let random_part = (random chars --length 6)
    $"($date_part)-($random_part)"
}

def next-history-persistence-instant [captured_at: datetime] {
    let captured_ns = ($captured_at | into int)
    let valid_instants = (
        load-history-index
        | each {|entry| history-timestamp-instant ($entry.timestamp? | default null) }
        | where {|instant| $instant != null }
    )
    let latest_ns = if ($valid_instants | is-empty) {
        null
    } else {
        $valid_instants | math max
    }

    if $latest_ns != null and $captured_ns <= $latest_ns {
        $captured_at + (($latest_ns - $captured_ns + 1) | into duration --unit ns)
    } else {
        $captured_at
    }
}

def validate-history-limit [limit: int] {
    if $limit < 0 {
        fail-command $"History --limit must be non-negative, got ($limit)"
    }
}

def rebuild-after-history-delete-error [delete_error: record] {
    try {
        rebuild-history-index | ignore
    } catch {|rebuild_error|
        error make {
            msg: $"($delete_error.msg)\nHistory index rebuild after partial clear also failed: ($rebuild_error.msg)"
        }
    }
    error make $delete_error
}

def clear-history-before-cutoff [dir: string, cutoff: datetime] {
    let dirs = (
        ls $dir
        | where type == dir
        | sort-by name
    )
    mut cleared = 0

    for d in $dirs {
        let dir_date = try {
            $d.name | path basename | into datetime
        } catch {
            continue
        }

        if $dir_date < $cutoff {
            let delete_error = try {
                rm -rf $d.name
                if ($d.name | path exists) {
                    {msg: $"History directory '($d.name)' could not be deleted"}
                } else {
                    null
                }
            } catch {|delete_error|
                $delete_error
                | upsert msg $"History directory '($d.name)' could not be deleted: ($delete_error.msg)"
            }
            if $delete_error != null {
                if $cleared > 0 {
                    rebuild-after-history-delete-error $delete_error
                }
                error make $delete_error
            }
            $cleared = $cleared + 1
        }
    }

    if $cleared > 0 {
        rebuild-history-index | ignore
    }
    $cleared
}

def history-list-time [timestamp: any] {
    try {
        $timestamp | into datetime | date to-timezone UTC | format date "%H:%M:%S"
    } catch {
        ""
    }
}

def history-search-time [timestamp: any] {
    if ($timestamp | describe) != "string" {
        return ""
    }
    try {
        $timestamp | into datetime | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ"
    } catch {
        $timestamp
    }
}

def history-entry-path [summary: record] {
    let logical_name = $"(($summary.date_dir? | default ''))/(($summary.id? | default ''))"
    resolve-under-base (get-history-dir) $logical_name "history entry" --nested --suffix ".nuon" --always-suffix --scope="history directory"
}

def sanitize-history-headers [headers: any, label: string] {
    if not (($headers | describe) | str starts-with "record") {
        fail-command $"($label) headers must be a record"
    }
    {
        headers: (redact-sensitive-headers $headers)
        had_sensitive: (
            $headers
            | transpose key value
            | any {|header| sensitive-header $header.key $header.value }
        )
    }
}

def sanitize-history-request [request: record] {
    let method = ($request.method? | default null)
    if $method == null or ($method | describe) != "string" or ($method | str trim | is-empty) {
        fail-command "History request method must be a non-empty string"
    }
    let url = ($request.url? | default null)
    if $url == null or ($url | describe) != "string" or ($url | str trim | is-empty) {
        fail-command "History request URL must be a non-empty string"
    }
    validate-secret-safe-url $url | ignore
    let headers_replayable = ($request.headers_replayable? | default null)
    if $headers_replayable != null and ($headers_replayable | describe) != "bool" {
        fail-command "History request headers_replayable must be a boolean"
    }
    let header_context = (
        sanitize-history-headers ($request.headers? | default {}) "History request"
    )
    mut safe_request = {
        method: $method
        url: $url
        headers: $header_context.headers
        body: ($request.body? | default null)
    }
    let auth = ($request.auth? | default null)
    if $auth != null {
        if not (($auth | describe) | str starts-with "record") {
            fail-command "History request authentication must be a record"
        }
        let safe_auth = (auth-history-projection $auth)
        if $safe_auth == null {
            $safe_request = ($safe_request | reject auth)
        } else {
            $safe_request = ($safe_request | upsert auth $safe_auth)
        }
    }
    if $header_context.had_sensitive or ($request.headers_replayable? | default true) == false {
        $safe_request = ($safe_request | upsert headers_replayable false)
    }
    $safe_request
}

def sanitize-history-response [response: record] {
    let status = ($response.status? | default null)
    if $status == null or ($status | describe) != "int" or $status < 100 or $status > 599 {
        fail-command "History response status must be an integer between 100 and 599"
    }
    let status_text = ($response.status_text? | default null)
    if $status_text == null or ($status_text | describe) != "string" {
        fail-command "History response status_text must be a string"
    }
    let time_ms = ($response.time_ms? | default null)
    if $time_ms == null or ($time_ms | describe) not-in ["int" "float"] or $time_ms < 0 {
        fail-command "History response time_ms must be a non-negative number"
    }
    let size_bytes = ($response.size_bytes? | default null)
    if $size_bytes == null or ($size_bytes | describe) != "int" or $size_bytes < 0 {
        fail-command "History response size_bytes must be a non-negative integer"
    }
    let header_context = (
        sanitize-history-headers ($response.headers? | default {}) "History response"
    )
    {
        status: $status
        status_text: $status_text
        headers: $header_context.headers
        body: ($response.body? | default null)
        time_ms: $time_ms
        size_bytes: $size_bytes
    }
}

# Save request/response to history
export def "api history save" [
    request: record    # Request details
    response: record   # Response details
] {
    let safe_request = (sanitize-history-request $request)
    let safe_response = (sanitize-history-response $response)
    let captured_at = (date now | date to-timezone UTC)
    let dir = (ensure-history-dir)
    ensure-history-index
    let persisted_at = (next-history-persistence-instant $captured_at)
    let date_dir = ($dir | path join ($persisted_at | format date "%Y-%m-%d"))

    if not ($date_dir | path exists) {
        mkdir $date_dir
    }

    let id = (generate-history-id $persisted_at)

    # Get current environment
    let root = ($env.API_ROOT? | default (pwd))
    let config_path = ($root | path join "config.nuon")
    let current_env = if ($config_path | path exists) {
        (open $config_path).default_environment? | default null
    } else {
        null
    }

    let entry = {
        id: $id
        timestamp: ($persisted_at | format date "%Y-%m-%dT%H:%M:%S%.9fZ")
        environment: $current_env
        request: $safe_request
        response: $safe_response
    }

    let file_name = $"($id).nuon"
    let file_path = ($date_dir | path join $file_name)

    $entry | to nuon | save $file_path

    # Update history index (B1)
    append-to-history-index {
        id: $id
        timestamp: $entry.timestamp
        method: ($safe_request.method? | default "")
        url: ($safe_request.url? | default "")
        status: ($safe_response.status? | default 0)
        time_ms: ($safe_response.time_ms? | default 0)
        date_dir: ($date_dir | path basename)
    }

    $id
}

# List history entries — uses index for O(1) list/search (B1)
export def "api history list" [
    --limit (-l): int = 20       # Number of entries to show
    --filter (-f): string = ""   # Filter by method (method:GET), status (status:200), or URL substring
    --date (-d): string = ""     # Filter by date (YYYY-MM-DD)
] {
    validate-history-limit $limit
    if $limit == 0 { return [] }

    let dir = (get-history-dir)

    if not ($dir | path exists) {
        print "(ansi yellow)No history found(ansi reset)"
        return []
    }

    # Ensure index exists (auto-build from files if needed)
    ensure-history-index

    # Load from index and ensure newest-first order (sort guards against legacy unsorted indexes)
    let all_entries = (load-history-index | sort-history-entries)

    if ($all_entries | is-empty) {
        print "(ansi yellow)No history found(ansi reset)"
        return []
    }

    # Apply filters using index fields only (no file I/O needed)
    let filtered = $all_entries | where {|entry|
        let date_ok = if $date != "" {
            ($entry.date_dir? | default "") == $date
        } else { true }

        let str_ok = if $filter == "" {
            true
        } else if ($filter | str starts-with "status:") {
            let want = ($filter | str replace "status:" "" | into int)
            ($entry.status? | default 0) == $want
        } else if ($filter | str starts-with "method:") {
            let want = ($filter | str replace "method:" "")
            ascii-equal-ignore-case ($entry.method? | default "") $want
        } else {
            ($entry.url? | default "") | str contains $filter
        }

        $date_ok and $str_ok
    }

    if ($filtered | is-empty) {
        print "(ansi yellow)No matching history entries(ansi reset)"
        return []
    }

    $filtered | first $limit | each {|entry|
        {
            id: ($entry.id? | default "")
            timestamp: (history-list-time ($entry.timestamp? | default null))
            method: ($entry.method? | default "???")
            status: ($entry.status? | default 0)
            url: ($entry.url? | default "" | str substring 0..50)
            time_ms: ($entry.time_ms? | default 0)
        }
    }
}

# Show detailed history entry
export def "api history show" [
    id: string  # History entry ID or partial ID
] {
    let entry = (resolve-history-entry $id)

    if $entry == null {
        fail-command $"History entry '($id)' not found"
    }

    $entry
}

# Resolve exact IDs first, then accept only unique partial matches.
def resolve-history-entry [id: string] {
    let dir = (get-history-dir)

    if not ($dir | path exists) {
        return null
    }

    # Get all history files
    let subdirs = try { ls $dir | where type == dir | get name } catch { [] }
    let all_files = $subdirs | each {|subdir|
        try { ls $subdir | where name =~ '\.nuon$' | get name | sort } catch { [] }
    } | flatten | sort | each {|path|
        {path: $path, id: ($path | path parse | get stem)}
    }

    # Try exact match first
    let exact_matches = $all_files | where {|file| $file.id == $id }
    let matches = if ($exact_matches | is-empty) {
        $all_files | where {|file| $file.id | str contains $id }
    } else {
        $exact_matches
    }
    let match_count = ($matches | length)
    if $match_count == 0 {
        return null
    }
    if $match_count > 1 {
        fail-command ("History ID '" + $id + "' is ambiguous (" + ($match_count | into string) + " matches); use a longer or exact ID")
    }

    open ($matches | first | get path)
}

# Resend a request from history
export def "api history resend" [
    id: string               # History entry ID
    --environment (-e): string = ""  # Override environment
    --auth (-a): record = {} # Authentication config (e.g., {type: bearer, token_ref: mytoken})
    --headers (-H): record # Replace stored headers (required when sensitive headers were redacted)
    --raw (-r)               # Return raw result
    --dry-run (-d)           # Output curl command instead of executing
] {
    let entry = (resolve-history-entry $id)

    if $entry == null {
        fail-command $"History entry '($id)' not found"
    }

    # Switch environment if specified
    # Note: global env concept not supported; flag is kept for backward compat but is a no-op
    # (was: api env use $environment — command does not exist)

    let explicit_auth = not ($auth | is-empty)
    let stored_auth = ($entry.request.auth? | default null)
    let effective_auth = if $explicit_auth {
        $auth
    } else if $stored_auth == null {
        {}
    } else if ($stored_auth.replayable? | default false) == true {
        $stored_auth
    } else {
        let auth_type = ($stored_auth.type? | default "inline")
        fail-command $"History entry '($id)' used non-replayable ($auth_type) authentication; pass --auth to resend it"
    }
    let explicit_headers = $headers != null
    if (($entry.request.headers_replayable? | default true) == false) and (not $explicit_headers) {
        fail-command $"History entry '($id)' contains redacted sensitive headers; pass --headers to resend it"
    }
    let effective_headers = if $explicit_headers { $headers } else { $entry.request.headers }

    require-curl-capability --dry-run=$dry_run

    # Rebuild body record from stored body (avoid double-encoding)
    let body_record = if ($entry.request.body? | default null) != null {
        if ($entry.request.body | describe | str starts-with "record") or ($entry.request.body | describe | str starts-with "list") {
            $entry.request.body
        } else {
            # body stored as string — decode it
            try { $entry.request.body | into string | from json } catch { {} }
        }
    } else {
        {}
    }

    # Execute request — pass body as record (api request handles to-json internally)
    api request -m $entry.request.method $entry.request.url -b $body_record -H $effective_headers -a $effective_auth --raw=$raw --dry-run=$dry_run
}

# Search history — uses index for URL/method; falls back to files for body search
export def "api history search" [
    query: string            # Search query
    --limit (-l): int = 20   # Max results
] {
    validate-history-limit $limit
    if $limit == 0 { return [] }

    let dir = (get-history-dir)

    if not ($dir | path exists) {
        print "(ansi yellow)No history found(ansi reset)"
        return []
    }

    ensure-history-index

    let all_entries = (load-history-index | sort-history-entries)
    if ($all_entries | is-empty) {
        print $"(ansi yellow)No results for '($query)'(ansi reset)"
        return []
    }

    # Search URL and method from index (fast path)
    let index_matches = $all_entries | where {|entry|
        let url_match = ($entry.url? | default "") | str contains -i $query
        let method_match = ($entry.method? | default "") | str contains -i $query
        $url_match or $method_match
    } | first $limit

    if not ($index_matches | is-empty) {
        return ($index_matches | each {|entry|
            {
                id: ($entry.id? | default "")
                timestamp: (history-search-time ($entry.timestamp? | default null))
                method: ($entry.method? | default "???")
                status: ($entry.status? | default 0)
                url: ($entry.url? | default "" | str substring 0..50)
            }
        })
    }

    mut results = []

    # Fall back to body search in the same canonical order as index searches.
    for summary in $all_entries {
        if ($results | length) >= $limit { break }

        let entry = try { open (history-entry-path $summary) } catch { continue }

        let body_text = if ($entry.response.body? | default null) != null {
            try { $entry.response.body | to json } catch { "" }
        } else { "" }

        if ($body_text | str contains -i $query) {
            $results = ($results | append {
                id: $entry.id
                timestamp: (history-search-time ($entry.timestamp? | default null))
                method: ($entry.request.method? | default "???")
                status: ($entry.response.status? | default 0)
                url: ($entry.request.url? | default "" | str substring 0..50)
            })
        }
    }

    if ($results | is-empty) {
        print $"(ansi yellow)No results for '($query)'(ansi reset)"
        return []
    }

    $results
}

# Clear old history entries
export def "api history clear" [
    --before (-b): string = ""  # Clear entries before date (YYYY-MM-DD)
    --all (-a)                  # Clear all history
    --force (-f)                # Skip confirmation
] {
    let dir = (get-history-dir)

    if not ($dir | path exists) {
        print "(ansi yellow)No history to clear(ansi reset)"
        return
    }

    if $all {
        if not $force {
            let confirm = (input "Clear ALL history? [y/N] ")
            if $confirm !~ "^[yY]" {
                print "Cancelled"
                return
            }
        }

        rm -rf $dir
        mkdir $dir
        print "(ansi green)All history cleared(ansi reset)"
        return
    }

    if $before != "" {
        let cutoff = ($before | into datetime)
        let cleared = (clear-history-before-cutoff $dir $cutoff)
        print $"(ansi green)Cleared ($cleared) days of history before ($before)(ansi reset)"
        return
    }

    # Default: clear entries older than retention period
    let root = ($env.API_ROOT? | default (pwd))
    let config_path = ($root | path join "config.nuon")
    let retention_days = if ($config_path | path exists) {
        (open $config_path).history_retention_days? | default 30
    } else {
        30
    }

    let cutoff = ((date now) - ($retention_days | into duration --unit day))
    let cleared = (clear-history-before-cutoff $dir $cutoff)
    print $"(ansi green)Cleared ($cleared) days of history older than ($retention_days) days(ansi reset)"
}

# Export history to file
export def "api history export" [
    --format (-f): string = "json"  # Export format: json, csv
    --output (-o): string = ""      # Output file path
    --limit (-l): int = 100         # Max entries
] {
    validate-history-limit $limit
    let supported_formats = ["json" "csv"]
    if $format not-in $supported_formats {
        fail-command $"Unsupported history export format '($format)'. Expected one of: ($supported_formats | str join ', ')."
    }

    let entries = if $limit == 0 {
        []
    } else {
        let dir = (get-history-dir)
        if not ($dir | path exists) {
            print "(ansi yellow)No history to export(ansi reset)"
            return
        }
        ensure-history-index
        load-history-index
        | sort-history-entries
        | first $limit
        | each {|summary|
            try { open (history-entry-path $summary) } catch { null }
        }
        | where {|entry| $entry != null }
    }

    let output_content = match $format {
        "json" => ($entries | to json)
        "csv" => {
            let rows = $entries | each {|e|
                {
                    id: ($e.id? | default "")
                    timestamp: ($e.timestamp? | default "")
                    method: ($e.request?.method? | default "")
                    url: ($e.request?.url? | default "")
                    status: ($e.response?.status? | default 0)
                    time_ms: ($e.response?.time_ms? | default 0)
                }
            }
            if ($rows | is-empty) {
                "id,timestamp,method,url,status,time_ms"
            } else {
                $rows | to csv
            }
        }
        _ => { fail-command $"Unsupported history export format '($format)'" }
    }

    if $output != "" {
        $output_content | save $output
        print $"(ansi green)Exported ($entries | length) entries to ($output)(ansi reset)"
    } else {
        print $output_content
    }
}

# Get history entry by ID (returns record)
export def "api history get" [id: string] {
    resolve-history-entry $id
}
