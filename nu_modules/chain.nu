# Request Chaining Module
# Execute sequences of requests with variable extraction and passing

# Execute a chain of requests
export def "api chain run" [
    steps: list  # List of chain steps
    --stop-on-error (-s)  # Stop execution on first error
    --quiet (-q)          # Suppress output
] {
    mut context = {}  # Variables extracted from responses
    mut results = []
    mut step_num = 0

    for step in $steps {
        $step_num = $step_num + 1

        if not $quiet {
            print $"(ansi blue)Step ($step_num): ($step.request? | default 'inline request')(ansi reset)"
        }

        # Get request configuration
        let request_config = if ($step.request? | default null) != null {
            # Load saved request
            load-saved-request $step.request
        } else {
            # Use inline request config
            $step
        }

        if $request_config == null {
            print $"(ansi red)Request not found: ($step.request)(ansi reset)"
            if $stop_on_error {
                return { success: false, results: $results, context: $context, error: $"Request not found: ($step.request)" }
            }
            continue
        }

        # Merge context variables with step-specific variables
        let step_vars = ($step.use? | default {})
        let all_vars = ($context | merge $step_vars)

        # Interpolate URL
        let url = (api vars interpolate ($request_config.url? | default "") -v $all_vars)

        # Interpolate headers
        let headers = if ($request_config.headers? | default null) != null {
            api vars interpolate-record $request_config.headers -v $all_vars
        } else {
            {}
        }

        # Interpolate body
        let body = if ($request_config.body?.content? | default null) != null {
            if ($request_config.body.content | describe | str starts-with "record") or ($request_config.body.content | describe | str starts-with "list") {
                let interpolated = (api vars interpolate-record $request_config.body.content -v $all_vars)
                $interpolated | to json
            } else {
                api vars interpolate ($request_config.body.content | into string) -v $all_vars
            }
        } else {
            ""
        }

        # Get auth config
        let auth = if ($request_config.auth? | default null) != null {
            api auth get-config $request_config.auth
        } else {
            {}
        }

        # Execute request
        let method = ($request_config.method? | default "GET")

        if not $quiet {
            print $"  (ansi dark_gray)($method) ($url)(ansi reset)"
        }

        let result = (api request -m $method $url -b $body -H $headers -a $auth --raw)

        if $result == null {
            print $"(ansi red)Request failed(ansi reset)"
            if $stop_on_error {
                return { success: false, results: $results, context: $context, error: "Request failed" }
            }
            continue
        }

        # Check for HTTP errors if stop-on-error is set
        if $stop_on_error and ($result.response.status >= 400) {
            print $"(ansi red)HTTP Error: ($result.response.status)(ansi reset)"
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
        print $"(ansi green)Chain completed: ($results | length) requests(ansi reset)"
    }

    {
        success: true
        results: $results
        context: $context
    }
}

# Execute chain from file
export def "api chain exec" [
    file: string  # Path to chain definition file
    --stop-on-error (-s)
    --quiet (-q)
] {
    let root = ($env.API_ROOT? | default (pwd))

    # Try to find the file
    let file_path = if ($file | path exists) {
        $file
    } else if (($root | path join $file) | path exists) {
        $root | path join $file
    } else if (($root | path join "chains" $file) | path exists) {
        $root | path join "chains" $file
    } else if (($root | path join "chains" $"($file).nuon") | path exists) {
        $root | path join "chains" $"($file).nuon"
    } else {
        print $"(ansi red)Chain file not found: ($file)(ansi reset)"
        return null
    }

    let chain_def = (open $file_path)

    if not $quiet {
        print $"(ansi blue)Running chain: ($chain_def.name? | default $file)(ansi reset)"
        if ($chain_def.description? | default "") != "" {
            print $"($chain_def.description)"
        }
        print ""
    }

    let steps = ($chain_def.steps? | default $chain_def)

    api chain run $steps --stop-on-error=$stop_on_error --quiet=$quiet
}

# Load saved request by name
def load-saved-request [name: string] {
    let root = ($env.API_ROOT? | default (pwd))
    let collections_dir = ($root | path join "collections")

    if not ($collections_dir | path exists) {
        return null
    }

    # Search through all collections for the request
    let colls = try { ls $collections_dir | where type == dir | get name } catch { [] }
    for coll_path in $colls {
        let requests_dir = ($coll_path | path join "requests")
        if ($requests_dir | path exists) {
            let request_file = ($requests_dir | path join $"($name).nuon")
            if ($request_file | path exists) {
                return (open $request_file)
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
    let root = ($env.API_ROOT? | default (pwd))
    let chains_dir = ($root | path join "chains")

    if not ($chains_dir | path exists) {
        mkdir $chains_dir
    }

    let file_path = ($chains_dir | path join $"($name).nuon")

    if ($file_path | path exists) {
        print $"(ansi red)Chain '($name)' already exists(ansi reset)"
        return
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
    let root = ($env.API_ROOT? | default (pwd))
    let chains_dir = ($root | path join "chains")

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
        let chain = try {
            open $file
        } catch {
            { name: ($file | path basename | str replace ".nuon" ""), description: "", steps: [] }
        }

        {
            name: ($chain.name? | default ($file | path basename | str replace ".nuon" ""))
            description: ($chain.description? | default "")
            steps: ($chain.steps? | default [] | length)
        }
    } | table
}

# Show chain details
export def "api chain show" [name: string] {
    let root = ($env.API_ROOT? | default (pwd))
    let file_path = ($root | path join "chains" $"($name).nuon")

    if not ($file_path | path exists) {
        print $"(ansi red)Chain '($name)' not found(ansi reset)"
        return null
    }

    let chain = (open $file_path)

    print $"(ansi blue)Chain: ($chain.name? | default $name)(ansi reset)"
    if ($chain.description? | default "") != "" {
        print $"Description: ($chain.description)"
    }
    print ""

    print "(ansi yellow)Steps:(ansi reset)"
    mut step_num = 0
    for step in ($chain.steps? | default []) {
        $step_num = $step_num + 1
        print $"  ($step_num). ($step.request? | default 'inline')"

        if ($step.extract? | default null) != null {
            print $"     Extract: ($step.extract | transpose | each {|e| $e.column0 } | str join ', ')"
        }

        if ($step.use? | default null) != null {
            print $"     Use: ($step.use | transpose | each {|e| $e.column0 } | str join ', ')"
        }
    }

    $chain
}

# Delete a chain
export def "api chain delete" [
    name: string  # Chain name
    --force (-f)  # Skip confirmation
] {
    let root = ($env.API_ROOT? | default (pwd))
    let file_path = ($root | path join "chains" $"($name).nuon")

    if not ($file_path | path exists) {
        print $"(ansi red)Chain '($name)' not found(ansi reset)"
        return
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
