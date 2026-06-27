# History Module
# Saves and manages request/response history

# Get history directory
def get-history-dir [] {
    let root = ($env.API_ROOT? | default (pwd))
    $root | path join "history"
}

# Get history index file path (B1)
def get-history-index-path [] {
    (get-history-dir) | path join "index.nuon"
}

# Load history index — list of summary entries (B1)
def load-history-index [] {
    let path = (get-history-index-path)
    if ($path | path exists) {
        try { open $path } catch { [] }
    } else {
        []
    }
}

# Append one summary entry to the history index (B1)
def append-to-history-index [summary: record] {
    let path = (get-history-index-path)
    let existing = (load-history-index)
    ($existing | append $summary) | to nuon | save -f $path
}

# Rebuild the full history index by scanning all date dirs + files (B1)
export def "api history rebuild-index" [] {
    let dir = (get-history-dir)
    if not ($dir | path exists) { return [] }

    let subdirs = try { ls $dir | where type == dir | get name } catch { [] }
    let entries = $subdirs | each {|subdir|
        let date_dir = ($subdir | path basename)
        (try { ls $subdir | where name =~ '\.nuon$' | get name } catch { [] })
        | each {|file|
            try {
                let e = (open $file)
                {
                    id: ($e.id? | default "")
                    timestamp: ($e.timestamp? | default "")
                    method: ($e.request?.method? | default "")
                    url: ($e.request?.url? | default "")
                    status: ($e.response?.status? | default 0)
                    time_ms: ($e.response?.time_ms? | default 0)
                    date_dir: $date_dir
                }
            } catch { null }
        }
        | where {|e| $e != null }
    } | flatten | sort-by timestamp -r

    let path = (get-history-index-path)
    $entries | to nuon | save -f $path
    print $"(ansi green)Index rebuilt: ($entries | length) entries(ansi reset)"
    $entries
}

# Ensure history index exists; auto-rebuild if missing (B1)
def ensure-history-index [] {
    let path = (get-history-index-path)
    if not ($path | path exists) {
        let dir = (get-history-dir)
        if ($dir | path exists) {
            # Silently rebuild
            let subdirs = try { ls $dir | where type == dir | get name } catch { [] }
            let entries = $subdirs | each {|subdir|
                let date_dir = ($subdir | path basename)
                (try { ls $subdir | where name =~ '\.nuon$' | get name } catch { [] })
                | each {|file|
                    try {
                        let e = (open $file)
                        {
                            id: ($e.id? | default "")
                            timestamp: ($e.timestamp? | default "")
                            method: ($e.request?.method? | default "")
                            url: ($e.request?.url? | default "")
                            status: ($e.response?.status? | default 0)
                            time_ms: ($e.response?.time_ms? | default 0)
                            date_dir: $date_dir
                        }
                    } catch { null }
                }
                | where {|e| $e != null }
            } | flatten | sort-by timestamp -r
            $entries | to nuon | save -f $path
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

# Generate history entry ID
def generate-history-id [] {
    let now = (date now)
    let date_part = ($now | format date "%Y%m%d-%H%M%S")
    let random_part = (random chars --length 6)
    $"($date_part)-($random_part)"
}

# Save request/response to history
export def "api history save" [
    request: record    # Request details
    response: record   # Response details
] {
    let dir = (ensure-history-dir)
    let date_dir = ($dir | path join (date now | format date "%Y-%m-%d"))

    if not ($date_dir | path exists) {
        mkdir $date_dir
    }

    let id = (generate-history-id)

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
        timestamp: (date now | format date "%Y-%m-%dT%H:%M:%SZ")
        environment: $current_env
        request: $request
        response: $response
    }

    let file_name = $"($id).nuon"
    let file_path = ($date_dir | path join $file_name)

    $entry | to nuon | save $file_path

    # Update history index (B1)
    append-to-history-index {
        id: $id
        timestamp: $entry.timestamp
        method: ($request.method? | default "")
        url: ($request.url? | default "")
        status: ($response.status? | default 0)
        time_ms: ($response.time_ms? | default 0)
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
    let dir = (get-history-dir)

    if not ($dir | path exists) {
        print "(ansi yellow)No history found(ansi reset)"
        return []
    }

    # Ensure index exists (auto-build from files if needed)
    ensure-history-index

    # Load from index — already sorted newest first
    let all_entries = (load-history-index)

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
            let want = ($filter | str replace "method:" "" | str upcase)
            ($entry.method? | default "") == $want
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
            timestamp: (($entry.timestamp? | default "") | str substring 11..19)
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
    let entry = (find-history-entry $id)

    if $entry == null {
        print $"(ansi red)History entry '($id)' not found(ansi reset)"
        return null
    }

    $entry
}

# Find history entry by ID or partial ID
def find-history-entry [id: string] {
    let dir = (get-history-dir)

    if not ($dir | path exists) {
        return null
    }

    # Get all history files
    let subdirs = try { ls $dir | where type == dir | get name } catch { [] }
    let all_files = $subdirs | each {|subdir|
        try { ls $subdir | where name =~ '\.nuon$' | get name } catch { [] }
    } | flatten

    # Try exact match first
    let exact_match = $all_files | where {|f| ($f | path basename) == $"($id).nuon" }
    if not ($exact_match | is-empty) {
        return (open ($exact_match | first))
    }

    # Try partial match
    let partial_match = $all_files | where {|f| ($f | path basename) | str contains $id }
    if ($partial_match | is-empty) {
        return null
    }

    open ($partial_match | first)
}

# Resend a request from history
export def "api history resend" [
    id: string               # History entry ID
    --environment (-e): string = ""  # Override environment
    --auth (-a): record = {} # Authentication config (e.g., {type: bearer, token_ref: mytoken})
    --raw (-r)               # Return raw result
    --dry-run (-d)           # Output curl command instead of executing
] {
    let entry = (find-history-entry $id)

    if $entry == null {
        print $"(ansi red)History entry '($id)' not found(ansi reset)"
        return null
    }

    # Switch environment if specified
    # Note: global env concept not supported; flag is kept for backward compat but is a no-op
    # (was: api env use $environment — command does not exist)

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

    if not $dry_run {
        print $"(ansi dark_gray)Resending: ($entry.request.method) ($entry.request.url)(ansi reset)"
    }

    # Execute request — pass body as record (api request handles to-json internally)
    api request -m $entry.request.method $entry.request.url -b $body_record -H $entry.request.headers -a $auth --raw=$raw --dry-run=$dry_run
}

# Search history — uses index for URL/method; falls back to files for body search
export def "api history search" [
    query: string            # Search query
    --limit (-l): int = 20   # Max results
] {
    let dir = (get-history-dir)

    if not ($dir | path exists) {
        print "(ansi yellow)No history found(ansi reset)"
        return []
    }

    ensure-history-index

    let all_entries = (load-history-index)
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
                timestamp: (($entry.timestamp? | default "") | str substring 0..19)
                method: ($entry.method? | default "???")
                status: ($entry.status? | default 0)
                url: ($entry.url? | default "" | str substring 0..50)
            }
        })
    }

    # Fall back to body search (open files, slow path)
    let subdirs = try { ls $dir | where type == dir | get name } catch { [] }
    let files = $subdirs | each {|subdir|
        try { ls $subdir | where name =~ '\.nuon$' | get name } catch { [] }
    } | flatten | sort -r

    mut results = []

    for file in $files {
        if ($results | length) >= $limit { break }

        let entry = try { open $file } catch { continue }

        let body_text = if ($entry.response.body? | default null) != null {
            try { $entry.response.body | to json } catch { "" }
        } else { "" }

        if ($body_text | str contains -i $query) {
            $results = ($results | append {
                id: $entry.id
                timestamp: ($entry.timestamp | str substring 0..19)
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
        let dirs = ls $dir | where type == dir

        mut cleared = 0

        for d in $dirs {
            let dir_date = try {
                $d.name | path basename | into datetime
            } catch {
                continue
            }

            if $dir_date < $cutoff {
                rm -rf $d.name
                $cleared = $cleared + 1
            }
        }

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
    let dirs = ls $dir | where type == dir

    mut cleared = 0

    for d in $dirs {
        let dir_date = try {
            $d.name | path basename | into datetime
        } catch {
            continue
        }

        if $dir_date < $cutoff {
            rm -rf $d.name
            $cleared = $cleared + 1
        }
    }

    print $"(ansi green)Cleared ($cleared) days of history older than ($retention_days) days(ansi reset)"
}

# Export history to file
export def "api history export" [
    --format (-f): string = "json"  # Export format: json, csv
    --output (-o): string = ""      # Output file path
    --limit (-l): int = 100         # Max entries
] {
    let dir = (get-history-dir)

    if not ($dir | path exists) {
        print "(ansi yellow)No history to export(ansi reset)"
        return
    }

    let subdirs = try { ls $dir | where type == dir | get name } catch { [] }
    let files = $subdirs | each {|subdir|
        try { ls $subdir | where name =~ '\.nuon$' | get name } catch { [] }
    } | flatten | sort -r | first $limit

    let entries = $files | each {|file|
        try {
            open $file
        } catch {
            null
        }
    } | where {|e| $e != null }

    let output_content = match $format {
        "json" => ($entries | to json)
        "csv" => {
            $entries | each {|e|
                {
                    id: $e.id
                    timestamp: $e.timestamp
                    method: $e.request.method
                    url: $e.request.url
                    status: $e.response.status
                    time_ms: $e.response.time_ms
                }
            } | to csv
        }
        _ => {
            print $"(ansi red)Unknown format: ($format)(ansi reset)"
            return
        }
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
    find-history-entry $id
}
