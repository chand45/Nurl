# HTTP Request Module
# Core HTTP request functionality using curl

use log.nu *
use vars.nu ["api vars interpolate", "api vars interpolate-record", "api vars extract"]
use auth.nu ["api auth get-config"]
use resource-path.nu [validate-resource-name resolve-under-base list-contained-resource-files]
use command-error.nu [fail-command]

def get-api-root [] {
    $env.API_ROOT? | default (pwd)
}

def get-collections-dir [] {
    resolve-under-base (get-api-root) "collections" "collections directory" --scope "API workspace"
}

def resolve-collection-dir [collections_dir: string, collection: string] {
    resolve-under-base $collections_dir $collection "collection" --scope "API workspace collections" --base-is-canonical
}

def resolve-requests-dir [collection_dir: string, collection: string] {
    resolve-under-base $collection_dir "requests" "request directory" --scope $"collection '($collection)'" --base-is-canonical
}

def resolve-request-file [requests_dir: string, name: string, --optional-suffix] {
    resolve-under-base $requests_dir $name "request" --nested --suffix ".nuon" --always-suffix=(not $optional_suffix) --scope "<collection>/requests" --base-is-canonical
}

def list-request-files [requests_dir: string] {
    list-contained-resource-files $requests_dir "request" --suffix ".nuon" --scope "<collection>/requests"
}

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

    # Update history index (B1) — inline to avoid cross-module dependency
    let index_path = ($history_dir | path join "index.nuon")
    let existing_index = if ($index_path | path exists) {
        try { open $index_path } catch { [] }
    } else { [] }
    let new_summary = {
        id: $id
        timestamp: $entry.timestamp
        method: ($request.method? | default "")
        url: ($request.url? | default "")
        status: ($response.status? | default 0)
        time_ms: ($response.time_ms? | default 0)
        date_dir: ($date_dir | path basename)
    }
    ($existing_index | append $new_summary | sort-by timestamp -r) | to nuon | save -f $index_path

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

def validate-output-mode [output: string] {
    let supported = ["pretty" "raw" "body" "json" "headers" "status" "none"]
    if $output not-in $supported {
        fail-command $"Unsupported output mode '($output)'. Expected one of: ($supported | str join ', ')."
    }
}

def read-body-file [body_file: string] {
    if not ($body_file | path exists) {
        fail-command $"Body file '($body_file)' not found"
    }
    if ($body_file | path type) == "dir" {
        fail-command $"Body file '($body_file)' must be a readable file"
    }
    try {
        open $body_file --raw | str trim
    } catch {
        fail-command $"Body file '($body_file)' could not be read"
    }
}

# Resolve body from multiple input sources (inline record/string, file)
# Priority: body-file > inline body
# Returns: JSON string ready for request
def resolve-body [
    --body (-b): any = {}          # Inline body as record, list, or pre-serialized JSON string
    --body-file (-f): string = ""  # Path to file containing body
] {
    # Body file takes priority
    if $body_file != "" {
        let file_content = (read-body-file $body_file)

        # Try to validate as JSON, but allow raw content
        try {
            $file_content | from json | to json
        } catch {
            $file_content
        }
    } else {
        let body_type = ($body | describe)
        if $body_type == "string" {
            # Pre-serialized JSON string — pass through as-is
            $body
        } else if not ($body | is-empty) {
            $body | to json
        } else {
            ""
        }
    }
}

# Build bearer authentication arguments for execution or redacted display.
def append-auth-args [
    args: list
    auth?: record
    --redact
] {
    if $auth == null {
        return $args
    }

    match ($auth.type? | default "none") {
        "bearer" => {
            let token = ($auth.token? | default "" | into string)
            if ($token | str trim | is-empty) {
                fail-command "Bearer token is missing"
            }
            let header_value = if $redact {
                "******"
            } else if $token =~ '(?i)^Bearer\s+' {
                $token
            } else {
                $"Bearer ($token)"
            }
            $args | append ["-H" $"Authorization: ($header_value)"]
        }
        _ => $args
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
        "--max-time" (get-timeout | into string)
    ]

    # HEAD: use --head so curl stops after receiving headers (avoids timeout waiting for body)
    if $method == "HEAD" {
        $args = ($args | append ["--head"])
    } else {
        $args = ($args | append ["-X" $method])
    }

    # Add headers
    for header in ($headers | transpose key value) {
        $args = ($args | append ["-H" $"($header.key): ($header.value)"])
    }

    # Non-bearer authentication retains its existing curl forms.
    if $auth != null {
        match ($auth.type? | default "none") {
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

    if $auth != null and ($auth.type? | default "none") == "bearer" {
        # Bearer headers share one builder so binary and normal execution cannot diverge.
        $args = (append-auth-args $args $auth)
    }

    # Add body if provided
    if $body != null and $body != "" {
        $args = ($args | append ["-d" $body])
    }

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

    # Non-bearer authentication retains its existing curl forms.
    if $auth != null {
        match ($auth.type? | default "none") {
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

    if $auth != null and ($auth.type? | default "none") == "bearer" {
        # Display construction never receives the execution token value.
        $args = (append-auth-args $args $auth --redact)
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

# URL-encode a single form value (application/x-www-form-urlencoded)
def url-encode-form-value [s: string] {
    $s
    | str replace --all "%" "%25"
    | str replace --all "+" "%2B"
    | str replace --all "&" "%26"
    | str replace --all "=" "%3D"
    | str replace --all "#" "%23"
    | str replace --all " " "+"
}

# Encode a record as application/x-www-form-urlencoded
def encode-form-data [data: record] {
    $data | transpose key value | each {|kv|
        let k = (url-encode-form-value $kv.key)
        let v = (url-encode-form-value ($kv.value | into string))
        $"($k)=($v)"
    } | str join "&"
}

# Build curl arguments for binary file download (no -i, adds -o path)
def build-curl-args-binary [
    method: string
    url: string
    headers: record
    output_path: string
    body?: string
    auth?: record
] {
    mut args = [
        "-s"
        "-S"
        "-w" "---RESPONSE_META---\n%{http_code}\n%{time_total}\n%{size_download}"
        "-X" $method
        "--max-time" (get-timeout | into string)
        "-o" $output_path
    ]

    for header in ($headers | transpose key value) {
        $args = ($args | append ["-H" $"($header.key): ($header.value)"])
    }

    if $auth != null {
        match ($auth.type? | default "none") {
            "basic" => { $args = ($args | append ["-u" $"($auth.username):($auth.password)"]) }
            "apikey_header" => { $args = ($args | append ["-H" $"($auth.header_name): ($auth.key)"]) }
            _ => {}
        }
    }

    if $auth != null and ($auth.type? | default "none") == "bearer" {
        # Keep binary execution on the same bearer builder as normal requests.
        $args = (append-auth-args $args $auth)
    }

    if $body != null and $body != "" {
        $args = ($args | append ["-d" $body])
    }

    $args
}

# Print response body with content-type-aware formatting and truncation (C9)
def print-body [body: any, output_mode: string = "pretty"] {
    if $body == null { return }

    let body_type = ($body | describe)

    if $output_mode == "raw" {
        try { print ($body | into string) } catch { print ($body | to json) }
        return
    }

    # Pretty / body mode
    if ($body_type | str starts-with "record") or ($body_type | str starts-with "list") or ($body_type | str starts-with "table") {
        let json_str = ($body | to json)
        let json_lines = ($json_str | lines)
        let line_count = ($json_lines | length)
        if $line_count > 40 {
            print ($json_lines | first 40 | str join "\n")
            let remaining = $line_count - 40
            print $"(ansi dark_gray)... [truncated — ($remaining) more lines; use --raw or --output body for full payload](ansi reset)"
        } else {
            print $json_str
        }
    } else {
        let body_str = try { $body | into string } catch { "" }
        let peek = ($body_str | str trim | str downcase | str substring 0..20)
        if ($peek | str starts-with "<!doctype") or ($peek | str starts-with "<html") {
            let len = ($body_str | str length)
            print $"(ansi dark_gray)[HTML response — ($len) bytes](ansi reset)"
            let html_lines = ($body_str | lines)
            let line_count = ($html_lines | length)
            # Truncate if too many lines OR body is too large (catches few-line but huge-line bodies)
            if $line_count > 15 or $len > 2000 {
                let preview_lines = ($html_lines | first 15 | each {|l| $l | str substring 0..500})
                let preview = ($preview_lines | str join "\n")
                let shown = if ($preview | str length) > 2000 { ($preview | str substring 0..2000) } else { $preview }
                let shown_len = ($shown | str length)
                print $shown
                print $"(ansi dark_gray)... [truncated — showing first ($shown_len) of ($len) bytes; use --raw or --output body for full payload](ansi reset)"
            } else {
                print $body_str
            }
        } else if ($peek | str starts-with "<?xml") {
            let len = ($body_str | str length)
            print $"(ansi dark_gray)[XML response — ($len) bytes](ansi reset)"
            let xml_lines = ($body_str | lines)
            let line_count = ($xml_lines | length)
            # Truncate if too many lines OR body is too large (catches few-line but huge-line bodies)
            if $line_count > 15 or $len > 2000 {
                let preview_lines = ($xml_lines | first 15 | each {|l| $l | str substring 0..500})
                let preview = ($preview_lines | str join "\n")
                let shown = if ($preview | str length) > 2000 { ($preview | str substring 0..2000) } else { $preview }
                let shown_len = ($shown | str length)
                print $shown
                print $"(ansi dark_gray)... [truncated — showing first ($shown_len) of ($len) bytes; use --raw or --output body for full payload](ansi reset)"
            } else {
                print $body_str
            }
        } else {
            # Plain text — truncate if very large
            let len = ($body_str | str length)
            if $len > 2048 {
                print ($body_str | str substring 0..2048)
                print $"(ansi dark_gray)... [truncated — ($len) bytes total; use --raw or --output body for full content](ansi reset)"
            } else {
                print $body_str
            }
        }
    }
}

# Build and return a coloured status line string for display
def format-status-line [response: record, method: string, url: string] {
    let status = ($response.status? | default 0)
    let status_text = ($response.status_text? | default "")
    let time_ms = ($response.time_ms? | default 0)
    let size_bytes = ($response.size_bytes? | default 0)

    let status_color = if $status >= 200 and $status < 300 {
        "green"
    } else if $status >= 400 {
        "red"
    } else {
        "yellow"
    }

    let size_str = if $size_bytes >= 1024 {
        $"($size_bytes / 1024 | math round)KB"
    } else {
        $"($size_bytes)B"
    }

    $"(ansi $status_color)● ($status) ($status_text)(ansi reset)  (ansi dark_gray)($time_ms)ms  ($size_str)  ($method) ($url)(ansi reset)"
}

# Map an HTTP status code to its standard reason phrase.
# Returns the numeric code as a string for unmapped codes (numeric fallback).
export def http-status-text [code: int] {
    match $code {
        100 => "Continue"
        101 => "Switching Protocols"
        200 => "OK"
        201 => "Created"
        202 => "Accepted"
        204 => "No Content"
        206 => "Partial Content"
        301 => "Moved Permanently"
        302 => "Found"
        303 => "See Other"
        304 => "Not Modified"
        307 => "Temporary Redirect"
        308 => "Permanent Redirect"
        400 => "Bad Request"
        401 => "Unauthorized"
        403 => "Forbidden"
        404 => "Not Found"
        405 => "Method Not Allowed"
        408 => "Request Timeout"
        409 => "Conflict"
        410 => "Gone"
        415 => "Unsupported Media Type"
        418 => "I'm a Teapot"
        422 => "Unprocessable Entity"
        429 => "Too Many Requests"
        500 => "Internal Server Error"
        501 => "Not Implemented"
        502 => "Bad Gateway"
        503 => "Service Unavailable"
        504 => "Gateway Timeout"
        _ => ($code | into string)
    }
}

def split-curl-output [output: string] {
    let parts = ($output | split row "---RESPONSE_META---")
    {
        payload: (if ($parts | length) > 1 {
            $parts | drop 1 | str join "---RESPONSE_META---"
        } else {
            $parts | first
        })
        metadata: (if ($parts | length) > 1 { $parts | last | str trim } else { "" })
    }
}

def parse-response-parts [body_raw: string, headers_raw: string, meta_part: string] {
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

    {
        status: $status_code
        status_text: (http-status-text $status_code)
        headers: $headers
        body: $body
        _raw_body: $body_raw
        time_ms: (($time_total * 1000) | math round)
        size_bytes: $size
    }
}

def require-fileless-header-curl [] {
    let version_result = try {
        {value: (curl --version | complete), error: null}
    } catch {|error|
        {value: null, error: $error}
    }
    if $version_result.error != null or $version_result.value.exit_code != 0 {
        fail-command "Nurl requires curl 7.83.0 or newer for fileless response-header capture"
    }
    let parsed = (
        $version_result.value.stdout
        | lines
        | get 0
        | parse --regex '^curl\s+(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)'
    )
    if ($parsed | is-empty) {
        fail-command "Could not determine whether curl supports fileless response-header capture"
    }
    let version = ($parsed | get 0)
    let major = ($version.major | into int)
    let minor = ($version.minor | into int)
    let patch = ($version.patch | into int)
    let supported = (
        $major > 7
        or ($major == 7 and $minor > 83)
        or ($major == 7 and $minor == 83 and $patch >= 0)
    )
    if not $supported {
        fail-command $"Nurl requires curl 7.83.0 or newer for fileless response-header capture \(found ($major).($minor).($patch)\)"
    }
}

def canonical-header-name [name: string] {
    let acronyms = {
        "cf": "CF"
        "dnt": "DNT"
        "md5": "MD5"
        "te": "TE"
        "www": "WWW"
        "xss": "XSS"
    }
    $name
    | split row "-"
    | each {|part|
        if $part in ($acronyms | columns) {
            $acronyms | get $part
        } else {
            $part | str capitalize
        }
    }
    | str join "-"
}

def normalize-header-json [headers: record] {
    $headers
    | transpose name values
    | reduce -f {} {|header, normalized|
        let value_type = ($header.values | describe)
        if not ($value_type | str starts-with "list") {
            fail-command "Curl returned invalid structured response headers"
        }
        let value = if ($header.values | is-empty) {
            ""
        } else {
            $header.values | get (($header.values | length) - 1)
        }
        $normalized | upsert (canonical-header-name $header.name) $value
    }
}

def parse-fileless-curl-stderr [stderr: string, token: string, expected_exit_code: int] {
    let begin = $"NURL_RESPONSE_META_($token)_BEGIN"
    let ending = $"NURL_RESPONSE_META_($token)_END"
    let begin_parts = ($stderr | split row $begin)
    if ($begin_parts | length) != 2 {
        fail-command "Curl did not return trusted response metadata"
    }
    let end_parts = ($begin_parts | get 1 | split row $ending)
    if ($end_parts | length) != 2 {
        fail-command "Curl returned malformed response metadata framing"
    }
    if not (($end_parts | get 1 | str trim) | is-empty) {
        fail-command "Curl returned malformed response metadata framing"
    }
    let metadata = try {
        $end_parts | get 0 | str trim | from json
    } catch {
        fail-command "Curl returned malformed structured response metadata"
    }
    let required = ["headers" "status" "time_total" "size_download" "exit_code"]
    for field in $required {
        if $field not-in ($metadata | columns) {
            fail-command "Curl returned incomplete structured response metadata"
        }
    }
    let metadata_exit = try {
        $metadata.exit_code | into int
    } catch {
        fail-command "Curl returned an invalid response metadata exit code"
    }
    if $metadata_exit != $expected_exit_code {
        fail-command "Curl response metadata did not match the transfer result"
    }
    if not (($metadata.headers | describe) | str starts-with "record") {
        fail-command "Curl returned invalid structured response headers"
    }
    {
        diagnostics: ($begin_parts | get 0 | str trim)
        metadata: ($metadata | update headers (normalize-header-json $metadata.headers))
    }
}

def curl-with-fileless-metadata [curl_args: list, url: string, method: string] {
    let token = (random uuid | str replace --all "-" "")
    let begin = $"NURL_RESPONSE_META_($token)_BEGIN"
    let ending = $"NURL_RESPONSE_META_($token)_END"
    let write_out = (
        "%{stderr}\n"
        + $begin
        + "\n{\"headers\":%{header_json},\"status\":\"%{http_code}\",\"time_total\":\"%{time_total}\",\"size_download\":\"%{size_download}\",\"exit_code\":\"%{exitcode}\"}\n"
        + $ending
        + "\n"
    )
    let framed_args = ($curl_args | append ["--write-out" $write_out])
    let final_args = if $method == "HEAD" {
        let null_device = if $nu.os-info.name == "windows" { "NUL" } else { "/dev/null" }
        $framed_args | append ["--output" $null_device]
    } else {
        $framed_args
    }
    let output = (curl ...$final_args $url | complete)
    if (($output.stderr | describe) | str starts-with "binary") {
        fail-command "Curl returned malformed structured response metadata"
    }
    let parsed = (parse-fileless-curl-stderr $output.stderr $token $output.exit_code)
    {
        output: ($output | update stderr $parsed.diagnostics)
        metadata: $parsed.metadata
    }
}

def parse-curl-response-fileless [body_raw: string, metadata: record] {
    let body = try {
        $body_raw | from json
    } catch {
        $body_raw
    }
    {
        status: ($metadata.status | into int)
        status_text: (http-status-text ($metadata.status | into int))
        headers: $metadata.headers
        body: $body
        _raw_body: $body_raw
        time_ms: ((($metadata.time_total | into float) * 1000) | math round)
        size_bytes: ($metadata.size_download | into int)
    }
}

def parse-curl-response-internal [output: string] {
    let split = (split-curl-output $output)
    # Compatibility parser for callers that provide historical curl `-i` output.
    let response_part = $split.payload
    let sep = if ($response_part | str contains "\r\n\r\n") { "\r\n\r\n" } else { "\n\n" }
    let all_blocks = ($response_part | split row $sep)
    let http_block_indices = ($all_blocks
        | enumerate
        | where {|b| $b.item | str trim | str starts-with "HTTP/"}
        | get index)

    let last_http_idx = if ($http_block_indices | is-empty) { 0 } else { $http_block_indices | last }

    let headers_raw = ($all_blocks | get $last_http_idx)
    let body_raw = if ($last_http_idx + 1) < ($all_blocks | length) {
        $all_blocks | skip ($last_http_idx + 1) | str join $sep
    } else { "" }
    parse-response-parts $body_raw $headers_raw $split.metadata
}

export def parse-curl-response [output: string] {
    parse-curl-response-internal $output | reject _raw_body
}

def redact-sensitive-response-headers [headers: record] {
    $headers | transpose key value | reduce -f {} {|header, redacted|
        let sensitive = (
            (($header.key | str downcase) =~ '(authorization|cookie|token|secret|api-key|session)')
            or (($header.value | into string | str downcase) | str starts-with "bearer ")
        )
        $redacted | upsert $header.key (if $sensitive { "******" } else { $header.value })
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
    --follow-redirects (-L)          # Follow HTTP redirects (curl -L)
    --retries: int = 0               # Number of retries on 5xx or connection failure
    --retry-delay: int = 0           # Seconds to wait between retries
    --binary-save (-B): string = ""  # Save binary response to file (bypasses body parse)
    --quiet-binary-status             # Suppress download status in data output modes
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

    # Handle dry-run mode
    if $dry_run {
        let display_args = (build-curl-args-for-display $method $request_url $final_headers $final_body $auth)
        let curl_command = (curl-args-to-string $display_args $request_url)
        print $curl_command
        return null
    }

    # Binary save mode: curl writes directly to file, no body in stdout
    if $binary_save != "" {
        let bin_args = (build-curl-args-binary $method $request_url $final_headers $binary_save $final_body $auth)
        let final_bin_args = if $follow_redirects { $bin_args | append "-L" } else { $bin_args }
        let start_time = (date now)
        let output = (curl ...$final_bin_args $request_url | complete)

        if $output.exit_code != 0 {
            log error $"Request failed: ($output.stderr)"
            return null
        }

        let meta_parts = ($output.stdout | split row "---RESPONSE_META---")
        let meta_lines = if ($meta_parts | length) > 1 { ($meta_parts | get 1 | str trim | lines) } else { [] }
        let status_code = if ($meta_lines | length) > 0 { try { $meta_lines | first | into int } catch { 0 } } else { 0 }
        let time_total = if ($meta_lines | length) > 1 { try { $meta_lines | get 1 | into float } catch { 0.0 } } else { 0.0 }
        let size = if ($meta_lines | length) > 2 { try { $meta_lines | get 2 | into int } catch { 0 } } else { 0 }

        let bin_response = {
            status: $status_code
            status_text: (http-status-text $status_code)
            headers: {}
            body: $"[binary saved to: ($binary_save)]"
            time_ms: (($time_total * 1000) | math round)
            size_bytes: $size
        }

        let request_record = { method: $method, url: $final_url, headers: $final_headers, body: null }
        if not $no_history { save-to-history $request_record $bin_response }

        if not $quiet_binary_status {
            print $"(ansi green)Downloaded: ($binary_save) (($size)B)(ansi reset)"
        }
        return {
            request: $request_record
            response: $bin_response
            timestamp: ($start_time | format date "%Y-%m-%dT%H:%M:%SZ")
        }
    }

    # Build curl arguments
    let base_args = (build-curl-args $method $request_url $final_headers $final_body $auth)
    let curl_args = if $follow_redirects { $base_args | append "-L" } else { $base_args }
    require-fileless-header-curl

    # Execute with retry loop (C8) — return-in-loop avoids null-typed mut variable
    let start_time = (date now)
    let max_attempts = ($retries + 1)
    mut attempt = 0

    while $attempt < $max_attempts {
        $attempt = $attempt + 1
        let captured = (curl-with-fileless-metadata $curl_args $request_url $method)
        let output = $captured.output

        if $output.exit_code != 0 {
            if $attempt < $max_attempts {
                if $retry_delay > 0 { sleep ($retry_delay | into duration --unit sec) }
                continue
            }
            log error $"Request failed: ($output.stderr)"
            return null
        }

        let parsed = (parse-curl-response-fileless $output.stdout $captured.metadata)
        let response = ($parsed | reject _raw_body)

        # Retry on 5xx if attempts remain
        if $parsed.status >= 500 and $attempt < $max_attempts {
            if $retry_delay > 0 { sleep ($retry_delay | into duration --unit sec) }
            continue
        }

        # Success: build and return result
        let request_record = {
            method: $method
            url: $final_url
            headers: $final_headers
            body: (if $final_body != "" { try { $final_body | from json } catch { $final_body } } else { null })
        }

        if not $no_history {
            let history_response = ($response | update headers (redact-sensitive-response-headers $response.headers))
            save-to-history $request_record $history_response
        }

        return {
            request: $request_record
            response: $response
            timestamp: ($start_time | format date "%Y-%m-%dT%H:%M:%SZ")
            _raw_body: $parsed._raw_body
        }
    }

    log error "All request attempts failed"
    null
}

def save-response-body [body: any, path: string, --announce] {
    if $path == "" or $body == null {
        return
    }
    let body_type = ($body | describe)
    let body_value = if ($body_type | str starts-with "record") or ($body_type | str starts-with "list") or ($body_type | str starts-with "table") {
        $body | to json
    } else {
        try { $body | into string } catch { $body }
    }
    $body_value | save -f $path
    if $announce {
        print $"(ansi green)Saved to: ($path)(ansi reset)"
    }
}

def save-result-body [result: record, path: string, --announce] {
    if $path == "" {
        return
    }
    if "_raw_body" in ($result | columns) {
        if $result._raw_body == "" {
            return
        }
        $result._raw_body | save -f $path
        if $announce {
            print $"(ansi green)Saved to: ($path)(ansi reset)"
        }
    } else {
        save-response-body ($result.response.body? | default null) $path --announce=$announce
    }
}

def raw-response-body [result: record] {
    if "_raw_body" in ($result | columns) {
        if $result._raw_body == "" { null } else { $result._raw_body }
    } else {
        let body = ($result.response.body? | default null)
        let body_type = ($body | describe)
        if ($body_type | str starts-with "record") or ($body_type | str starts-with "list") or ($body_type | str starts-with "table") {
            $body | to json --raw
        } else {
            $body
        }
    }
}

# Pretty-mode display only (A1, C3). Called only when output == "pretty".
# All other modes are handled by apply-output-selection which returns the value directly.
def display-response [
    result: record
    --verbose (-v)           # Show request + response headers (curl-like > / <)
    --include (-I)           # Include response headers above body
    --save (-S): string = "" # Save response body to file
] {
    let response = $result.response
    let method = ($result.request?.method? | default "")
    let url = ($result.request?.url? | default "")

    # Status line
    print (format-status-line $response $method $url)

    # Verbose: print request info in curl-like > style
    if $verbose {
        print ""
        print $"(ansi dark_gray)> ($method) ($url)(ansi reset)"
        for hdr in ($result.request?.headers? | default {} | transpose key value) {
            print $"(ansi dark_gray)> ($hdr.key): ($hdr.value)(ansi reset)"
        }
    }

    # Response headers (verbose or --include)
    if $verbose or $include {
        print ""
        for hdr in (redact-sensitive-response-headers ($response.headers? | default {}) | transpose key value) {
            print $"(ansi cyan)< ($hdr.key): ($hdr.value)(ansi reset)"
        }
    }

    # Body
    let body = ($response.body? | default null)
    if $body != null and $body != "" {
        print ""
        print-body $body "pretty"
    }

    # --save: write body to file
    if $save != "" {
        save-result-body $result $save --announce
    }
}

# Route output by mode (C1, C2).
# DATA modes (--raw, --output status/body/headers/json/none, --select): return the value directly.
#   Nushell renders the returned value once when naked; `let x = (api get ...)` captures correctly.
# INTERACTIVE mode (pretty/default): prints custom display, returns null to prevent REPL double-render.
def apply-output-selection [
    result: record
    output: string
    select_path: string
    raw: bool
    verbose: bool
    include: bool
    save: string
] {
    let public_result = if "_raw_body" in ($result | columns) {
        $result | reject _raw_body
    } else {
        $result
    }
    let body = ($public_result.response.body? | default null)
    if $save != "" and ($raw or $select_path != "" or $output != "pretty") {
        save-result-body $result $save
    }

    if $raw {
        return $public_result
    }

    # --select: normalize shorthand paths, extract and return the value
    if $select_path != "" {
        let full_path = if ($select_path == "status") or ($select_path | str starts-with "body") or ($select_path | str starts-with "headers") {
            "response." + $select_path
        } else {
            $select_path
        }
        let extracted = (api vars extract $public_result $full_path)
        if $extracted != null {
            return $extracted
        } else {
            let warn_msg = ("no value at path: " + $select_path)
            print ((ansi yellow) + $warn_msg + (ansi reset))
            return null
        }
    }

    match $output {
        "status"  => { $public_result.response.status? | default 0 }
        "body"    => { $public_result.response.body? | default null }
        "raw"     => { raw-response-body $result }
        "headers" => { $public_result.response.headers? | default {} }
        "json"    => { $public_result | to json }
        "none"    => { null }
        "pretty"  => {
            # pretty / interactive: print custom display, return null (no REPL double-render)
            display-response $result --verbose=$verbose --include=$include --save=$save
            null
        }
        _ => { fail-command $"Unsupported output mode '($output)'" }
    }
}

# GET request
export def "api get" [
    url: string                          # URL to request
    --headers (-H): record = {}          # Additional headers
    --auth (-a): record = {}             # Authentication config
    --raw (-r)                           # Return raw result without display
    --no-history                         # Don't save to history
    --dry-run (-d)                       # Output curl command instead of executing
    --debug                              # Show verbose debug output
    --output (-o): string = "pretty"     # Output mode: pretty|body|raw|json|headers|status|none
    --select (-s): string = ""           # Select a field (dot-path, e.g. response.body.id)
    --verbose (-v)                       # Show request + response headers
    --include (-I)                       # Include response headers above body
    --follow-redirects (-L)              # Follow HTTP redirects
    --save (-S): string = ""             # Save response body to file
    --binary-save (-B): string = ""      # Save binary response directly to file
    --retries: int = 0                   # Retry count on 5xx/connection error
    --retry-delay: int = 0              # Seconds between retries
] {
    validate-output-mode $output
    if $debug { $env.API_DEBUG = true }
    let resolved_auth = (api auth get-config $auth)
    let data_output = ($raw or $select != "" or $output != "pretty")
    let result = (execute-request "GET" $url -H $headers -a $resolved_auth --no-history=$no_history --dry-run=$dry_run --follow-redirects=$follow_redirects --retries=$retries --retry-delay=$retry_delay --binary-save=$binary_save --quiet-binary-status=$data_output)

    if $result == null {
        if $debug { $env.API_DEBUG = false }
        return null
    }

    if $debug { $env.API_DEBUG = false }
    apply-output-selection $result $output $select $raw $verbose $include $save
}
export def "api post" [
    url: string                          # URL to request
    --body (-b): any = {}                # Request body as record or JSON string
    --body-file (-f): string = ""        # Read body from file
    --headers (-H): record = {}          # Additional headers
    --auth (-a): record = {}             # Authentication config
    --raw (-r)                           # Return raw result without display
    --no-history                         # Don't save to history
    --dry-run (-d)                       # Output curl command instead of executing
    --debug                              # Show verbose debug output
    --form (-F): record = {}             # Form-encoded body (application/x-www-form-urlencoded)
    --output (-o): string = "pretty"     # Output mode: pretty|body|raw|json|headers|status|none
    --select (-s): string = ""           # Select a field (dot-path)
    --verbose (-v)                       # Show request + response headers
    --include (-I)                       # Include response headers above body
    --follow-redirects (-L)              # Follow HTTP redirects
    --save (-S): string = ""             # Save response body to file
    --binary-save (-B): string = ""      # Save binary response directly to file
    --retries: int = 0                   # Retry count on 5xx/connection error
    --retry-delay: int = 0              # Seconds between retries
] {
    validate-output-mode $output
    if $body_file != "" { read-body-file $body_file | ignore }
    if $debug { $env.API_DEBUG = true }

    # Form encoding takes precedence over --body/--body-file
    let final_body = if not ($form | is-empty) {
        encode-form-data $form
    } else {
        let b = (resolve-body -b $body -f $body_file)
        if $b == null {
            if $debug { $env.API_DEBUG = false }
            return null
        }
        $b
    }
    let resolved_auth = (api auth get-config $auth)

    # Override Content-Type header for form encoding
    let req_headers = if not ($form | is-empty) {
        $headers | upsert "Content-Type" "application/x-www-form-urlencoded"
    } else { $headers }

    let data_output = ($raw or $select != "" or $output != "pretty")
    let result = (execute-request "POST" $url -H $req_headers -b $final_body -a $resolved_auth --no-history=$no_history --dry-run=$dry_run --follow-redirects=$follow_redirects --retries=$retries --retry-delay=$retry_delay --binary-save=$binary_save --quiet-binary-status=$data_output)

    if $result == null {
        if $debug { $env.API_DEBUG = false }
        return null
    }

    if $debug { $env.API_DEBUG = false }
    apply-output-selection $result $output $select $raw $verbose $include $save
}

# PUT request
export def "api put" [
    url: string                          # URL to request
    --body (-b): any = {}                # Request body as record or JSON string
    --body-file (-f): string = ""        # Read body from file
    --headers (-H): record = {}          # Additional headers
    --auth (-a): record = {}             # Authentication config
    --raw (-r)                           # Return raw result without display
    --no-history                         # Don't save to history
    --dry-run (-d)                       # Output curl command instead of executing
    --debug                              # Show verbose debug output
    --form (-F): record = {}             # Form-encoded body (application/x-www-form-urlencoded)
    --output (-o): string = "pretty"     # Output mode: pretty|body|raw|json|headers|status|none
    --select (-s): string = ""           # Select a field (dot-path)
    --verbose (-v)                       # Show request + response headers
    --include (-I)                       # Include response headers above body
    --follow-redirects (-L)              # Follow HTTP redirects
    --save (-S): string = ""             # Save response body to file
    --binary-save (-B): string = ""      # Save binary response directly to file
    --retries: int = 0                   # Retry count on 5xx/connection error
    --retry-delay: int = 0              # Seconds between retries
] {
    validate-output-mode $output
    if $body_file != "" { read-body-file $body_file | ignore }
    if $debug { $env.API_DEBUG = true }

    let final_body = if not ($form | is-empty) {
        encode-form-data $form
    } else {
        let b = (resolve-body -b $body -f $body_file)
        if $b == null {
            if $debug { $env.API_DEBUG = false }
            return null
        }
        $b
    }
    let resolved_auth = (api auth get-config $auth)

    let req_headers = if not ($form | is-empty) {
        $headers | upsert "Content-Type" "application/x-www-form-urlencoded"
    } else { $headers }

    let data_output = ($raw or $select != "" or $output != "pretty")
    let result = (execute-request "PUT" $url -H $req_headers -b $final_body -a $resolved_auth --no-history=$no_history --dry-run=$dry_run --follow-redirects=$follow_redirects --retries=$retries --retry-delay=$retry_delay --binary-save=$binary_save --quiet-binary-status=$data_output)

    if $result == null {
        if $debug { $env.API_DEBUG = false }
        return null
    }

    if $debug { $env.API_DEBUG = false }
    apply-output-selection $result $output $select $raw $verbose $include $save
}

# PATCH request
export def "api patch" [
    url: string                          # URL to request
    --body (-b): any = {}                # Request body as record or JSON string
    --body-file (-f): string = ""        # Read body from file
    --headers (-H): record = {}          # Additional headers
    --auth (-a): record = {}             # Authentication config
    --raw (-r)                           # Return raw result without display
    --no-history                         # Don't save to history
    --dry-run (-d)                       # Output curl command instead of executing
    --debug                              # Show verbose debug output
    --form (-F): record = {}             # Form-encoded body (application/x-www-form-urlencoded)
    --output (-o): string = "pretty"     # Output mode: pretty|body|raw|json|headers|status|none
    --select (-s): string = ""           # Select a field (dot-path)
    --verbose (-v)                       # Show request + response headers
    --include (-I)                       # Include response headers above body
    --follow-redirects (-L)              # Follow HTTP redirects
    --save (-S): string = ""             # Save response body to file
    --binary-save (-B): string = ""      # Save binary response directly to file
    --retries: int = 0                   # Retry count on 5xx/connection error
    --retry-delay: int = 0              # Seconds between retries
] {
    validate-output-mode $output
    if $body_file != "" { read-body-file $body_file | ignore }
    if $debug { $env.API_DEBUG = true }

    let final_body = if not ($form | is-empty) {
        encode-form-data $form
    } else {
        let b = (resolve-body -b $body -f $body_file)
        if $b == null {
            if $debug { $env.API_DEBUG = false }
            return null
        }
        $b
    }
    let resolved_auth = (api auth get-config $auth)

    let req_headers = if not ($form | is-empty) {
        $headers | upsert "Content-Type" "application/x-www-form-urlencoded"
    } else { $headers }

    let data_output = ($raw or $select != "" or $output != "pretty")
    let result = (execute-request "PATCH" $url -H $req_headers -b $final_body -a $resolved_auth --no-history=$no_history --dry-run=$dry_run --follow-redirects=$follow_redirects --retries=$retries --retry-delay=$retry_delay --binary-save=$binary_save --quiet-binary-status=$data_output)

    if $result == null {
        if $debug { $env.API_DEBUG = false }
        return null
    }

    if $debug { $env.API_DEBUG = false }
    apply-output-selection $result $output $select $raw $verbose $include $save
}

# DELETE request
export def "api delete" [
    url: string                          # URL to request
    --headers (-H): record = {}          # Additional headers
    --auth (-a): record = {}             # Authentication config
    --raw (-r)                           # Return raw result without display
    --no-history                         # Don't save to history
    --dry-run (-d)                       # Output curl command instead of executing
    --debug                              # Show verbose debug output
    --output (-o): string = "pretty"     # Output mode: pretty|body|raw|json|headers|status|none
    --select (-s): string = ""           # Select a field (dot-path)
    --verbose (-v)                       # Show request + response headers
    --include (-I)                       # Include response headers above body
    --follow-redirects (-L)              # Follow HTTP redirects
    --retries: int = 0                   # Retry count on 5xx/connection error
    --retry-delay: int = 0              # Seconds between retries
] {
    validate-output-mode $output
    if $debug { $env.API_DEBUG = true }
    let resolved_auth = (api auth get-config $auth)
    let result = (execute-request "DELETE" $url -H $headers -a $resolved_auth --no-history=$no_history --dry-run=$dry_run --follow-redirects=$follow_redirects --retries=$retries --retry-delay=$retry_delay)

    if $result == null {
        if $debug { $env.API_DEBUG = false }
        return null
    }

    if $debug { $env.API_DEBUG = false }
    apply-output-selection $result $output $select $raw $verbose $include ""
}

# Generic request with any method
export def "api request" [
    --method (-m): string = "GET"        # HTTP method
    url: string                          # URL to request
    --body (-b): any = {}                # Request body as record or JSON string
    --body-file (-f): string = ""        # Read body from file
    --headers (-H): record = {}          # Additional headers
    --auth (-a): record = {}             # Authentication config
    --raw (-r)                           # Return raw result without display
    --no-history                         # Don't save to history
    --dry-run (-d)                       # Output curl command instead of executing
    --debug                              # Show verbose debug output
    --form (-F): record = {}             # Form-encoded body (application/x-www-form-urlencoded)
    --output (-o): string = "pretty"     # Output mode: pretty|body|raw|json|headers|status|none
    --select (-s): string = ""           # Select a field (dot-path)
    --verbose (-v)                       # Show request + response headers
    --include (-I)                       # Include response headers above body
    --follow-redirects (-L)              # Follow HTTP redirects
    --save (-S): string = ""             # Save response body to file
    --binary-save (-B): string = ""      # Save binary response directly to file
    --retries: int = 0                   # Retry count on 5xx/connection error
    --retry-delay: int = 0              # Seconds between retries
] {
    validate-output-mode $output
    if $body_file != "" { read-body-file $body_file | ignore }
    if $debug { $env.API_DEBUG = true }

    let final_body = if not ($form | is-empty) {
        encode-form-data $form
    } else {
        let b = (resolve-body -b $body -f $body_file)
        if $b == null {
            if $debug { $env.API_DEBUG = false }
            return null
        }
        $b
    }
    let resolved_auth = (api auth get-config $auth)

    let req_headers = if not ($form | is-empty) {
        $headers | upsert "Content-Type" "application/x-www-form-urlencoded"
    } else { $headers }

    let data_output = ($raw or $select != "" or $output != "pretty")
    let result = (execute-request $method $url -H $req_headers -b $final_body -a $resolved_auth --no-history=$no_history --dry-run=$dry_run --follow-redirects=$follow_redirects --retries=$retries --retry-delay=$retry_delay --binary-save=$binary_save --quiet-binary-status=$data_output)

    if $result == null {
        if $debug { $env.API_DEBUG = false }
        return null
    }

    if $debug { $env.API_DEBUG = false }
    apply-output-selection $result $output $select $raw $verbose $include $save
}

# Send a saved request by name
export def "api send" [
    name: string                         # Request name (path in collection)
    --collection (-c): string = ""       # Collection name
    --body (-b): any = {}                # Override request body as record or JSON string
    --body-file (-f): string = ""        # Override request body from file
    --auth (-a): record = {}             # Override authentication config
    --raw (-r)                           # Return raw result
    --vars (-v): record = {}             # Extra variables
    --dry-run (-d)                       # Output curl command instead of executing
    --debug                              # Show verbose debug output
    --no-history                         # Don't save to history (A7)
    --output (-o): string = "pretty"     # Output mode: pretty|body|raw|json|headers|status|none
    --select (-s): string = ""           # Select a field (dot-path)
    --verbose                            # Show request + response headers (no shorthand: -v taken by --vars)
    --include (-I)                       # Include response headers above body
    --follow-redirects (-L)              # Follow HTTP redirects
    --save (-S): string = ""             # Save response body to file
    --binary-save (-B): string = ""      # Save binary response directly to file
    --retries: int = 0                   # Retry count on 5xx/connection error
    --retry-delay: int = 0              # Seconds between retries
] {
    validate-output-mode $output
    validate-resource-name "request" $name --nested --scope "<collection>/requests" | ignore
    if $collection != "" {
        validate-resource-name "collection" $collection | ignore
    }
    let has_body_override = (not ($body | is-empty)) or $body_file != ""
    let resolved_body_override = if $has_body_override {
        resolve-body -b $body -f $body_file
    } else {
        null
    }
    if $debug { $env.API_DEBUG = true }
    let collections_dir = (get-collections-dir)

    # Find request file and determine collection name
    mut coll_name = $collection
    let request_path = if $collection != "" {
        let collection_path = (resolve-collection-dir $collections_dir $collection)
        let requests_dir = (resolve-requests-dir $collection_path $collection)
        resolve-request-file $requests_dir $name --optional-suffix
    } else {
        # Search in all collections
        let colls = try { ls $collections_dir | where type == dir | get name } catch { [] }
        mut found_file = null
        for discovered_path in $colls {
            let discovered_name = ($discovered_path | path basename)
            let coll_path = (resolve-collection-dir $collections_dir $discovered_name)
            let requests_dir = (resolve-requests-dir $coll_path $discovered_name)
            let request_file = (resolve-request-file $requests_dir $name --optional-suffix)
            if ($request_file | path exists) {
                $found_file = $request_file
                $coll_name = $discovered_name
                break
            }
        }

        if $found_file == null {
            if $debug { $env.API_DEBUG = false }
            fail-command $"Request '($name)' not found"
        }

        $found_file
    }

    if not ($request_path | path exists) {
        if $debug { $env.API_DEBUG = false }
        fail-command $"Request '($name)' not found"
    }

    # Load request
    let request = (open $request_path)

    # Build headers
    let headers = ($request.headers? | default {})

    # Build body - check for override first, then use saved body
    let body = if $has_body_override {
        $resolved_body_override
    } else if ($request.body?.content? | default null) != null {
        # Use saved request body
        $request.body.content | to json
    } else {
        ""
    }

    # Build auth from override or request config
    let auth = if not ($auth | is-empty) {
        api auth get-config $auth
    } else if ($request.auth? | default null) != null {
        api auth get-config $request.auth
    } else {
        {}
    }

    # Execute request with collection context for variable resolution
    let data_output = ($raw or $select != "" or $output != "pretty")
    let result = (execute-request ($request.method? | default "GET") $request.url -H $headers -b $body -a $auth --dry-run=$dry_run -c $coll_name -v $vars --no-history=$no_history --follow-redirects=$follow_redirects --retries=$retries --retry-delay=$retry_delay --binary-save=$binary_save --quiet-binary-status=$data_output)

    if $result == null {
        if $debug { $env.API_DEBUG = false }
        return null
    }

    # Run tests if defined (C7)
    mut final_result = $result
    if ($request.tests? | default null) != null and ($request.tests | describe | str starts-with "record") {
        # Suppress test output in raw/data modes — only print in pretty/interactive mode
        let tests_quiet = ($raw or ($output != "pretty"))
        let test_results = (run-tests $result $request.tests --quiet=$tests_quiet)
        # Merge tests_passed into result so --raw callers can inspect it
        $final_result = ($result | upsert tests_passed $test_results.all_passed)
        if not $tests_quiet and not $test_results.all_passed {
            let fail_msg = ("Warning: " + ($test_results.failed | into string) + " tests failed")
            print ((ansi yellow) + $fail_msg + (ansi reset))
        }
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

    if $debug { $env.API_DEBUG = false }
    apply-output-selection $final_result $output $select $raw $verbose $include $save
}

# Create a new saved request
export def "api request create" [
    name: string                   # Request name
    method: string                 # HTTP method
    url: string                    # Request URL
    --headers (-H): record = {}    # Headers
    --body (-b): record = {}       # Body as record
    --body-file (-f): string = ""  # Read body from file
    --auth (-a): record = {}       # Authentication config (e.g., {type: bearer, token_ref: mytoken})
    --collection (-c): string = "default"  # Collection name
    --debug                        # Show verbose output
] {
    validate-resource-name "request" $name --nested --scope "<collection>/requests" | ignore
    validate-resource-name "collection" $collection | ignore
    let body_content = if $body_file != "" {
        let file_content = (read-body-file $body_file)
        try {
            $file_content | from json
        } catch {
            $file_content
        }
    } else if not ($body | is-empty) {
        $body
    } else {
        null
    }
    if $debug { $env.API_DEBUG = true }
    let collections_dir = (get-collections-dir)
    let collection_path = (resolve-collection-dir $collections_dir $collection)

    # Ensure collection exists
    if not ($collection_path | path exists) {
        mkdir $collection_path
        let requests_dir = (resolve-requests-dir $collection_path $collection)
        let environments_dir = (resolve-under-base $collection_path "environments" "environment directory" --scope $"collection '($collection)'" --base-is-canonical)
        mkdir $requests_dir
        mkdir $environments_dir
        let collection_file = (resolve-under-base $collection_path "collection.nuon" "collection metadata" --scope $"collection '($collection)'" --base-is-canonical)
        {
            name: $collection
            description: ""
            created_at: (date now | format date "%Y-%m-%dT%H:%M:%SZ")
        } | to nuon --indent 4 | save $collection_file
    }

    let requests_path = (resolve-requests-dir $collection_path $collection)
    if not ($requests_path | path exists) {
        mkdir $requests_path
    }

    let request_file = (resolve-request-file $requests_path $name)
    let request_parent = ($request_file | path dirname)
    if not ($request_parent | path exists) {
        mkdir $request_parent
    }

    {
        name: $name
        collection: $collection
        method: $method
        url: $url
        headers: $headers
        body: (if $body_content != null { { type: "json", content: $body_content } } else { null })
        auth: (if ($auth | is-empty) { null } else { $auth })
        pre_request: null
        tests: null
        chain: null
        created_at: (date now | format date "%Y-%m-%dT%H:%M:%SZ")
    } | to nuon --indent 4 | save $request_file

    print $"(ansi green)Request '($name)' created in collection '($collection)'(ansi reset)"
    if $debug { $env.API_DEBUG = false }
}

# List saved requests
export def "api request list" [
    --collection (-c): string = ""  # Filter by collection
    --debug                         # Show verbose output
] {
    if $collection != "" {
        validate-resource-name "collection" $collection | ignore
    }
    if $debug { $env.API_DEBUG = true }
    let collections_dir = (get-collections-dir)

    if not ($collections_dir | path exists) {
        log warn "No collections found"
        if $debug { $env.API_DEBUG = false }
        return []
    }

    let requests = if $collection != "" {
        let collection_dir = (resolve-collection-dir $collections_dir $collection)
        let requests_dir = (resolve-requests-dir $collection_dir $collection)
        if ($requests_dir | path exists) {
            list-request-files $requests_dir | each {|file|
                let req = (open $file.path)
                {
                    name: ($req.name? | default $file.name)
                    collection: $collection
                    method: ($req.method? | default "GET")
                    url: ($req.url? | default "")
                }
            }
        } else { [] }
    } else {
        # Get all collections and their requests
        let colls = try { ls $collections_dir | where type == dir | get name } catch { [] }
        $colls | each {|discovered_path|
            let coll_name = ($discovered_path | path basename)
            let coll_path = (resolve-collection-dir $collections_dir $coll_name)
            let requests_dir = (resolve-requests-dir $coll_path $coll_name)
            if ($requests_dir | path exists) {
                list-request-files $requests_dir | each {|file|
                    let req = (open $file.path)
                    {
                        name: ($req.name? | default $file.name)
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
        return []
    }

    $requests
}

# Show details of a saved request
export def "api request show" [
    name: string                   # Request name
    --collection (-c): string = ""  # Collection name (searches all if not specified)
] {
    validate-resource-name "request" $name --nested --scope "<collection>/requests" | ignore
    if $collection != "" {
        validate-resource-name "collection" $collection | ignore
    }
    let collections_dir = (get-collections-dir)

    let request_file = if $collection != "" {
        # Search in specific collection
        let collection_dir = (resolve-collection-dir $collections_dir $collection)
        let requests_dir = (resolve-requests-dir $collection_dir $collection)
        resolve-request-file $requests_dir $name
    } else {
        # Search across all collections
        let colls = try { ls $collections_dir | where type == dir | get name } catch { [] }
        let found = $colls | each {|discovered_path|
            let coll_name = ($discovered_path | path basename)
            let coll_path = (resolve-collection-dir $collections_dir $coll_name)
            let requests_dir = (resolve-requests-dir $coll_path $coll_name)
            let file = (resolve-request-file $requests_dir $name)
            if ($file | path exists) { $file } else { null }
        } | where {|f| $f != null }
        if ($found | is-empty) { null } else { $found | first }
    }

    if $request_file == null or not ($request_file | path exists) {
        let scope = if $collection != "" { $"collection '($collection)'" } else { "any collection" }
        fail-command $"Request '($name)' not found in ($scope)"
    }

    open $request_file
}

# Update an existing saved request
export def "api request update" [
    name: string                   # Request name
    --method (-m): string          # New HTTP method
    --url (-u): string             # New URL
    --headers (-H): record         # New headers
    --body (-b): record            # New body as record
    --body-file (-f): string       # New body from file
    --auth (-a): record            # New authentication config (e.g., {type: bearer, token_ref: mytoken})
    --collection (-c): string = "default"  # Collection name
] {
    validate-resource-name "request" $name --nested --scope "<collection>/requests" | ignore
    validate-resource-name "collection" $collection | ignore
    let collections_dir = (get-collections-dir)
    let collection_dir = (resolve-collection-dir $collections_dir $collection)
    let requests_dir = (resolve-requests-dir $collection_dir $collection)
    let request_file = (resolve-request-file $requests_dir $name)

    if not ($request_file | path exists) {
        fail-command $"Request '($name)' not found in collection '($collection)'"
    }

    let file_body_content = if $body_file != null and $body_file != "" {
        let file_content = (read-body-file $body_file)
        try {
            $file_content | from json
        } catch {
            $file_content
        }
    } else {
        null
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
    # Handle body update from either inline record or file
    if $body != null or $body_file != null {
        let body_content = if $body_file != null and $body_file != "" {
            $file_body_content
        } else if $body != null and not ($body | is-empty) {
            $body
        } else {
            null
        }
        $req = ($req | upsert body (if $body_content != null { { type: "json", content: $body_content } } else { null }))
    }
    if $auth != null {
        $req = ($req | upsert auth $auth)
    }

    $req = ($req | upsert updated_at (date now | format date "%Y-%m-%dT%H:%M:%SZ"))
    $req | to nuon --indent 4 | save -f $request_file

    print $"(ansi green)Request '($name)' updated in collection '($collection)'(ansi reset)"
}

# Delete a saved request
export def "api request delete" [
    name: string                   # Request name
    --collection (-c): string = "default"  # Collection name
    --force (-f)                   # Skip confirmation prompt
] {
    validate-resource-name "request" $name --nested --scope "<collection>/requests" | ignore
    validate-resource-name "collection" $collection | ignore
    let collections_dir = (get-collections-dir)
    let collection_dir = (resolve-collection-dir $collections_dir $collection)
    let requests_dir = (resolve-requests-dir $collection_dir $collection)
    let request_file = (resolve-request-file $requests_dir $name)

    if not ($request_file | path exists) {
        fail-command $"Request '($name)' not found in collection '($collection)'"
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
    $result.response.headers | transpose key value
}

# Format response as table (for JSON arrays)
export def "api table" [result: record] {
    let body = $result.response.body
    if ($body | describe | str starts-with "list") {
        $body
    } else {
        $body
    }
}

# HEAD request — returns status + headers, no body (C10)
export def "api head" [
    url: string                          # URL to request
    --headers (-H): record = {}          # Additional headers
    --auth (-a): record = {}             # Authentication config
    --raw (-r)                           # Return raw result without display
    --no-history                         # Don't save to history
    --debug                              # Show verbose debug output
    --output (-o): string = "pretty"     # Output mode: pretty|body|raw|json|headers|status|none
    --select (-s): string = ""           # Select a field (dot-path)
    --verbose (-v)                       # Show request + response headers
    --include (-I)                       # Include response headers above body
    --save (-S): string = ""             # Save response body to file
] {
    validate-output-mode $output
    if $debug { $env.API_DEBUG = true }
    let resolved_auth = (api auth get-config $auth)
    let result = (execute-request "HEAD" $url -H $headers -a $resolved_auth --no-history=$no_history)

    if $result == null {
        if $debug { $env.API_DEBUG = false }
        return null
    }

    if $debug { $env.API_DEBUG = false }
    # HEAD has no body; --include shows response headers by default in pretty mode
    if $raw or $output != "pretty" or $select != "" {
        apply-output-selection $result $output $select $raw $verbose $include $save
    } else {
        display-response $result --include --verbose=$verbose --save=$save
        null
    }
}

# OPTIONS request (C10)
export def "api options" [
    url: string                          # URL to request
    --headers (-H): record = {}          # Additional headers
    --auth (-a): record = {}             # Authentication config
    --raw (-r)                           # Return raw result without display
    --no-history                         # Don't save to history
    --debug                              # Show verbose debug output
    --output (-o): string = "pretty"     # Output mode: pretty|body|raw|json|headers|status|none
    --select (-s): string = ""           # Select a field (dot-path)
    --verbose (-v)                       # Show request + response headers
    --include (-I)                       # Include response headers above body
    --save (-S): string = ""             # Save response body to file
] {
    validate-output-mode $output
    if $debug { $env.API_DEBUG = true }
    let resolved_auth = (api auth get-config $auth)
    let result = (execute-request "OPTIONS" $url -H $headers -a $resolved_auth --no-history=$no_history)

    if $result == null {
        if $debug { $env.API_DEBUG = false }
        return null
    }

    if $debug { $env.API_DEBUG = false }
    apply-output-selection $result $output $select $raw $verbose $include $save
}

# Export a saved request as a curl command (C11)
export def "api request export" [
    name: string                         # Request name
    --collection (-c): string = "default"  # Collection name
] {
    api send $name -c $collection --dry-run
}

# Run assertion tests against a response (C7)
# Key shorthand: status → response.status, body.* → response.body.*, headers.* → response.headers.*
# Full paths starting with response.* pass through unchanged.
def run-tests [result: record, tests: record, --quiet] {
    mut passed = 0
    mut failed = 0

    for test_entry in ($tests | transpose key expected) {
        let key = $test_entry.key
        let expected = $test_entry.expected

        # Normalize key the same way --select does (consistent shorthand expansion)
        let full_key = if ($key == "status") or ($key | str starts-with "body") or ($key | str starts-with "headers") {
            "response." + $key
        } else {
            $key  # already full path (response.*, request.*) or literal
        }

        let actual = (api vars extract $result $full_key)

        let ok = if ($expected | describe) == "int" or ($expected | describe) == "string" {
            $actual == $expected
        } else if ($expected | describe | str starts-with "record") {
            mut sub_ok = true
            if ($expected.not_null? | default false) {
                if $actual == null { $sub_ok = false }
            }
            if ($expected.equals? | default null) != null {
                if $actual != $expected.equals { $sub_ok = false }
            }
            if ($expected.contains? | default null) != null {
                let actual_str = try { $actual | into string } catch { "" }
                if not ($actual_str | str contains $expected.contains) { $sub_ok = false }
            }
            if ($expected.gt? | default null) != null {
                if $actual <= $expected.gt { $sub_ok = false }
            }
            if ($expected.lt? | default null) != null {
                if $actual >= $expected.lt { $sub_ok = false }
            }
            $sub_ok
        } else {
            $actual == $expected
        }

        if $ok {
            if not $quiet { print $"(ansi green)✓(ansi reset) ($key)" }
            $passed = $passed + 1
        } else {
            let actual_str = try { $actual | into string } catch { "null" }
            let expected_str = try { $expected | into string } catch { ($expected | to json) }
            if not $quiet {
                print $"(ansi red)✗(ansi reset) ($key): expected ($expected_str | str substring 0..60), got ($actual_str | str substring 0..60)"
            }
            $failed = $failed + 1
        }
    }

    if not $quiet { print $"(ansi dark_gray)Tests: ($passed) passed, ($failed) failed(ansi reset)" }
    { passed: $passed, failed: $failed, all_passed: ($failed == 0) }
}
