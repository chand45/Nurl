# Request Chaining Module
# Execute sequences of requests with variable extraction and passing

use vars.nu ["api vars interpolate", "api vars interpolate-record", "api vars extract"]
use http.nu ["api request"]
use resource-path.nu [validate-resource-name resolve-under-base]
use command-error.nu [fail-command]
use curl-capability.nu [require-curl-capability]

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
        let request_name = ($step.request? | default null)
        if $request_name != null {
            validate-resource-name "request" $request_name --nested --scope "<collection>/requests" | ignore
        }
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

        if not $quiet {
            print $"(ansi blue)Step ($step_num): ($step.request? | default 'inline request')(ansi reset)"
        }

        # Get request configuration and determine collection context
        mut step_collection = $collection
        let request_config = if ($step.request? | default null) != null {
            # Load saved request (and get collection name)
            let loaded = (load-saved-request-with-collection $step.request)
            if $loaded != null and $step_collection == "" {
                $step_collection = ($loaded.collection? | default "")
            }
            $loaded.request? | default null
        } else {
            # Use inline request config
            $step
        }

        if $request_config == null {
            let message = $"Request not found: ($step.request)"
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

        # Merge context variables with step-specific variables
        let step_vars = ($step.use? | default {})
        let all_vars = ($context | merge $step_vars)

        # Interpolate URL with collection context
        let url = (api vars interpolate ($request_config.url? | default "") -v $all_vars -c $step_collection)

        # Interpolate headers with collection context
        let headers = if ($request_config.headers? | default null) != null {
            api vars interpolate-record $request_config.headers -v $all_vars -c $step_collection
        } else {
            {}
        }

        # Interpolate body with collection context
        let body = if ($request_config.body?.content? | default null) != null {
            if ($request_config.body.content | describe | str starts-with "record") or ($request_config.body.content | describe | str starts-with "list") {
                let interpolated = (api vars interpolate-record $request_config.body.content -v $all_vars -c $step_collection)
                $interpolated | to json
            } else {
                api vars interpolate ($request_config.body.content | into string) -v $all_vars -c $step_collection
            }
        } else {
            ""
        }

        # Get auth config
        let auth = ($request_config.auth? | default {})

        # Execute request
        let method = ($request_config.method? | default "GET")

        if not $quiet {
            print $"  (ansi dark_gray)($method) ($url)(ansi reset)"
        }

        let attempted = if $stop_on_error {
            {
                result: (api request -m $method $url -b $body -H $headers -a $auth --raw)
                error: null
            }
        } else {
            try {
                {
                    result: (api request -m $method $url -b $body -H $headers -a $auth --raw)
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
                request: ($step.request? | default "inline")
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
        let extract_config = ($step.extract? | default ($request_config.chain?.extract? | default null))

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
            request: ($step.request? | default "inline")
            status: $result.response.status
            time_ms: $result.response.time_ms
            response: $result.response
        })

        # Check for delay between requests
        if ($step.delay_ms? | default 0) > 0 {
            sleep ($step.delay_ms | into duration --unit ms)
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
        let direct_type = ($file | path type)
        let root_relative = ($root | path join $file)
        let root_relative_type = ($root_relative | path type)
        let chains_relative = ($root | path join "chains" $file)
        let chains_relative_type = ($chains_relative | path type)
        let chains_relative_with_suffix = ($root | path join "chains" $"($file).nuon")
        let chains_relative_with_suffix_type = ($chains_relative_with_suffix | path type)

        if ($direct_type | is-not-empty) and $direct_type != "dir" {
            $file
        } else if ($root_relative_type | is-not-empty) and $root_relative_type != "dir" {
            $root_relative
        } else if ($chains_relative_type | is-not-empty) and $chains_relative_type != "dir" {
            $chains_relative
        } else if ($chains_relative_with_suffix_type | is-not-empty) and $chains_relative_with_suffix_type != "dir" {
            $chains_relative_with_suffix
        } else {
            fail-command $"Chain file not found: ($file)"
        }
    }

    let chain_def = (open $file_path)
    let steps = ($chain_def.steps? | default $chain_def)
    validate-chain-steps $steps

    if not $quiet {
        print $"(ansi blue)Running chain: ($chain_def.name? | default $file)(ansi reset)"
        if ($chain_def.description? | default "") != "" {
            print $"($chain_def.description)"
        }
        print ""
    }

    api chain run $steps --stop-on-error=$stop_on_error --quiet=$quiet
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
                    request: (open $request_file)
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

    {
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
    } | to nuon | save $file_path

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
        let chain = try {
            open $resolved_file
        } catch {
            { name: $logical_name, description: "", steps: [] }
        }

        {
            name: ($chain.name? | default $logical_name)
            description: ($chain.description? | default "")
            steps: ($chain.steps? | default [] | length)
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

    open $file_path
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
