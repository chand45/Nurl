# HTTP Request Module
# Core HTTP request functionality using curl

use log.nu *
use vars.nu ["api vars interpolate", "api vars extract", interpolate-record-values, interpolate-structured, interpolate-structured-json]
use auth.nu [SAML_AUTH_SCHEME prepare-auth-context redact-sensitive-headers sensitive-header validate-secret-safe-url]
use history.nu ["api history save"]
use resource-path.nu [commit-state-replace list-contained-resource-files open-state-record path-type-safe resolve-under-base save-state-replace state-base-type state-replacement-temp-path validate-resource-name]
use command-error.nu [fail-command]
use curl-capability.nu [require-curl-capability]
use string-compat.nu [ascii-equal-ignore-case ascii-upcase]

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

# Get default headers from config
def get-default-headers [] {
    let root = ($env.API_ROOT? | default (pwd))
    let config_path = ($root | path join "config.nuon")

    if ($config_path | path exists) {
        (open-state-record $config_path "config.nuon").default_headers? | default {}
    } else {
        {
            "Content-Type": "application/json"
            "Accept": "application/json"
        }
    }
}

def normalize-header-name [name: string] {
    $name | ascii-upcase
}

def assert-unique-header-names [headers: record] {
    mut observed = []
    for name in ($headers | columns) {
        if ($name | str contains "\r") or ($name | str contains "\n") {
            fail-command "Request header names must not contain carriage returns or newlines."
        }
        let value = (try { $headers | get $name | into string } catch { "" })
        if ($value | str contains "\r") or ($value | str contains "\n") {
            fail-command $"Request header '($name)' must not contain carriage returns or newlines."
        }
        let folded = (normalize-header-name $name)
        let prior = ($observed | where folded == $folded)
        if not ($prior | is-empty) {
            let previous = ($prior | first | get name)
            fail-command $"Request header record contains both '($previous)' and '($name)'; remove one."
        }
        $observed = ($observed | append {name: $name, folded: $folded})
    }
}

def header-name-present [headers: record, name: string] {
    let folded = (normalize-header-name $name)
    $headers | columns | any {|candidate| (normalize-header-name $candidate) == $folded }
}

def merge-request-headers [base: record, overlay: record] {
    assert-unique-header-names $base
    assert-unique-header-names $overlay

    let base_rows = ($base | transpose key value)
    let overlay_rows = ($overlay | transpose key value)
    let replaced = (
        $base_rows
        | reduce -f {} {|header, result|
            let matches = (
                $overlay_rows
                | where {|candidate| ascii-equal-ignore-case $candidate.key $header.key }
            )
            if ($matches | is-empty) {
                $result | upsert $header.key $header.value
            } else {
                let winner = ($matches | first)
                $result | upsert $winner.key $winner.value
            }
        }
    )
    $overlay_rows | reduce -f $replaced {|header, result|
        if (header-name-present $base $header.key) {
            $result
        } else {
            $result | upsert $header.key $header.value
        }
    }
}

def managed-auth-header-name [display_auth: record] {
    match ($display_auth.type? | default "none") {
        "bearer" | "saml" | "basic" => "Authorization"
        "apikey_header" => ($display_auth.header_name? | default null)
        _ => null
    }
}

# Get timeout from config
def get-timeout [] {
    let root = ($env.API_ROOT? | default (pwd))
    let config_path = ($root | path join "config.nuon")

    if ($config_path | path exists) {
        (open-state-record $config_path "config.nuon").timeout_seconds? | default 30
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

def validate-retry-options [retries: int, retry_delay: int] {
    if $retries < 0 {
        fail-command "Retry count must be zero or greater"
    }
    if $retry_delay < 0 {
        fail-command "Retry delay must be zero or greater"
    }
}

def with-api-debug [debug: bool, action: closure] {
    if $debug {
        with-env {API_DEBUG: true} $action
    } else {
        do $action
    }
}

def read-body-file [body_file: string] {
    if not ($body_file | path exists) {
        fail-command $"Body file '($body_file)' not found"
    }
    if (path-type-safe $body_file) == "dir" {
        fail-command $"Body file '($body_file)' must be a readable file"
    }
    try {
        open $body_file --raw | str trim
    } catch {
        fail-command $"Body file '($body_file)' could not be read"
    }
}

def encode-query-component [value: string] {
    $value
    | url encode
    | str replace --all "/" "%2F"
    | str replace --all ":" "%3A"
    | str replace --all "%2D" "-"
    | str replace --all "%5F" "_"
    | str replace --all "%7E" "~"
}

def append-query-auth [url: string, name: string, value: string, --masked] {
    let parts = ($url | split row "#")
    let base = ($parts | first)
    let fragment = if ($parts | length) > 1 {
        "#" + ($parts | skip 1 | str join "#")
    } else {
        ""
    }
    let separator = if ($base | str contains "?") {
        if ($base | str ends-with "?") or ($base | str ends-with "&") { "" } else { "&" }
    } else {
        "?"
    }
    let encoded_name = (encode-query-component $name)
    let encoded_value = if $masked { "******" } else { encode-query-component $value }
    $"($base)($separator)($encoded_name)=($encoded_value)($fragment)"
}

# Resolve body from multiple input sources (inline record/string, file)
# Priority: body-file > inline body
# Returns tagged content so interpolation happens before serialization.
def looks-like-json [content: string] {
    let trimmed = ($content | str trim)
    if ($trimmed | is-empty) {
        return false
    }
    [
        ($trimmed | str starts-with "{")
        ($trimmed | str starts-with "[")
        ($trimmed | str starts-with '"')
        ($trimmed in ["true" "false" "null"])
        ($trimmed =~ '^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$')
    ] | any {|matches| $matches }
}

def resolve-body [
    --body (-b): any = {}          # Inline body as record, list, or pre-serialized JSON string
    --body-file (-f): string = ""  # Path to file containing body
] {
    # Body file takes priority
    if $body_file != "" {
        let file_content = (read-body-file $body_file)

        let parsed = if (looks-like-json $file_content) {
            try {
                {ok: true, content: ($file_content | from json)}
            } catch {
                {ok: false, content: $file_content}
            }
        } else {
            {ok: false, content: $file_content}
        }
        if $parsed.ok {
            {kind: "structured", content: $parsed.content}
        } else {
            {kind: "text", content: $parsed.content}
        }
    } else {
        if ($body | describe) == "string" {
            {kind: "text", content: $body}
        } else if not ($body | is-empty) {
            {kind: "structured", content: $body}
        } else {
            {kind: "none", content: null}
        }
    }
}

def serialize-structured-body [content: any] {
    if (state-base-type $content) == "string" {
        $content | to json
    } else {
        $content | to json --raw
    }
}

def resolve-form-body [form: record] {
    {
        kind: "encoded"
        content: (encode-form-data (interpolate-structured $form --single-pass))
    }
}

# Build Authorization header arguments for execution or redacted display.
def append-authorization-args [
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
        "saml" => {
            let token = ($auth.token? | default null)
            if $token == null or ($token | describe) != "string" or ($token | str trim | is-empty) {
                fail-command "SAML token must be a non-empty string"
            }
            let header_value = if $redact {
                "******"
            } else {
                $"($SAML_AUTH_SCHEME) ($token)"
            }
            $args | append ["-H" $"Authorization: ($header_value)"]
        }
        _ => $args
    }
}

def assert-safe-auth-headers [auth: any] {
    if $auth == null {
        return
    }
    match ($auth.type? | default "none") {
        "bearer" => {
            let token = ($auth.token? | default "" | into string)
            if ($token | str contains "\r") or ($token | str contains "\n") {
                fail-command "Request header 'Authorization' must not contain carriage returns or newlines."
            }
            let value = if $token =~ '(?i)^Bearer\s+' { $token } else { $"******" }
            assert-unique-header-names {Authorization: $value}
        }
        "saml" => {
            let token = ($auth.token? | default "" | into string)
            if ($token | str contains "\r") or ($token | str contains "\n") {
                fail-command "Request header 'Authorization' must not contain carriage returns or newlines."
            }
            assert-unique-header-names {Authorization: $"($SAML_AUTH_SCHEME) ($token)"}
        }
        "apikey_header" => {
            let name = ($auth.header_name? | default "" | into string)
            let value = ($auth.key? | default "" | into string)
            assert-unique-header-names { $name: $value }
        }
        _ => {}
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

    if $auth != null and ($auth.type? | default "none") in ["bearer" "saml"] {
        # Bearer headers share one builder so binary and normal execution cannot diverge.
        $args = (append-authorization-args $args $auth)
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
    for header in (redact-sensitive-headers $headers | transpose key value) {
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

    if $auth != null and ($auth.type? | default "none") in ["bearer" "saml"] {
        # Display construction never receives the execution token value.
        $args = (append-authorization-args $args $auth --redact)
    }

    # Add body if provided
    if $body != null and $body != "" {
        $args = ($args | append ["-d" $body])
    }

    $args
}

def quote-posix-shell-arg [arg: string] {
    if $arg =~ '^[A-Za-z0-9_@%+:,./-]+$' {
        $arg
    } else {
        let escaped = ($arg | str replace --all "'" "'\\''")
        $"'($escaped)'"
    }
}

# Convert curl arguments to a copyable POSIX shell command string.
def curl-args-to-string [
    args: list      # The curl arguments list
    url: string     # The URL to request
] {
    mut parts = ["curl"]

    for arg in $args {
        $parts = ($parts | append (quote-posix-shell-arg ($arg | into string)))
    }

    $parts = ($parts | append (quote-posix-shell-arg $url))

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

# Build curl arguments for binary file download (no response headers, writes to a sibling temp)
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

    if $auth != null and ($auth.type? | default "none") in ["bearer" "saml"] {
        # Keep binary execution on the same bearer builder as normal requests.
        $args = (append-authorization-args $args $auth)
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
        let peek = ($body_str | str trim | str substring 0..20)
        if ($peek =~ '(?i)^<!doctype') or ($peek =~ '(?i)^<html') {
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
        } else if ($peek =~ '(?i)^<\?xml') {
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
    let required = ["status" "time_total" "size_download" "size_header" "exit_code"]
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
    {
        diagnostics: ($begin_parts | get 0 | str trim)
        metadata: $metadata
    }
}

def unframed-curl-diagnostics [stderr: string] {
    $stderr
    | split row --regex 'NURL_RESPONSE_META_[A-Za-z0-9]+_(?:BEGIN|END)'
    | first
    | str trim
}

def curl-with-fileless-metadata [
    curl_args: list
    url: string
    --include-response
    --stdin-body: any = null
] {
    let token = (random uuid | str replace --all "-" "")
    let begin = $"NURL_RESPONSE_META_($token)_BEGIN"
    let ending = $"NURL_RESPONSE_META_($token)_END"
    let write_out = (
        "%{stderr}\n"
        + $begin
        + "\n{\"status\":\"%{http_code}\",\"time_total\":\"%{time_total}\",\"size_download\":\"%{size_download}\",\"size_header\":\"%{size_header}\",\"exit_code\":\"%{exitcode}\"}\n"
        + $ending
        + "\n"
    )
    let transfer_args = if $include_response {
        $curl_args | append "--include"
    } else {
        $curl_args
    }
    let final_args = ($transfer_args | append ["--write-out" $write_out])
    let output = if $stdin_body == null {
        do { curl ...$final_args $url } | complete
    } else {
        do { $stdin_body | curl ...$final_args $url } | complete
    }
    let output_stderr = try { $output.stderr } catch { "" }
    if (($output_stderr | describe) | str starts-with "binary") {
        if $output.exit_code != 0 {
            return {
                output: ($output | upsert stderr "")
                metadata: null
            }
        }
        fail-command "Curl returned malformed structured response metadata"
    }
    let parsed_result = try {
        {
            value: (parse-fileless-curl-stderr $output_stderr $token $output.exit_code)
            error: null
        }
    } catch {|error|
        {value: null, error: $error}
    }
    if $parsed_result.error != null {
        if $output.exit_code != 0 {
            return {
                output: ($output | upsert stderr (unframed-curl-diagnostics $output_stderr))
                metadata: null
            }
        }
        error make {msg: $parsed_result.error.msg}
    }
    let parsed = $parsed_result.value
    {
        output: ($output | upsert stderr $parsed.diagnostics)
        metadata: $parsed.metadata
    }
}

def last-header-block [header_output: string] {
    let separator = if ($header_output | str contains "\r\n\r\n") {
        "\r\n\r\n"
    } else {
        "\n\n"
    }
    if not ($header_output | str ends-with $separator) {
        fail-command "Curl response header size did not end at a complete header block"
    }
    let blocks = ($header_output | split row $separator)
    let indices = (
        $blocks
        | enumerate
        | where {|block| $block.item | str trim | str starts-with "HTTP/" }
        | get index
    )
    if ($indices | is-empty) {
        fail-command "Curl returned malformed response headers"
    }
    $blocks | get ($indices | last)
}

def upsert-wire-header [headers: record, key: string, value: string] {
    let retained = (
        $headers
        | transpose key value
        | where {|header| not (ascii-equal-ignore-case $header.key $key) }
        | reduce -f {} {|header, result| $result | upsert $header.key $header.value }
    )
    $retained | upsert $key $value
}

def parse-wire-headers [header_output: string] {
    let final_block = (last-header-block $header_output)
    $final_block
    | lines
    | skip 1
    | reduce -f {} {|line, headers|
        let parts = ($line | split row ":")
        if ($parts | length) < 2 {
            $headers
        } else {
            let key = ($parts | get 0 | str trim)
            let value = ($parts | skip 1 | str join ":" | str trim)
            if ($key | is-empty) {
                $headers
            } else {
                upsert-wire-header $headers $key $value
            }
        }
    }
}

def parse-wire-trailers [trailer_bytes: binary] {
    if ($trailer_bytes | bytes length) == 0 {
        return {}
    }
    let output = try {
        $trailer_bytes | decode utf-8
    } catch {
        fail-command "Curl returned malformed response trailers"
    }
    if ($output | str trim | is-empty) {
        return {}
    }
    $output
    | lines
    | where {|line| not ($line | str trim | is-empty) }
    | reduce -f {} {|line, trailers|
        let parts = ($line | split row ":")
        if ($parts | length) < 2 {
            fail-command "Curl returned malformed response trailers"
        }
        let raw_key = ($parts | get 0)
        let key = ($raw_key | str trim)
        if ($key | is-empty) or $raw_key != $key {
            fail-command "Curl returned malformed response trailers"
        }
        let allowed = "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        let invalid_name = (
            $key
            | split chars
            | any {|character| not ($allowed | str contains $character) }
        )
        if $invalid_name {
            fail-command "Curl returned malformed response trailers"
        }
        let value = ($parts | skip 1 | str join ":" | str trim)
        upsert-wire-header $trailers $key $value
    }
}

def as-binary [value: any] {
    if (($value | describe) | str starts-with "binary") {
        $value
    } else {
        $value | encode utf-8
    }
}

def legacy-bytes-at-range-semantics [] {
    (0x[00 01] | bytes at 0..<1 | bytes length) == 0
}

def bytes-before [value: binary, end: int] {
    if $end == 0 {
        return 0x[]
    }
    if (legacy-bytes-at-range-semantics) {
        $value | bytes at 0..$end
    } else {
        $value | bytes at 0..<$end
    }
}

def bytes-between [value: binary, start: int, end: int] {
    if $start == $end {
        return 0x[]
    }
    if (legacy-bytes-at-range-semantics) {
        $value | bytes at $start..$end
    } else {
        $value | bytes at $start..<$end
    }
}

def parse-curl-response-fileless [included_output: any, metadata: record] {
    let bytes = (as-binary $included_output)
    let total_size = ($bytes | bytes length)
    let header_size = try {
        $metadata.size_header | into int
    } catch {
        fail-command "Curl returned an invalid response header size"
    }
    if $header_size < 0 or $header_size > $total_size {
        fail-command "Curl response header size did not match the transfer output"
    }
    let body_size = try {
        $metadata.size_download | into int
    } catch {
        fail-command "Curl returned an invalid response body size"
    }
    let body_end = ($header_size + $body_size)
    if $body_size < 0 or $body_end > $total_size {
        fail-command "Curl response body size did not match the transfer output"
    }

    let header_bytes = if $header_size == 0 {
        0x[]
    } else {
        bytes-before $bytes $header_size
    }
    let body_bytes = if $body_size == 0 {
        0x[]
    } else {
        bytes-between $bytes $header_size $body_end
    }
    let trailer_bytes = if $body_end == $total_size {
        0x[]
    } else {
        $bytes | bytes at $body_end..
    }
    let header_output = try {
        $header_bytes | decode utf-8
    } catch {
        fail-command "Curl returned malformed response headers"
    }
    let body_raw = if ($body_bytes | bytes length) == 0 {
        ""
    } else {
        let decoded = try {
            $body_bytes | decode utf-8
        } catch {
            null
        }
        if $decoded == null or ($decoded | encode utf-8) != $body_bytes {
            $body_bytes
        } else {
            $decoded
        }
    }
    let body = if (($body_raw | describe) | str starts-with "binary") {
        $body_raw
    } else {
        try {
            $body_raw | from json
        } catch {
            $body_raw
        }
    }
    let response_headers = (parse-wire-headers $header_output)
    let trailer_headers = (parse-wire-trailers $trailer_bytes)
    let headers = (
        $trailer_headers
        | transpose key value
        | reduce -f $response_headers {|header, result|
            upsert-wire-header $result $header.key $header.value
        }
    )
    {
        status: ($metadata.status | into int)
        status_text: (http-status-text ($metadata.status | into int))
        headers: $headers
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

def transport-secret-values [headers: record, auth: any] {
    let header_values = (
        $headers
        | transpose key value
        | where {|header| $header.key =~ '(?i)(authorization|cookie|token|secret|api[-_]?key|password)' }
        | each {|header| try { $header.value | into string } catch { "" } }
    )
    let auth_values = if $auth == null {
        []
    } else {
        $auth
        | transpose key value
        | where {|field| $field.key =~ '(?i)(token|secret|password|key)' }
        | each {|field| try { $field.value | into string } catch { "" } }
    }
    $header_values
    | append $auth_values
    | where {|value| not ($value | str trim | is-empty) }
    | uniq
}

def sanitize-transport-diagnostics [diagnostics: string, headers: record, auth: any] {
    mut safe = (
        $diagnostics
        | ansi strip
        | str replace --all --regex 'NURL_RESPONSE_META_[A-Za-z0-9]+_(BEGIN|END)' "[metadata]"
        | str replace --all --regex '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]' ""
    )
    for secret in (transport-secret-values $headers $auth) {
        $safe = ($safe | str replace --all $secret "******")
    }
    $safe = (
        $safe
        | str replace --all --regex '(?i)(https?://)[^/@\s]+:[^/@\s]+@' '$1******:******@'
        | str replace --all --regex '(?i)([?&](?:access_token|refresh_token|client_secret|api[-_]?key|token|key)=)[^&\s]+' '$1******'
        | str replace --all --regex '(?i)((?:authorization|proxy-authorization|x-api-key|api[-_]?key|access_token|refresh_token|client_secret)\s*[:=]\s*)[^\s,;]+' '$1******'
        | str trim
    )
    if ($safe | str length) > 2000 {
        ($safe | str substring 0..<2000) + "..."
    } else {
        $safe
    }
}

def fail-transport [
    exit_code: int
    attempt: int
    max_attempts: int
    diagnostics: string
    headers: record
    auth: any
] {
    let safe_diagnostics = (sanitize-transport-diagnostics $diagnostics $headers $auth)
    let detail = if ($safe_diagnostics | is-empty) {
        ""
    } else {
        $": ($safe_diagnostics)"
    }
    fail-command $"Curl transport failed with exit code ($exit_code) after ($attempt) of ($max_attempts) attempts($detail)"
}

def binary-attempt-path [destination: string] {
    let expanded = ($destination | path expand --no-symlink)
    state-replacement-temp-path $expanded
}

def remove-binary-attempt [path: string] {
    if $path != "" and ($path | path exists) {
        rm -f $path
    }
}

def parse-binary-response [metadata: record, attempt_path: string, destination: string] {
    let status = try {
        $metadata.status | into int
    } catch {
        fail-command "Curl returned an invalid binary response status"
    }
    let time_total = try {
        $metadata.time_total | into float
    } catch {
        fail-command "Curl returned an invalid binary response duration"
    }
    let expected_size = try {
        $metadata.size_download | into int
    } catch {
        fail-command "Curl returned an invalid binary response size"
    }
    if $expected_size < 0 or (path-type-safe $attempt_path) != "file" {
        fail-command "Curl did not produce a complete binary response file"
    }
    let actual_size = (ls $attempt_path | first | get size | into int)
    if $actual_size != $expected_size {
        fail-command "Curl binary response size did not match the completed transfer"
    }
    {
        status: $status
        status_text: (http-status-text $status)
        headers: {}
        body: $"[binary saved to: ($destination)]"
        time_ms: (($time_total * 1000) | math round)
        size_bytes: $expected_size
    }
}

def commit-binary-response [attempt_path: string, destination: string] {
    let destination_path = ($destination | path expand --no-symlink)
    let intended = (open $attempt_path --raw)
    commit-state-replace $intended $attempt_path $destination_path
}

# Execute HTTP request
def execute-request [
    method: string
    url: string
    --headers (-H): record = {}
    --body (-b): record = {kind: "none", content: null}
    --auth-spec: record = {}
    --no-interpolate   # Skip variable interpolation
    --url-resolved     # URL was already interpolated with --resolved-context
    --headers-resolved # Caller headers were already interpolated with --resolved-context
    --resolved-context: record = {} # Wrapper containing an authoritative `vars` record
    --no-history       # Don't save to history
    --dry-run (-d)     # Output curl command instead of executing
    --collection (-c): string = ""   # Collection context for variable resolution
    --extra-vars (-v): record = {}   # Extra variables for interpolation
    --follow-redirects (-L)          # Follow HTTP redirects (curl -L)
    --retries: int = 0               # Additional attempts after 5xx or transport failure
    --retry-delay: int = 0           # Seconds to wait between attempts
    --binary-save (-B): string = ""  # Save binary response bytes to a file
    --quiet-binary-status             # Suppress download status in data output modes
] {
    let default_headers = (get-default-headers)
    let resolved_vars = if $no_interpolate {
        {}
    } else if "vars" in ($resolved_context | columns) {
        $resolved_context.vars
    } else {
        api vars get-merged -c $collection -v $extra_vars
    }
    let single_pass = ($resolved_context.single_pass? | default false)

    # Interpolate variables with collection context
    let final_url = if $no_interpolate or $url_resolved {
        $url
    } else {
        api vars interpolate $url -e $resolved_vars --resolved
    }
    validate-secret-safe-url $final_url | ignore

    let final_headers = if $no_interpolate {
        $headers
    } else if $headers_resolved {
        let resolved_defaults = (interpolate-record-values $default_headers -e $resolved_vars --resolved --single-pass=$single_pass)
        merge-request-headers $resolved_defaults $headers
    } else {
        let all_headers = (merge-request-headers $default_headers $headers)
        interpolate-record-values $all_headers -e $resolved_vars --resolved
    }
    assert-unique-header-names $final_headers

    let display_auth_context = (prepare-auth-context $auth_spec --display-only)
    let display_auth = ($display_auth_context.display? | default {})
    assert-safe-auth-headers $auth_spec
    assert-safe-auth-headers $display_auth
    let managed_header = (managed-auth-header-name $display_auth)
    if $managed_header != null and (header-name-present $final_headers $managed_header) {
        fail-command $"Request supplies both --auth and an '($managed_header)' header; remove one."
    }
    let auth_context = if $dry_run {
        $display_auth_context
    } else {
        prepare-auth-context $auth_spec
    }
    let wire_auth = ($auth_context.wire? | default null)
    let history_auth = ($auth_context.history? | default null)
    assert-safe-auth-headers $wire_auth

    let has_sensitive_request_headers = (
        $final_headers
        | transpose key value
        | any {|header| sensitive-header $header.key $header.value }
    )

    let final_body = match $body.kind {
        "none" => ""
        "encoded" => $body.content
        "structured-encoded" => $body.content
        "text" => {
            if $no_interpolate or $body.content == "" {
                $body.content
            } else {
                api vars interpolate $body.content -e $resolved_vars --resolved
            }
        }
        "structured" => {
            let content = if $no_interpolate {
                $body.content
            } else {
                interpolate-structured-json $body.content -e $resolved_vars --resolved
            }
            serialize-structured-body $content
        }
        _ => (fail-command $"Unknown request body kind '($body.kind)'")
    }

    # Handle dry-run mode
    if $dry_run {
        let display_url = if ($display_auth.type? | default "none") == "apikey_query" {
            append-query-auth $final_url $display_auth.param_name $display_auth.key --masked
        } else {
            $final_url
        }
        let display_args = (build-curl-args-for-display $method $display_url $final_headers $final_body $display_auth)
        let curl_command = (curl-args-to-string $display_args $display_url)
        print $curl_command
        return null
    }

    let request_url = if ($wire_auth.type? | default "none") == "apikey_query" {
        append-query-auth $final_url $wire_auth.param_name $wire_auth.key
    } else {
        $final_url
    }
    let body_via_stdin = (
        (($body.kind in ["structured" "structured-encoded"]) or ($no_interpolate and (($final_body | str length) > 8000)))
        and (state-base-type $body.content) == "string"
        and $final_body != ""
    )

    # Normal and binary requests share one retry policy. Binary attempts are isolated until commit.
    let start_time = (date now)
    let max_attempts = ($retries + 1)
    mut attempt = 0

    while $attempt < $max_attempts {
        $attempt = $attempt + 1
        let attempt_path = if $binary_save == "" { "" } else { binary-attempt-path $binary_save }
        let argument_body = if $body_via_stdin { "" } else { $final_body }
        let base_args = if $binary_save == "" {
            build-curl-args $method $request_url $final_headers $argument_body $wire_auth
        } else {
            build-curl-args-binary $method $request_url $final_headers $attempt_path $argument_body $wire_auth
        }
        let body_args = if $body_via_stdin {
            $base_args | append ["--data-binary" "@-"]
        } else {
            $base_args
        }
        let curl_args = if $follow_redirects { $body_args | append "-L" } else { $body_args }
        let capture = try {
            {
                value: (curl-with-fileless-metadata $curl_args $request_url --include-response=($binary_save == "") --stdin-body=(if $body_via_stdin { $final_body } else { null }))
                error: null
            }
        } catch {|error|
            {value: null, error: $error}
        }
        if $capture.error != null {
            remove-binary-attempt $attempt_path
            error make {msg: $capture.error.msg}
        }
        let captured = $capture.value
        let output = $captured.output

        if $output.exit_code != 0 {
            remove-binary-attempt $attempt_path
            if $attempt < $max_attempts {
                if $retry_delay > 0 { sleep ($retry_delay | into duration --unit sec) }
                continue
            }
            fail-transport $output.exit_code $attempt $max_attempts $output.stderr $final_headers $wire_auth
        }

        let parse_result = try {
            {
                value: (if $binary_save == "" {
                    parse-curl-response-fileless $output.stdout $captured.metadata
                } else {
                    parse-binary-response $captured.metadata $attempt_path $binary_save
                })
                error: null
            }
        } catch {|error|
            {value: null, error: $error}
        }
        if $parse_result.error != null {
            remove-binary-attempt $attempt_path
            error make {msg: $parse_result.error.msg}
        }
        let parsed = $parse_result.value

        # Retry on 5xx if attempts remain
        if $parsed.status >= 500 and $attempt < $max_attempts {
            remove-binary-attempt $attempt_path
            if $retry_delay > 0 { sleep ($retry_delay | into duration --unit sec) }
            continue
        }

        let public_request_record = {
            method: $method
            url: $final_url
            headers: (redact-sensitive-headers $final_headers)
            body: (if $binary_save != "" {
                null
            } else if $final_body != "" {
                try { $final_body | from json } catch { $final_body }
            } else {
                null
            })
        }
        let history_body = if $binary_save != "" or $final_body == "" {
            null
        } else if ($body.kind == "structured") and ((state-base-type $body.content) in ["record" "list"]) and (not ($public_request_record.body | is-empty)) {
            $public_request_record.body
        } else {
            $final_body
        }
        let history_request_record = if $history_auth == null {
            $public_request_record | update body $history_body
        } else {
            $public_request_record | update body $history_body | insert auth $history_auth
        }
        let history_request_record = if $has_sensitive_request_headers {
            $history_request_record | insert headers_replayable false
        } else {
            $history_request_record
        }
        let response = if $binary_save == "" { $parsed | reject _raw_body } else { $parsed }
        let public_response = (
            $response | update headers (redact-sensitive-headers $response.headers)
        )
        if $binary_save != "" {
            commit-binary-response $attempt_path $binary_save
        }

        if not $no_history {
            api history save $history_request_record $public_response | ignore
        }

        let result = {
            request: $public_request_record
            response: $public_response
            timestamp: ($start_time | format date "%Y-%m-%dT%H:%M:%SZ")
        }
        if $binary_save != "" {
            if not $quiet_binary_status {
                print ((ansi green) + "Downloaded: " + $binary_save + " (" + ($response.size_bytes | into string) + "B)" + (ansi reset))
            }
            return $result
        }
        return ($result | insert _raw_body $parsed._raw_body)
    }

    fail-command "Request retry loop ended without a result"
}

export def execute-encoded-request [
    method: string
    url: string
    body: string
    headers: record
    auth: record
    --resolved-context: record = {}
    --structured-string
] {
    let body_kind = if $structured_string { "structured-encoded" } else { "encoded" }
    let result = (execute-request $method $url -H $headers -b {kind: $body_kind, content: $body} --auth-spec $auth --url-resolved --headers-resolved --resolved-context $resolved_context)
    if "_raw_body" in ($result | columns) {
        $result | reject _raw_body
    } else {
        $result
    }
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
        for hdr in (redact-sensitive-headers ($response.headers? | default {}) | transpose key value) {
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
    --binary-save (-B): string = ""      # Save binary response bytes to a file
    --retries: int = 0                   # Additional attempts after 5xx or transport failure
    --retry-delay: int = 0               # Seconds between attempts
] {
    validate-output-mode $output
    validate-retry-options $retries $retry_delay
    require-curl-capability --dry-run=$dry_run
    with-api-debug $debug {
        let data_output = ($raw or $select != "" or $output != "pretty")
        let result = (execute-request "GET" $url -H $headers --auth-spec $auth --no-history=$no_history --dry-run=$dry_run --follow-redirects=$follow_redirects --retries=$retries --retry-delay=$retry_delay --binary-save=$binary_save --quiet-binary-status=$data_output)
        if $result == null { return null }
        apply-output-selection $result $output $select $raw $verbose $include $save
    }
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
    --binary-save (-B): string = ""      # Save binary response bytes to a file
    --retries: int = 0                   # Additional attempts after 5xx or transport failure
    --retry-delay: int = 0               # Seconds between attempts
] {
    validate-output-mode $output
    validate-retry-options $retries $retry_delay
    require-curl-capability --dry-run=$dry_run
    if $body_file != "" { read-body-file $body_file | ignore }
    with-api-debug $debug {
        # Form encoding takes precedence over --body/--body-file
        let final_body = if not ($form | is-empty) {
            resolve-form-body $form
        } else {
            resolve-body -b $body -f $body_file
        }
        # Override Content-Type header for form encoding
        let req_headers = if not ($form | is-empty) {
            merge-request-headers $headers {"Content-Type": "application/x-www-form-urlencoded"}
        } else { $headers }

        let data_output = ($raw or $select != "" or $output != "pretty")
        let result = (execute-request "POST" $url -H $req_headers -b $final_body --auth-spec $auth --no-history=$no_history --dry-run=$dry_run --follow-redirects=$follow_redirects --retries=$retries --retry-delay=$retry_delay --binary-save=$binary_save --quiet-binary-status=$data_output)
        if $result == null { return null }
        apply-output-selection $result $output $select $raw $verbose $include $save
    }
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
    --binary-save (-B): string = ""      # Save binary response bytes to a file
    --retries: int = 0                   # Additional attempts after 5xx or transport failure
    --retry-delay: int = 0               # Seconds between attempts
] {
    validate-output-mode $output
    validate-retry-options $retries $retry_delay
    require-curl-capability --dry-run=$dry_run
    if $body_file != "" { read-body-file $body_file | ignore }
    with-api-debug $debug {
        let final_body = if not ($form | is-empty) {
            resolve-form-body $form
        } else {
            resolve-body -b $body -f $body_file
        }
        let req_headers = if not ($form | is-empty) {
            merge-request-headers $headers {"Content-Type": "application/x-www-form-urlencoded"}
        } else { $headers }

        let data_output = ($raw or $select != "" or $output != "pretty")
        let result = (execute-request "PUT" $url -H $req_headers -b $final_body --auth-spec $auth --no-history=$no_history --dry-run=$dry_run --follow-redirects=$follow_redirects --retries=$retries --retry-delay=$retry_delay --binary-save=$binary_save --quiet-binary-status=$data_output)
        if $result == null { return null }
        apply-output-selection $result $output $select $raw $verbose $include $save
    }
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
    --binary-save (-B): string = ""      # Save binary response bytes to a file
    --retries: int = 0                   # Additional attempts after 5xx or transport failure
    --retry-delay: int = 0               # Seconds between attempts
] {
    validate-output-mode $output
    validate-retry-options $retries $retry_delay
    require-curl-capability --dry-run=$dry_run
    if $body_file != "" { read-body-file $body_file | ignore }
    with-api-debug $debug {
        let final_body = if not ($form | is-empty) {
            resolve-form-body $form
        } else {
            resolve-body -b $body -f $body_file
        }
        let req_headers = if not ($form | is-empty) {
            merge-request-headers $headers {"Content-Type": "application/x-www-form-urlencoded"}
        } else { $headers }

        let data_output = ($raw or $select != "" or $output != "pretty")
        let result = (execute-request "PATCH" $url -H $req_headers -b $final_body --auth-spec $auth --no-history=$no_history --dry-run=$dry_run --follow-redirects=$follow_redirects --retries=$retries --retry-delay=$retry_delay --binary-save=$binary_save --quiet-binary-status=$data_output)
        if $result == null { return null }
        apply-output-selection $result $output $select $raw $verbose $include $save
    }
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
    --retries: int = 0                   # Additional attempts after 5xx or transport failure
    --retry-delay: int = 0               # Seconds between attempts
] {
    validate-output-mode $output
    validate-retry-options $retries $retry_delay
    require-curl-capability --dry-run=$dry_run
    with-api-debug $debug {
        let result = (execute-request "DELETE" $url -H $headers --auth-spec $auth --no-history=$no_history --dry-run=$dry_run --follow-redirects=$follow_redirects --retries=$retries --retry-delay=$retry_delay)
        if $result == null { return null }
        apply-output-selection $result $output $select $raw $verbose $include ""
    }
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
    --no-interpolate                     # Replay already-resolved URL, headers, and body values exactly
    --dry-run (-d)                       # Output curl command instead of executing
    --debug                              # Show verbose debug output
    --form (-F): record = {}             # Form-encoded body (application/x-www-form-urlencoded)
    --output (-o): string = "pretty"     # Output mode: pretty|body|raw|json|headers|status|none
    --select (-s): string = ""           # Select a field (dot-path)
    --verbose (-v)                       # Show request + response headers
    --include (-I)                       # Include response headers above body
    --follow-redirects (-L)              # Follow HTTP redirects
    --save (-S): string = ""             # Save response body to file
    --binary-save (-B): string = ""      # Save binary response bytes to a file
    --retries: int = 0                   # Additional attempts after 5xx or transport failure
    --retry-delay: int = 0               # Seconds between attempts
] {
    validate-output-mode $output
    validate-retry-options $retries $retry_delay
    require-curl-capability --dry-run=$dry_run
    if $body_file != "" { read-body-file $body_file | ignore }
    with-api-debug $debug {
        let final_body = if not ($form | is-empty) {
            resolve-form-body $form
        } else {
            resolve-body -b $body -f $body_file
        }
        let req_headers = if not ($form | is-empty) {
            merge-request-headers $headers {"Content-Type": "application/x-www-form-urlencoded"}
        } else { $headers }

        let data_output = ($raw or $select != "" or $output != "pretty")
        let result = (execute-request $method $url -H $req_headers -b $final_body --auth-spec $auth --no-interpolate=$no_interpolate --no-history=$no_history --dry-run=$dry_run --follow-redirects=$follow_redirects --retries=$retries --retry-delay=$retry_delay --binary-save=$binary_save --quiet-binary-status=$data_output)
        if $result == null { return null }
        apply-output-selection $result $output $select $raw $verbose $include $save
    }
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
    --binary-save (-B): string = ""      # Save binary response bytes to a file
    --retries: int = 0                   # Additional attempts after 5xx or transport failure
    --retry-delay: int = 0               # Seconds between attempts
] {
    validate-output-mode $output
    validate-retry-options $retries $retry_delay
    require-curl-capability --dry-run=$dry_run
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
    with-api-debug $debug {
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
            mut found_file: string = ""
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

            if ($found_file | is-empty) {
                fail-command $"Request '($name)' not found"
            }

            $found_file
        }

        if not ($request_path | path exists) {
            fail-command $"Request '($name)' not found"
        }

        # Load request
        let request = (open-state-record $request_path $"request '($name)'")
        let headers = ($request.headers? | default {})
        let body = if $has_body_override {
            $resolved_body_override
        } else if ($request.body?.content? | default null) != null {
            {kind: "structured", content: $request.body.content}
        } else {
            {kind: "none", content: null}
        }
        let effective_auth = if not ($auth | is-empty) {
            $auth
        } else if ($request.auth? | default null) != null {
            $request.auth
        } else {
            {}
        }
        let data_output = ($raw or $select != "" or $output != "pretty")
        let result = (execute-request ($request.method? | default "GET") $request.url -H $headers -b $body --auth-spec $effective_auth --dry-run=$dry_run -c $coll_name -v $vars --no-history=$no_history --follow-redirects=$follow_redirects --retries=$retries --retry-delay=$retry_delay --binary-save=$binary_save --quiet-binary-status=$data_output)
        if $result == null { return null }

        # Run tests if defined (C7)
        mut final_result = $result
        if ($request.tests? | default null) != null and ($request.tests | describe | str starts-with "record") {
            let tests_quiet = ($raw or ($output != "pretty"))
            let test_results = (run-tests $result $request.tests --quiet=$tests_quiet)
            $final_result = ($result | upsert tests_passed $test_results.all_passed)
            if (not $tests_quiet) and (not $test_results.all_passed) {
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

        apply-output-selection $final_result $output $select $raw $verbose $include $save
    }
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
    with-api-debug $debug {
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
    }
}

# List saved requests
export def "api request list" [
    --collection (-c): string = ""  # Filter by collection
    --debug                         # Show verbose output
] {
    if $collection != "" {
        validate-resource-name "collection" $collection | ignore
    }
    with-api-debug $debug {
        let collections_dir = (get-collections-dir)

        if not ($collections_dir | path exists) {
            log warn "No collections found"
            return []
        }

        let requests = if $collection != "" {
            let collection_dir = (resolve-collection-dir $collections_dir $collection)
            let requests_dir = (resolve-requests-dir $collection_dir $collection)
            if ($requests_dir | path exists) {
                list-request-files $requests_dir | each {|file|
                    let req = (open-state-record $file.path $"request '($file.name)' in collection '($collection)'")
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
                        let req = (open-state-record $file.path $"request '($file.name)' in collection '($coll_name)'")
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

        if ($requests | is-empty) {
            print $"(ansi yellow)No requests found(ansi reset)"
            return []
        }

        $requests
    }
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

    if ($request_file == null) or (not ($request_file | path exists)) {
        let scope = if $collection != "" { $"collection '($collection)'" } else { "any collection" }
        fail-command $"Request '($name)' not found in ($scope)"
    }

    open-state-record $request_file $"request '($name)'"
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

    mut req = (open-state-record $request_file $"request '($name)' in collection '($collection)'")

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
        } else if ($body != null) and (not ($body | is-empty)) {
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
    save-state-replace ($req | to nuon --indent 4) $request_file

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
    --dry-run (-d)                       # Output curl command instead of executing
    --debug                              # Show verbose debug output
    --output (-o): string = "pretty"     # Output mode: pretty|body|raw|json|headers|status|none
    --select (-s): string = ""           # Select a field (dot-path)
    --verbose (-v)                       # Show request + response headers
    --include (-I)                       # Include response headers above body
    --save (-S): string = ""             # Save response body to file
] {
    validate-output-mode $output
    require-curl-capability --dry-run=$dry_run
    with-api-debug $debug {
        let result = (execute-request "HEAD" $url -H $headers --auth-spec $auth --no-history=$no_history --dry-run=$dry_run)
        if $result == null { return null }
        if $raw or $output != "pretty" or $select != "" {
            apply-output-selection $result $output $select $raw $verbose $include $save
        } else {
            display-response $result --include --verbose=$verbose --save=$save
            null
        }
    }
}

# OPTIONS request (C10)
export def "api options" [
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
    --save (-S): string = ""             # Save response body to file
] {
    validate-output-mode $output
    require-curl-capability --dry-run=$dry_run
    with-api-debug $debug {
        let result = (execute-request "OPTIONS" $url -H $headers --auth-spec $auth --no-history=$no_history --dry-run=$dry_run)
        if $result == null { return null }
        apply-output-selection $result $output $select $raw $verbose $include $save
    }
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
