# HTTP Request Module
# Core HTTP request functionality using curl

use log.nu *

# Internal function to save history (avoids module scoping issues)
def save-to-history [request: record, response: record] {
    let root = ($env.API_ROOT? | default (pwd))
    let history_dir = ($root | path join "history")

    if not ($history_dir | path exists) {
        mkdir $history_dir
    }

    let date_dir = ($history_dir | path join (date now | format date "%Y-%m-%d"))
    if not ($date_dir | path exists) {
        mkdir $date_dir
    }

    let id = $"(date now | format date '%Y%m%d-%H%M%S')-(random chars --length 6)"
    let config_path = ($root | path join "config.nuon")
    let current_env = if ($config_path | path exists) {
        (open $config_path).default_environment? | default null
    } else { null }

    let entry = {
        id: $id
        timestamp: (date now | format date "%Y-%m-%dT%H:%M:%SZ")
        environment: $current_env
        request: $request
        response: $response
    }

    $entry | to nuon | save ($date_dir | path join $"($id).nuon")
    $id
}

# Get default headers from config
def get-default-headers [] {
    let root = ($env.API_ROOT? | default (pwd))
    let config_path = ($root | path join "config.nuon")

    if ($config_path | path exists) {
        (open $config_path).default_headers? | default {}
    } else {
        {
            "Content-Type": "application/json"
            "Accept": "application/json"
        }
    }
}

# Get timeout from config
def get-timeout [] {
    let root = ($env.API_ROOT? | default (pwd))
    let config_path = ($root | path join "config.nuon")

    if ($config_path | path exists) {
        (open $config_path).timeout_seconds? | default 30
    } else {
        30
    }
}

# Build curl command arguments
def build-curl-args [
    method: string
    url: string
    headers: record
    body?: string
    auth?: record
] {
    mut args = [
        "-s"                    # Silent mode
        "-S"                    # Show errors
        "-w" "\n---RESPONSE_META---\n%{http_code}\n%{time_total}\n%{size_download}"
        "-X" $method
        "--max-time" (get-timeout | into string)
    ]

    # Add headers
    for header in ($headers | transpose key value) {
        $args = ($args | append ["-H" $"($header.key): ($header.value)"])
    }

    # Add authentication if provided
    if $auth != null {
        match ($auth.type? | default "none") {
            "bearer" => {
                $args = ($args | append ["-H" $"Authorization: Bearer ($auth.token)"])
            }
            "basic" => {
                $args = ($args | append ["-u" $"($auth.username):($auth.password)"])
            }
            "apikey_header" => {
                $args = ($args | append ["-H" $"($auth.header_name): ($auth.key)"])
            }
            "apikey_query" => {
                # Will be handled in URL
            }
            _ => {}
        }
    }

    # Add body if provided
    if $body != null and $body != "" {
        $args = ($args | append ["-d" $body])
    }

    # Include response headers in output
    $args = ($args | append ["-i"])

    $args
}

# Build curl arguments for display (cleaner output for --dry-run)
def build-curl-args-for-display [
    method: string
    url: string
    headers: record
    body?: string
    auth?: record
] {
    mut args = [
        "-X" $method
    ]

    # Add headers
    for header in ($headers | transpose key value) {
        $args = ($args | append ["-H" $"($header.key): ($header.value)"])
    }

    # Add authentication if provided
    if $auth != null {
        match ($auth.type? | default "none") {
            "bearer" => {
                $args = ($args | append ["-H" $"Authorization: Bearer ($auth.token)"])
            }
            "basic" => {
                $args = ($args | append ["-u" $"($auth.username):($auth.password)"])
            }
            "apikey_header" => {
                $args = ($args | append ["-H" $"($auth.header_name): ($auth.key)"])
            }
            "apikey_query" => {
                # Will be handled in URL
            }
            _ => {}
        }
    }

    # Add body if provided
    if $body != null and $body != "" {
        $args = ($args | append ["-d" $body])
    }

    $args
}

# Convert curl arguments to a copyable shell command string
def curl-args-to-string [
    args: list      # The curl arguments list
    url: string     # The URL to request
] {
    mut parts = ["curl"]

    for arg in $args {
        # Check if argument needs quoting
        let needs_quote = ($arg | str contains "'") or ($arg | str contains '"') or ($arg | str contains " ") or ($arg | str contains "$") or ($arg | str contains "&") or ($arg | str contains "?") or ($arg | str contains "=") or ($arg | str contains ";") or ($arg | str contains "(") or ($arg | str contains ")") or ($arg | str contains "{") or ($arg | str contains "}")

        if $needs_quote {
            if ($arg | str contains "'") {
                # Escape single quotes using '\'' pattern
                let escaped = ($arg | str replace --all "'" "'\\''")
                $parts = ($parts | append $"'($escaped)'")
            } else {
                $parts = ($parts | append $"'($arg)'")
            }
        } else {
            $parts = ($parts | append $arg)
        }
    }

    # Add URL at the end (always quote it for safety)
    if ($url | str contains "'") {
        let escaped_url = ($url | str replace --all "'" "'\\''")
        $parts = ($parts | append $"'($escaped_url)'")
    } else {
        $parts = ($parts | append $"'($url)'")
    }

    $parts | str join " "
}

# Parse curl response output
def parse-curl-response [output: string] {
    # Split response into headers and body
    let parts = ($output | split row "---RESPONSE_META---")
    let response_part = ($parts | first | str trim)
    let meta_part = if ($parts | length) > 1 { $parts | get 1 | str trim } else { "" }

    # Parse meta information
    let meta_lines = ($meta_part | lines)
    let status_code = if ($meta_lines | length) > 0 {
        $meta_lines | first | into int
    } else { 0 }
    let time_total = if ($meta_lines | length) > 1 {
        $meta_lines | get 1 | into float
    } else { 0.0 }
    let size = if ($meta_lines | length) > 2 {
        $meta_lines | get 2 | into int
    } else { 0 }

    # Split headers from body (separated by empty line)
    let header_body_split = ($response_part | split row "\r\n\r\n")
    let headers_raw = if ($header_body_split | length) > 0 {
        $header_body_split | first
    } else { "" }

    # Get body (join remaining parts in case body contains empty lines)
    let body_raw = if ($header_body_split | length) > 1 {
        $header_body_split | skip 1 | str join "\r\n\r\n"
    } else { "" }

    # Parse headers
    let header_lines = ($headers_raw | lines | skip 1)  # Skip status line
    let headers = $header_lines
        | each {|line|
            let parts = ($line | split row ":" | str trim)
            if ($parts | length) >= 2 {
                let key = ($parts | first)
                let value = ($parts | skip 1 | str join ":")
                { $key: ($value | str trim) }
            } else {
                {}
            }
        }
        | reduce -f {} {|it, acc| $acc | merge $it }

    # Try to parse body as JSON
    let body = try {
        $body_raw | from json
    } catch {
        $body_raw
    }

    # Determine status text
    let status_text = match $status_code {
        200 => "OK"
        201 => "Created"
        204 => "No Content"
        400 => "Bad Request"
        401 => "Unauthorized"
        403 => "Forbidden"
        404 => "Not Found"
        500 => "Internal Server Error"
        _ => "Unknown"
    }

    {
        status: $status_code
        status_text: $status_text
        headers: $headers
        body: $body
        time_ms: (($time_total * 1000) | math round)
        size_bytes: $size
    }
}

# Execute HTTP request
def execute-request [
    method: string
    url: string
    --headers (-H): record = {}
    --body (-b): string = ""
    --auth (-a): record = {}
    --no-interpolate   # Skip variable interpolation
    --no-history       # Don't save to history
    --dry-run (-d)     # Output curl command instead of executing
    --collection (-c): string = ""   # Collection context for variable resolution
    --extra-vars (-v): record = {}   # Extra variables for interpolation
] {
    # Merge default headers with provided headers
    let all_headers = (get-default-headers | merge $headers)

    # Interpolate variables with collection context
    let final_url = if $no_interpolate {
        $url
    } else {
        api vars interpolate $url -c $collection -v $extra_vars
    }

    let final_headers = if $no_interpolate {
        $all_headers
    } else {
        api vars interpolate-record $all_headers -c $collection -v $extra_vars
    }

    let final_body = if $no_interpolate or $body == "" {
        $body
    } else {
        api vars interpolate $body -c $collection -v $extra_vars
    }

    # Handle API key in query string
    mut request_url = $final_url
    if ($auth.type? == "apikey_query") {
        let separator = if ($request_url | str contains "?") { "&" } else { "?" }
        $request_url = $"($request_url)($separator)($auth.param_name)=($auth.key)"
    }

    # Build curl arguments
    let curl_args = (build-curl-args $method $request_url $final_headers $final_body $auth)

    # Handle dry-run mode - output curl command instead of executing
    if $dry_run {
        let display_args = (build-curl-args-for-display $method $request_url $final_headers $final_body $auth)
        let curl_command = (curl-args-to-string $display_args $request_url)
        print $curl_command
        return { dry_run: true, command: $curl_command }
    }

    # Execute curl
    let start_time = (date now)
    let output = (curl ...$curl_args $request_url | complete)

    if $output.exit_code != 0 {
        log error $"Request failed: ($output.stderr)"
        return null
    }

    # Parse response
    let response = (parse-curl-response $output.stdout)

    # Build request record for history
    let request_record = {
        method: $method
        url: $final_url
        headers: $final_headers
        body: (if $final_body != "" { try { $final_body | from json } catch { $final_body } } else { null })
    }

    # Save to history
    if not $no_history {
        save-to-history $request_record $response
    }

    # Return formatted response
    {
        request: $request_record
        response: $response
        timestamp: ($start_time | format date "%Y-%m-%dT%H:%M:%SZ")
    }
}

# Format and display response
def display-response [result: record] {
    let response = $result.response

    # Log status line (only shown with --debug)
    log status $response.status $response.status_text $response.time_ms $response.size_bytes

    # Print response body (only shown with --debug)
    if $response.body != null {
        let body_type = ($response.body | describe)
        if ($body_type | str starts-with "record") or ($body_type | str starts-with "list") or ($body_type | str starts-with "table") {
            log debug ($response.body | to json)
        } else {
            log debug (try { $response.body | into string } catch { $response.body | to json })
        }
    }
}

# GET request
export def "api get" [
    url: string                    # URL to request
    --headers (-H): record = {}    # Additional headers
    --auth (-a): record = {}       # Authentication config
    --raw (-r)                     # Return raw result without display
    --no-history                   # Don't save to history
    --dry-run (-d)                 # Output curl command instead of executing
    --debug                        # Show verbose output
] {
    if $debug { $env.API_DEBUG = true }
    let result = (execute-request "GET" $url -H $headers -a $auth --no-history=$no_history --dry-run=$dry_run)

    if $result == null {
        if $debug { $env.API_DEBUG = false }
        return null
    }

    if ($result.dry_run? | default false) {
        if $debug { $env.API_DEBUG = false }
        return $result
    }

    if $raw {
        if $debug { $env.API_DEBUG = false }
        $result
    } else {
        display-response $result
        if $debug { $env.API_DEBUG = false }
        $result
    }
}

# POST request
export def "api post" [
    url: string                    # URL to request
    --body (-b): string = ""       # Request body (JSON string)
    --headers (-H): record = {}    # Additional headers
    --auth (-a): record = {}       # Authentication config
    --raw (-r)                     # Return raw result without display
    --no-history                   # Don't save to history
    --dry-run (-d)                 # Output curl command instead of executing
    --debug                        # Show verbose output
] {
    if $debug { $env.API_DEBUG = true }
    let result = (execute-request "POST" $url -H $headers -b $body -a $auth --no-history=$no_history --dry-run=$dry_run)

    if $result == null {
        if $debug { $env.API_DEBUG = false }
        return null
    }

    if ($result.dry_run? | default false) {
        if $debug { $env.API_DEBUG = false }
        return $result
    }

    if $raw {
        if $debug { $env.API_DEBUG = false }
        $result
    } else {
        display-response $result
        if $debug { $env.API_DEBUG = false }
        $result
    }
}

# PUT request
export def "api put" [
    url: string                    # URL to request
    --body (-b): string = ""       # Request body (JSON string)
    --headers (-H): record = {}    # Additional headers
    --auth (-a): record = {}       # Authentication config
    --raw (-r)                     # Return raw result without display
    --no-history                   # Don't save to history
    --dry-run (-d)                 # Output curl command instead of executing
    --debug                        # Show verbose output
] {
    if $debug { $env.API_DEBUG = true }
    let result = (execute-request "PUT" $url -H $headers -b $body -a $auth --no-history=$no_history --dry-run=$dry_run)

    if $result == null {
        if $debug { $env.API_DEBUG = false }
        return null
    }

    if ($result.dry_run? | default false) {
        if $debug { $env.API_DEBUG = false }
        return $result
    }

    if $raw {
        if $debug { $env.API_DEBUG = false }
        $result
    } else {
        display-response $result
        if $debug { $env.API_DEBUG = false }
        $result
    }
}

# PATCH request
export def "api patch" [
    url: string                    # URL to request
    --body (-b): string = ""       # Request body (JSON string)
    --headers (-H): record = {}    # Additional headers
    --auth (-a): record = {}       # Authentication config
    --raw (-r)                     # Return raw result without display
    --no-history                   # Don't save to history
    --dry-run (-d)                 # Output curl command instead of executing
    --debug                        # Show verbose output
] {
    if $debug { $env.API_DEBUG = true }
    let result = (execute-request "PATCH" $url -H $headers -b $body -a $auth --no-history=$no_history --dry-run=$dry_run)

    if $result == null {
        if $debug { $env.API_DEBUG = false }
        return null
    }

    if ($result.dry_run? | default false) {
        if $debug { $env.API_DEBUG = false }
        return $result
    }

    if $raw {
        if $debug { $env.API_DEBUG = false }
        $result
    } else {
        display-response $result
        if $debug { $env.API_DEBUG = false }
        $result
    }
}

# DELETE request
export def "api delete" [
    url: string                    # URL to request
    --headers (-H): record = {}    # Additional headers
    --auth (-a): record = {}       # Authentication config
    --raw (-r)                     # Return raw result without display
    --no-history                   # Don't save to history
    --dry-run (-d)                 # Output curl command instead of executing
    --debug                        # Show verbose output
] {
    if $debug { $env.API_DEBUG = true }
    let result = (execute-request "DELETE" $url -H $headers -a $auth --no-history=$no_history --dry-run=$dry_run)

    if $result == null {
        if $debug { $env.API_DEBUG = false }
        return null
    }

    if ($result.dry_run? | default false) {
        if $debug { $env.API_DEBUG = false }
        return $result
    }

    if $raw {
        if $debug { $env.API_DEBUG = false }
        $result
    } else {
        display-response $result
        if $debug { $env.API_DEBUG = false }
        $result
    }
}

# Generic request with any method
export def "api request" [
    --method (-m): string = "GET"  # HTTP method
    url: string                    # URL to request
    --body (-b): string = ""       # Request body
    --headers (-H): record = {}    # Additional headers
    --auth (-a): record = {}       # Authentication config
    --raw (-r)                     # Return raw result without display
    --no-history                   # Don't save to history
    --dry-run (-d)                 # Output curl command instead of executing
    --debug                        # Show verbose output
] {
    if $debug { $env.API_DEBUG = true }
    let result = (execute-request $method $url -H $headers -b $body -a $auth --no-history=$no_history --dry-run=$dry_run)

    if $result == null {
        if $debug { $env.API_DEBUG = false }
        return null
    }

    if ($result.dry_run? | default false) {
        if $debug { $env.API_DEBUG = false }
        return $result
    }

    if $raw {
        if $debug { $env.API_DEBUG = false }
        $result
    } else {
        display-response $result
        if $debug { $env.API_DEBUG = false }
        $result
    }
}

# Send a saved request by name
export def "api send" [
    name: string                   # Request name (path in collection)
    --collection (-c): string = "" # Collection name
    --raw (-r)                     # Return raw result
    --vars (-v): record = {}       # Extra variables
    --dry-run (-d)                 # Output curl command instead of executing
    --debug                        # Show verbose output
] {
    if $debug { $env.API_DEBUG = true }
    let root = ($env.API_ROOT? | default (pwd))

    # Find request file and determine collection name
    mut coll_name = $collection
    let collection_path = if $collection != "" {
        $root | path join "collections" $collection
    } else {
        # Search in all collections
        let collections_dir = ($root | path join "collections")
        let colls = try { ls $collections_dir | where type == dir | get name } catch { [] }
        mut found_path = null
        for coll_path in $colls {
            let request_file = ($coll_path | path join "requests" $"($name).nuon")
            if ($request_file | path exists) {
                $found_path = $coll_path
                $coll_name = ($coll_path | path basename)
                break
            }
        }

        if $found_path == null {
            log error $"Request '($name)' not found"
            if $debug { $env.API_DEBUG = false }
            return null
        }

        $found_path
    }

    let request_path = if ($name | str ends-with ".nuon") {
        $collection_path | path join "requests" $name
    } else {
        $collection_path | path join "requests" $"($name).nuon"
    }

    if not ($request_path | path exists) {
        # Try direct path
        let direct_path = $root | path join "collections" $"($name).nuon"
        if not ($direct_path | path exists) {
            log error $"Request '($name)' not found"
            if $debug { $env.API_DEBUG = false }
            return null
        }
    }

    # Load request
    let request = (open $request_path)

    # Build headers
    let headers = ($request.headers? | default {})

    # Build body
    let body = if ($request.body?.content? | default null) != null {
        $request.body.content | to json
    } else {
        ""
    }

    # Build auth from request config
    let auth = if ($request.auth? | default null) != null {
        api auth get-config $request.auth
    } else {
        {}
    }

    # Execute request with collection context for variable resolution
    let result = (execute-request ($request.method? | default "GET") $request.url -H $headers -b $body -a $auth --dry-run=$dry_run -c $coll_name -v $vars)

    if $result == null {
        if $debug { $env.API_DEBUG = false }
        return null
    }

    if ($result.dry_run? | default false) {
        if $debug { $env.API_DEBUG = false }
        return $result
    }

    # Run tests if defined
    if ($request.tests? | default "") != "" {
        # Tests would be executed here
        log debug "Tests: not implemented yet"
    }

    # Extract chain variables if defined
    if ($request.chain?.extract? | default null) != null {
        mut extracted = {}
        for item in ($request.chain.extract | transpose key path) {
            let value = (api vars extract $result.response $item.path)
            if $value != null {
                $extracted = ($extracted | upsert $item.key $value)
            }
        }
        if not ($extracted | is-empty) {
            log debug $"Extracted: ($extracted | to nuon)"
        }
    }

    if $raw {
        if $debug { $env.API_DEBUG = false }
        $result
    } else {
        display-response $result
        if $debug { $env.API_DEBUG = false }
        $result
    }
}

# Create a new saved request
export def "api request create" [
    name: string                   # Request name
    method: string                 # HTTP method
    url: string                    # Request URL
    --headers (-H): record = {}    # Headers
    --body (-b): string = ""       # Body
    --collection (-c): string = "default"  # Collection name
    --debug                        # Show verbose output
] {
    if $debug { $env.API_DEBUG = true }
    let root = ($env.API_ROOT? | default (pwd))
    let collection_path = ($root | path join "collections" $collection)

    # Ensure collection exists
    if not ($collection_path | path exists) {
        mkdir $collection_path
        mkdir ($collection_path | path join "requests")
        mkdir ($collection_path | path join "environments")
        {
            name: $collection
            description: ""
            created_at: (date now | format date "%Y-%m-%dT%H:%M:%SZ")
        } | to nuon | save ($collection_path | path join "collection.nuon")
    }

    let requests_path = ($collection_path | path join "requests")
    if not ($requests_path | path exists) {
        mkdir $requests_path
    }

    let request_file = ($requests_path | path join $"($name).nuon")

    let body_content = if $body != "" {
        try {
            $body | from json
        } catch {
            $body
        }
    } else {
        null
    }

    {
        name: $name
        collection: $collection
        method: $method
        url: $url
        headers: $headers
        body: (if $body_content != null { { type: "json", content: $body_content } } else { null })
        auth: null
        pre_request: null
        tests: null
        chain: null
        created_at: (date now | format date "%Y-%m-%dT%H:%M:%SZ")
    } | to nuon | save $request_file

    print $"(ansi green)Request '($name)' created in collection '($collection)'(ansi reset)"
    if $debug { $env.API_DEBUG = false }
}

# List saved requests
export def "api request list" [
    --collection (-c): string = ""  # Filter by collection
    --debug                         # Show verbose output
] {
    if $debug { $env.API_DEBUG = true }
    let root = ($env.API_ROOT? | default (pwd))
    let collections_dir = ($root | path join "collections")

    if not ($collections_dir | path exists) {
        log warn "No collections found"
        if $debug { $env.API_DEBUG = false }
        return []
    }

    let requests = if $collection != "" {
        let requests_dir = ($collections_dir | path join $collection "requests")
        if ($requests_dir | path exists) {
            try { ls $requests_dir | where name =~ '\.nuon$' | get name } catch { [] } | each {|file|
                let req = (open $file)
                {
                    name: ($req.name? | default ($file | path basename | str replace ".nuon" ""))
                    collection: $collection
                    method: ($req.method? | default "GET")
                    url: ($req.url? | default "")
                }
            }
        } else { [] }
    } else {
        # Get all collections and their requests
        let colls = try { ls $collections_dir | where type == dir | get name } catch { [] }
        $colls | each {|coll_path|
            let coll_name = ($coll_path | path basename)
            let requests_dir = ($coll_path | path join "requests")
            if ($requests_dir | path exists) {
                try { ls $requests_dir | where name =~ '\.nuon$' | get name } catch { [] } | each {|file|
                    let req = (open $file)
                    {
                        name: ($req.name? | default ($file | path basename | str replace ".nuon" ""))
                        collection: $coll_name
                        method: ($req.method? | default "GET")
                        url: ($req.url? | default "")
                    }
                }
            } else { [] }
        } | flatten
    }

    if $debug { $env.API_DEBUG = false }

    if ($requests | is-empty) {
        print $"(ansi yellow)No requests found(ansi reset)"
    } else {
        $requests | table
    }
}

# Show details of a saved request
export def "api request show" [
    name: string                   # Request name
    --collection (-c): string = ""  # Collection name (searches all if not specified)
] {
    let root = ($env.API_ROOT? | default (pwd))
    let collections_dir = ($root | path join "collections")

    let request_file = if $collection != "" {
        # Search in specific collection
        $root | path join "collections" $collection "requests" $"($name).nuon"
    } else {
        # Search across all collections
        let colls = try { ls $collections_dir | where type == dir | get name } catch { [] }
        let found = $colls | each {|coll_path|
            let file = ($coll_path | path join "requests" $"($name).nuon")
            if ($file | path exists) { $file } else { null }
        } | where {|f| $f != null }
        if ($found | is-empty) { null } else { $found | first }
    }

    if $request_file == null or not ($request_file | path exists) {
        let scope = if $collection != "" { $"collection '($collection)'" } else { "any collection" }
        print $"(ansi red)Request '($name)' not found in ($scope)(ansi reset)"
        return
    }

    open $request_file
}

# Update an existing saved request
export def "api request update" [
    name: string                   # Request name
    --method (-m): string          # New HTTP method
    --url (-u): string             # New URL
    --headers (-H): record         # New headers
    --body (-b): string            # New body
    --collection (-c): string = "default"  # Collection name
] {
    let root = ($env.API_ROOT? | default (pwd))
    let request_file = ($root | path join "collections" $collection "requests" $"($name).nuon")

    if not ($request_file | path exists) {
        print $"(ansi red)Request '($name)' not found in collection '($collection)'(ansi reset)"
        return
    }

    mut req = (open $request_file)

    if $method != null {
        $req = ($req | upsert method $method)
    }
    if $url != null {
        $req = ($req | upsert url $url)
    }
    if $headers != null {
        $req = ($req | upsert headers $headers)
    }
    if $body != null {
        let body_content = if $body != "" {
            try {
                $body | from json
            } catch {
                $body
            }
        } else {
            null
        }
        $req = ($req | upsert body (if $body_content != null { { type: "json", content: $body_content } } else { null }))
    }

    $req = ($req | upsert updated_at (date now | format date "%Y-%m-%dT%H:%M:%SZ"))
    $req | to nuon | save -f $request_file

    print $"(ansi green)Request '($name)' updated in collection '($collection)'(ansi reset)"
}

# Delete a saved request
export def "api request delete" [
    name: string                   # Request name
    --collection (-c): string = "default"  # Collection name
    --force (-f)                   # Skip confirmation prompt
] {
    let root = ($env.API_ROOT? | default (pwd))
    let request_file = ($root | path join "collections" $collection "requests" $"($name).nuon")

    if not ($request_file | path exists) {
        print $"(ansi red)Request '($name)' not found in collection '($collection)'(ansi reset)"
        return
    }

    if not $force {
        let confirm = (input $"Delete request '($name)' from collection '($collection)'? [y/N] ")
        if $confirm !~ "^[yY]" {
            print "Cancelled"
            return
        }
    }

    rm $request_file
    print $"(ansi green)Request '($name)' deleted from collection '($collection)'(ansi reset)"
}

# Show response headers
export def "api headers" [result: record] {
    $result.response.headers | transpose key value | table
}

# Format response as table (for JSON arrays)
export def "api table" [result: record] {
    let body = $result.response.body
    if ($body | describe | str starts-with "list") {
        $body | table
    } else {
        $body
    }
}
