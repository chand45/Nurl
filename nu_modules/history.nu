# History Module
# Saves and manages request/response history

# Get history directory
def get-history-dir [] {
    let root = ($env.API_ROOT? | default (pwd))
    $root | path join "history" | str replace -a '\\' '/'
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

    $id
}

# List history entries
export def "api history list" [
    --limit (-l): int = 20       # Number of entries to show
    --filter (-f): string = ""   # Filter by method, status, or URL
    --date (-d): string = ""     # Filter by date (YYYY-MM-DD)
] {
    let dir = (get-history-dir)

    if not ($dir | path exists) {
        print "(ansi yellow)No history found(ansi reset)"
        return []
    }

    # Get all history files using ls instead of glob for Windows compatibility
    let files = if $date != "" {
        let date_dir = ($dir | path join $date)
        if ($date_dir | path exists) {
            try { ls ($date_dir) | where name =~ '\.nuon$' | get name | sort -r } catch { [] }
        } else {
            []
        }
    } else {
        # Get all nuon files from all date subdirectories
        let subdirs = try { ls $dir | where type == dir | get name } catch { [] }
        $subdirs | each {|subdir|
            try { ls $subdir | where name =~ '\.nuon$' | get name } catch { [] }
        } | flatten | sort -r
    }

    if ($files | is-empty) {
        print "(ansi yellow)No history found(ansi reset)"
        return []
    }

    mut entries = []

    for file in $files {
        if ($entries | length) >= $limit {
            break
        }

        let entry = try {
            open $file
        } catch {
            continue
        }

        # Apply filters
        let matches = if $filter == "" {
            true
        } else if ($filter | str starts-with "status:") {
            let status = ($filter | str replace "status:" "" | into int)
            ($entry.response.status? | default 0) == $status
        } else if ($filter | str starts-with "method:") {
            let method = ($filter | str replace "method:" "" | str upcase)
            ($entry.request.method? | default "") == $method
        } else {
            # General text search in URL
            ($entry.request.url? | default "") | str contains $filter
        }

        if $matches {
            $entries = ($entries | append $entry)
        }
    }

    if ($entries | is-empty) {
        print "(ansi yellow)No matching history entries(ansi reset)"
        return []
    }

    # Format for display
    $entries | each {|entry|
        let status_color = if ($entry.response.status? | default 0) >= 200 and ($entry.response.status? | default 0) < 300 {
            "green"
        } else if ($entry.response.status? | default 0) >= 400 {
            "red"
        } else {
            "yellow"
        }

        {
            id: $entry.id
            timestamp: ($entry.timestamp | str substring 11..19)
            method: ($entry.request.method? | default "???")
            status: ($entry.response.status? | default 0)
            url: ($entry.request.url? | default "" | str substring 0..50)
            time_ms: ($entry.response.time_ms? | default 0)
        }
    } | table
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

    print $"(ansi blue)History Entry: ($entry.id)(ansi reset)"
    print $"Timestamp: ($entry.timestamp)"
    print $"Environment: ($entry.environment? | default 'none')"
    print ""

    print $"(ansi yellow)Request:(ansi reset)"
    print $"  Method: ($entry.request.method)"
    print $"  URL: ($entry.request.url)"

    if ($entry.request.headers | is-not-empty) {
        print "  Headers:"
        $entry.request.headers | transpose key value | each {|h|
            print $"    ($h.key): ($h.value)"
        }
    }

    if ($entry.request.body? | default null) != null {
        print "  Body:"
        if ($entry.request.body | describe | str starts-with "record") or ($entry.request.body | describe | str starts-with "list") {
            $entry.request.body | to json | lines | each {|line| print $"    ($line)" }
        } else {
            print $"    ($entry.request.body)"
        }
    }

    print ""
    let status_color = if $entry.response.status >= 200 and $entry.response.status < 300 {
        "green"
    } else if $entry.response.status >= 400 {
        "red"
    } else {
        "yellow"
    }

    print $"(ansi yellow)Response:(ansi reset)"
    print $"  Status: (ansi $status_color)($entry.response.status) ($entry.response.status_text)(ansi reset)"
    print $"  Time: ($entry.response.time_ms)ms"
    print $"  Size: ($entry.response.size_bytes) bytes"

    if ($entry.response.headers | is-not-empty) {
        print "  Headers:"
        $entry.response.headers | transpose key value | each {|h|
            print $"    ($h.key): ($h.value)"
        }
    }

    if ($entry.response.body? | default null) != null {
        print "  Body:"
        if ($entry.response.body | describe | str starts-with "record") or ($entry.response.body | describe | str starts-with "list") {
            $entry.response.body | to json | lines | each {|line| print $"    ($line)" }
        } else {
            print $"    ($entry.response.body)"
        }
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
    --raw (-r)               # Return raw result
] {
    let entry = (find-history-entry $id)

    if $entry == null {
        print $"(ansi red)History entry '($id)' not found(ansi reset)"
        return null
    }

    # Switch environment if specified
    if $environment != "" {
        api env use $environment
    }

    # Rebuild body string
    let body = if ($entry.request.body? | default null) != null {
        if ($entry.request.body | describe | str starts-with "record") or ($entry.request.body | describe | str starts-with "list") {
            $entry.request.body | to json
        } else {
            $entry.request.body | into string
        }
    } else {
        ""
    }

    print $"(ansi dark_gray)Resending: ($entry.request.method) ($entry.request.url)(ansi reset)"

    # Execute request
    api request -m $entry.request.method $entry.request.url -b $body -H $entry.request.headers --raw=$raw
}

# Search history
export def "api history search" [
    query: string            # Search query
    --limit (-l): int = 20   # Max results
] {
    let dir = (get-history-dir)

    if not ($dir | path exists) {
        print "(ansi yellow)No history found(ansi reset)"
        return []
    }

    let subdirs = try { ls $dir | where type == dir | get name } catch { [] }
    let files = $subdirs | each {|subdir|
        try { ls $subdir | where name =~ '\.nuon$' | get name } catch { [] }
    } | flatten | sort -r

    mut results = []

    for file in $files {
        if ($results | length) >= $limit {
            break
        }

        let entry = try {
            open $file
        } catch {
            continue
        }

        # Search in URL, method, status, and response body
        let url_match = ($entry.request.url? | default "") | str contains -i $query
        let method_match = ($entry.request.method? | default "") | str contains -i $query

        let body_text = if ($entry.response.body? | default null) != null {
            try { $entry.response.body | to json } catch { "" }
        } else {
            ""
        }
        let body_match = $body_text | str contains -i $query

        if $url_match or $method_match or $body_match {
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
    } else {
        $results | table
    }
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
