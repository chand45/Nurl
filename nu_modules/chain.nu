# Request Chaining Module
# Execute sequences of requests with variable extraction and passing

use vars.nu ["api vars interpolate", "api vars extract", interpolate-record-values, interpolate-structured-json]
use http.nu [execute-encoded-request]
use auth.nu [validate-secret-safe-url]
use resource-path.nu [open-state-record open-state-value path-type-safe resolve-under-base state-base-type validate-resource-name]
use command-error.nu [fail-command]
use curl-capability.nu [require-curl-capability]
use string-compat.nu [optional-get]

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

def get-chains-dir [] {
    resolve-under-base (get-api-root) "chains" "chains directory" --scope "API workspace"
}

def resolve-chain-file [chains_dir: string, name: string] {
    resolve-under-base $chains_dir $name "chain" --suffix ".nuon" --always-suffix --scope "API workspace chains" --base-is-canonical
}

def validate-chain-steps [steps: list] {
    for step in $steps {
        if "request" in ($step | columns) {
            validate-resource-name "request" $step.request --nested --scope "<collection>/requests" | ignore
        }
    }
}

def normalize-chain-state [value: any, path: string] {
    let base_type = (state-base-type $value)
    if $base_type != "record" and $base_type not-in ["list" "table"] {
        fail-command $"Invalid chain state at '($path)': expected a NUON record or list. Repair or replace the file."
    }

    let steps = if $base_type == "record" {
        $value.steps? | default []
    } else {
        $value
    }
    if (state-base-type $steps) not-in ["list" "table"] {
        fail-command $"Invalid chain state at '($path)': expected steps to be a NUON list. Repair or replace the file."
    }

    {
        value: $value
        base_type: $base_type
        steps: $steps
    }
}

def is-transport-failure [error: record] {
    ($error.msg? | default "") | str starts-with "Curl transport failed"
}

# Execute a chain of requests
export def "api chain run" [
    steps: list  # List of chain steps
    --stop-on-error (-s)   # Stop execution on first error
    --quiet (-q)           # Suppress output
    --collection (-c): string = ""  # Collection context for variable resolution
] {
    require-curl-capability
    if $collection != "" {
        validate-resource-name "collection" $collection | ignore
    }
    validate-chain-steps $steps

    mut context = {}  # Variables extracted from responses
    mut results = []
    mut step_num = 0
    mut chain_success = true
    mut chain_error = ""

    for step in $steps {
        $step_num = $step_num + 1

        # Get request configuration and determine collection context
        mut step_collection = $collection
        let saved_request = "request" in ($step | columns)
        let request_name = if $saved_request { $step.request } else { "" }
        let request_config = if $saved_request {
            # Load saved request (and get collection name)
            let loaded = (load-saved-request-with-collection $request_name)
            if $loaded != null and $step_collection == "" {
                $step_collection = ($loaded | optional-get "collection" | default "")
            }
            if $loaded == null { null } else { $loaded | optional-get "request" }
        } else {
            # Use inline request config
            $step
        }

        if $request_config == null {
            let message = $"Request not found: ($request_name)"
            if not $quiet {
                print -e $message
            }
            $chain_success = false
            $chain_error = $message
            if $stop_on_error {
                return { success: false, results: $results, context: $context, error: $message }
            }
            continue
        }

        # Resolve use bindings once against globals, collection variables, and prior extracts.
        let context_vars = (api vars get-merged -c $step_collection -v $context)
        let raw_step_vars = ($step | optional-get "use" | default {})
        let step_vars = (interpolate-record-values $raw_step_vars -e $context_vars --resolved --single-pass)
        let resolved_vars = ($context_vars | merge $step_vars)
        let request_url = ($request_config | get "url")
        let url = (api vars interpolate $request_url -e $resolved_vars --resolved --single-pass)
        validate-secret-safe-url $url | ignore

        if not $quiet {
            let display_name = if $saved_request { $request_name } else { "inline request" }
            print $"(ansi blue)Step ($step_num): ($display_name)(ansi reset)"
        }

        # Interpolate headers with collection context
        let request_headers = ($request_config | optional-get "headers")
        let headers = if $request_headers != null {
            interpolate-record-values $request_headers -e $resolved_vars --resolved --single-pass
        } else {
            {}
        }

        # Resolve structured values before compact serialization, then send the encoded bytes once.
        let request_body = ($request_config | optional-get "body")
        let has_body_content = $request_body != null and ("content" in ($request_body | columns))
        let body_content = if $has_body_content { $request_body | get "content" } else { null }
        let body_type_hint = if $request_body == null { null } else { $request_body | optional-get "type" }
        let body_resolution = if $has_body_content {
            let body_type = (state-base-type $body_content)
            if $body_type_hint == "json" or $body_type in ["record" "list" "table"] {
                let resolved_body = (interpolate-structured-json $body_content -e $resolved_vars --resolved)
                let resolved_type = (state-base-type $resolved_body)
                {
                    content: (if $resolved_type == "string" { $resolved_body | to json } else { $resolved_body | to json --raw })
                    structured_string: ($resolved_type == "string")
                }
            } else {
                {
                    content: (api vars interpolate ($body_content | into string) -e $resolved_vars --resolved --single-pass)
                    structured_string: false
                }
            }
        } else {
            {content: "", structured_string: false}
        }

        # Get auth config
        let auth = ($request_config | optional-get "auth" | default {})

        # Execute request
        let method = ($request_config | optional-get "method" | default "GET")

        if not $quiet {
            print $"  (ansi dark_gray)($method) ($url)(ansi reset)"
        }

        let attempted = if $stop_on_error {
            {
                result: (execute-encoded-request $method $url $body_resolution.content $headers $auth --resolved-context {vars: $resolved_vars, single_pass: true} --structured-string=$body_resolution.structured_string)
                error: null
            }
        } else {
            try {
                {
                    result: (execute-encoded-request $method $url $body_resolution.content $headers $auth --resolved-context {vars: $resolved_vars, single_pass: true} --structured-string=$body_resolution.structured_string)
                    error: null
                }
            } catch {|error|
                if not (is-transport-failure $error) {
                    error make {msg: $error.msg}
                }
                {result: null, error: $error}
            }
        }

        if $attempted.error != null {
            let message = $attempted.error.msg
            $chain_success = false
            $chain_error = $message
            $results = ($results | append {
                step: $step_num
                request: (if $saved_request { $request_name } else { "inline" })
                status: null
                time_ms: 0
                response: null
                error: $message
            })
            if not $quiet {
                print -e $message
            }
            continue
        }
        let result = $attempted.result

        # Check for HTTP errors if stop-on-error is set
        if $stop_on_error and ($result.response.status >= 400) {
            if not $quiet {
                print $"(ansi red)HTTP Error: ($result.response.status)(ansi reset)"
            }
            return { success: false, results: $results, context: $context, error: $"HTTP ($result.response.status)" }
        }

        if not $quiet {
            let status_color = if $result.response.status >= 200 and $result.response.status < 300 {
                "green"
            } else {
                "red"
            }
            print $"  (ansi $status_color)($result.response.status)(ansi reset) in ($result.response.time_ms)ms"
        }

        # Extract variables from response
        let step_extract = ($step | optional-get "extract")
        let request_chain = ($request_config | optional-get "chain")
        let chain_extract = if $request_chain == null { null } else { $request_chain | optional-get "extract" }
        let extract_config = ($step_extract | default $chain_extract)

        if $extract_config != null {
            for item in ($extract_config | transpose key path) {
                let value = (api vars extract $result.response $item.path)
                if $value != null {
                    $context = ($context | upsert $item.key $value)
                    if not $quiet {
                        print $"  (ansi dark_gray)Extracted: ($item.key) = ($value | to nuon)(ansi reset)"
                    }
                }
            }
        }

        # Add result to list
        $results = ($results | append {
            step: $step_num
            request: (if $saved_request { $request_name } else { "inline" })
            status: $result.response.status
            time_ms: $result.response.time_ms
            response: $result.response
        })

        # Check for delay between requests
        let delay_ms = ($step | optional-get "delay_ms" | default 0)
        if $delay_ms > 0 {
            sleep ($delay_ms | into duration --unit ms)
        }
    }

    if not $quiet {
        print ""
        if $chain_success {
            print $"(ansi green)Chain completed: ($results | length) requests(ansi reset)"
        } else {
            print $"(ansi yellow)Chain completed with failures: ($results | length) steps recorded(ansi reset)"
        }
    }

    let summary = {
        success: $chain_success
        results: $results
        context: $context
    }
    if ($chain_error | is-empty) {
        $summary
    } else {
        $summary | insert error $chain_error
    }
}

# Execute chain from file
export def "api chain exec" [
    file: string  # Path to chain definition file
    --stop-on-error (-s)
    --quiet (-q)
] {
    require-curl-capability
    let root = (get-api-root)
    let normalized = ($file | str replace --all "\\" "/")
    let explicit_syntax = (
        ($normalized | str starts-with "/")
        or ($normalized =~ '^[A-Za-z]:')
        or (($normalized | split row "/" | length) > 1)
    )

    let file_path = if not $explicit_syntax {
        validate-resource-name "chain" $file | ignore
        let chains_dir = (get-chains-dir)
        let named_file = (resolve-chain-file $chains_dir $file)
        if not ($named_file | path exists) {
            fail-command $"Chain file not found: ($file)"
        }
        $named_file
    } else {
        # Explicit path syntax remains path-taking input and is not confined to the workspace.
        let direct_type = (path-type-safe $file)
        let root_relative = ($root | path join $file)
        let root_relative_type = (path-type-safe $root_relative)
        let chains_relative = ($root | path join "chains" $file)
        let chains_relative_type = (path-type-safe $chains_relative)
        let chains_relative_with_suffix = ($root | path join "chains" $"($file).nuon")
        let chains_relative_with_suffix_type = (path-type-safe $chains_relative_with_suffix)

        if (not ($direct_type | is-empty)) and $direct_type != "dir" {
            $file
        } else if (not ($root_relative_type | is-empty)) and $root_relative_type != "dir" {
            $root_relative
        } else if (not ($chains_relative_type | is-empty)) and $chains_relative_type != "dir" {
            $chains_relative
        } else if (not ($chains_relative_with_suffix_type | is-empty)) and $chains_relative_with_suffix_type != "dir" {
            $chains_relative_with_suffix
        } else {
            fail-command $"Chain file not found: ($file)"
        }
    }

    let chain = (normalize-chain-state (open-state-value $file_path "chain state") $file_path)
    validate-chain-steps $chain.steps

    if not $quiet {
        let display_name = if $chain.base_type == "record" {
            $chain.value.name? | default $file
        } else {
            $file
        }
        let description = if $chain.base_type == "record" {
            $chain.value.description? | default ""
        } else {
            ""
        }
        print $"(ansi blue)Running chain: ($display_name)(ansi reset)"
        if $description != "" {
            print $description
        }
        print ""
    }

    api chain run $chain.steps --stop-on-error=$stop_on_error --quiet=$quiet
}

# Load saved request by name (returns just the request)
def load-saved-request [name: string] {
    let result = (load-saved-request-with-collection $name)
    $result.request? | default null
}

# Load saved request by name and return collection name too
def load-saved-request-with-collection [name: string] {
    validate-resource-name "request" $name --nested --scope "<collection>/requests" | ignore
    let collections_dir = (get-collections-dir)

    if not ($collections_dir | path exists) {
        return null
    }

    # Search through all collections for the request
    let colls = try { ls $collections_dir | where type == dir | get name } catch { [] }
    for discovered_path in $colls {
        let collection = ($discovered_path | path basename)
        let coll_path = (resolve-collection-dir $collections_dir $collection)
        let requests_dir = (resolve-requests-dir $coll_path $collection)
        if ($requests_dir | path exists) {
            let request_file = (resolve-under-base $requests_dir $name "request" --nested --suffix ".nuon" --always-suffix --scope "<collection>/requests" --base-is-canonical)
            if ($request_file | path exists) {
                return {
                    request: (open-state-record $request_file $"request '($name)' in collection '($collection)'")
                    collection: $collection
                }
            }
        }
    }

    null
}

# Create a chain file
export def "api chain create" [
    name: string                    # Chain name
    --description (-d): string = "" # Chain description
] {
    validate-resource-name "chain" $name | ignore
    let chains_dir = (get-chains-dir)
    let file_path = (resolve-chain-file $chains_dir $name)

    if not ($chains_dir | path exists) {
        mkdir $chains_dir
    }

    if ($file_path | path exists) {
        fail-command $"Chain '($name)' already exists"
    }

    let serialized = ({
        name: $name
        description: $description
        created_at: (date now | format date "%Y-%m-%dT%H:%M:%SZ")
        steps: [
            {
                request: "example-request"
                extract: {
                    token: "body.access_token"
                }
            }
            {
                request: "another-request"
                use: {
                    bearer_token: "{{token}}"
                }
            }
        ]
    } | to nuon)
    # Nushell has no portable atomic create-new primitive. This intentionally
    # retains main's direct-save TOCTOU behavior without adding coordination.
    try {
        $serialized | save $file_path
    } catch {|error|
        if ($error.msg? | default "") == "Destination file already exists" {
            fail-command $"Chain '($name)' already exists"
        }
        error make $error.raw
    }

    print $"(ansi green)Chain '($name)' created at: ($file_path)(ansi reset)"
    print "Edit the file to define your request chain."
}

# List available chains
export def "api chain list" [] {
    let chains_dir = (get-chains-dir)

    if not ($chains_dir | path exists) {
        print "(ansi yellow)No chains found. Create one with: api chain create <name>(ansi reset)"
        return []
    }

    let files = try { ls $chains_dir | where name =~ '\.nuon$' | get name } catch { [] }

    if ($files | is-empty) {
        print "(ansi yellow)No chains found(ansi reset)"
        return []
    }

    $files | each {|file|
        let logical_name = ($file | path basename | str replace -r '\.nuon$' '')
        let resolved_file = (resolve-chain-file $chains_dir $logical_name)
        let chain = (normalize-chain-state (open-state-value $resolved_file "chain state") $resolved_file)

        {
            name: (if $chain.base_type == "record" { $chain.value.name? | default $logical_name } else { $logical_name })
            description: (if $chain.base_type == "record" { $chain.value.description? | default "" } else { "" })
            steps: ($chain.steps | length)
        }
    }
}

# Show chain details
export def "api chain show" [name: string] {
    validate-resource-name "chain" $name | ignore
    let chains_dir = (get-chains-dir)
    let file_path = (resolve-chain-file $chains_dir $name)

    if not ($file_path | path exists) {
        fail-command $"Chain '($name)' not found"
    }

    let chain = (normalize-chain-state (open-state-value $file_path "chain state") $file_path)
    $chain.value
}

# Delete a chain
export def "api chain delete" [
    name: string  # Chain name
    --force (-f)  # Skip confirmation
] {
    validate-resource-name "chain" $name | ignore
    let chains_dir = (get-chains-dir)
    let file_path = (resolve-chain-file $chains_dir $name)

    if not ($file_path | path exists) {
        fail-command $"Chain '($name)' not found"
    }

    if not $force {
        let confirm = (input $"Delete chain '($name)'? [y/N] ")
        if $confirm !~ "^[yY]" {
            print "Cancelled"
            return
        }
    }

    rm $file_path
    print $"(ansi green)Chain '($name)' deleted(ansi reset)"
}
