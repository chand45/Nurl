# Variable Interpolation Module
# Handles {{variable}} replacement and built-in dynamic variables

# ============================================================================
# Global Variables Management
# ============================================================================

# Get the global variables file path
def get-global-vars-path [] {
    let root = ($env.API_ROOT? | default (pwd))
    $root | path join "variables.nuon"
}

# Load global variables from variables.nuon
def load-global-vars [] {
    let path = (get-global-vars-path)
    if ($path | path exists) {
        open $path
    } else {
        {}
    }
}

# Save global variables to variables.nuon
def save-global-vars [vars: record] {
    let path = (get-global-vars-path)
    $vars | to nuon | save -f $path
}

# Get collection meta path
def get-collection-meta-path [collection: string] {
    let root = ($env.API_ROOT? | default (pwd))
    $root | path join "collections" $collection "meta.nuon"
}

# Load collection meta
def load-collection-meta [collection: string] {
    let path = (get-collection-meta-path $collection)
    if ($path | path exists) {
        open $path
    } else {
        { active_environment: null }
    }
}

# Get collection environment path
def get-collection-env-path [collection: string, env_name: string] {
    let root = ($env.API_ROOT? | default (pwd))
    $root | path join "collections" $collection "environments" $"($env_name).nuon"
}

# Get merged variables with proper layering
# Resolution order (narrowest wins):
#   1. extra_vars (request-level --vars)
#   2. Collection's active environment
#   3. Global variables (variables.nuon)
export def "api vars get-merged" [
    --collection (-c): string = ""  # Collection for context
    --extra-vars (-v): record = {}  # Request-level overrides
] {
    # Layer 1: Start with global variables (lowest priority)
    mut merged = (load-global-vars)

    # Layer 2: Overlay collection's active environment
    if $collection != "" {
        let meta = (load-collection-meta $collection)
        let active_env = ($meta.active_environment? | default null)

        if $active_env != null {
            let env_path = (get-collection-env-path $collection $active_env)
            if ($env_path | path exists) {
                let env_data = (open $env_path)
                let env_vars = ($env_data.variables? | default {})
                $merged = ($merged | merge $env_vars)
            }
        }
    }

    # Layer 3: Overlay extra vars (highest priority)
    $merged = ($merged | merge $extra_vars)

    $merged
}

# ============================================================================
# Secrets Management
# ============================================================================

# Get secrets from secrets.nuon
def get-secrets [] {
    let root = ($env.API_ROOT? | default (pwd))
    let secrets_path = ($root | path join "secrets.nuon")

    if ($secrets_path | path exists) {
        open $secrets_path
    } else {
        {
            tokens: {}
            oauth: {}
            api_keys: {}
            basic_auth: {}
        }
    }
}

# Generate built-in variable values
def get-builtin-var [name: string] {
    match $name {
        "$uuid" => (random uuid)
        "$timestamp" => (date now | format date "%Y-%m-%dT%H:%M:%SZ")
        "$timestamp_unix" => (date now | into int | $in / 1_000_000_000 | into int)
        "$random_int" | "$randomInt" => (random int 0..999999 | into string)
        "$random_string" | "$randomString" => (random chars --length 16)
        "$random_email" | "$randomEmail" => $"user_(random chars --length 8)@example.com"
        "$date" => (date now | format date "%Y-%m-%d")
        "$time" => (date now | format date "%H:%M:%S")
        _ => null
    }
}

# Interpolate variables in a string
# Supports: {{var_name}}, {{$uuid}}, {{$timestamp}}, etc.
# Resolution order: extra-vars > collection env > global vars > built-ins
export def "api vars interpolate" [
    text: string                     # Text containing {{variables}}
    --extra-vars (-v): record = {}   # Additional variables (highest priority)
    --collection (-c): string = ""   # Collection context for variable resolution
    --env-vars (-e): record = {}     # Pre-fetched variables (for backward compat)
] {
    # Get merged variables with proper layering
    let all_vars = if not ($env_vars | is-empty) {
        # Backward compatibility: if env_vars provided, use them merged with extra_vars
        $env_vars | merge $extra_vars
    } else {
        # New layered resolution: global vars < collection env < extra vars
        api vars get-merged -c $collection -v $extra_vars
    }

    # Find all {{...}} patterns
    mut result = $text
    let pattern = '\{\{([^}]+)\}\}'

    # Keep replacing until no more matches
    loop {
        let matches = ($result | parse -r $pattern)

        if ($matches | is-empty) {
            break
        }

        for match in $matches {
            let var_name = ($match.capture0 | str trim)
            let placeholder = $"{{($var_name)}}"

            # Check if it's a built-in variable (starts with $)
            let value = if ($var_name | str starts-with "$") {
                get-builtin-var $var_name
            } else if $var_name in $all_vars {
                $all_vars | get $var_name
            } else {
                null
            }

            if $value != null {
                $result = ($result | str replace $placeholder ($value | into string))
            }
        }

        # Check if we made any replacements
        let new_matches = ($result | parse -r $pattern)
        if ($new_matches | length) >= ($matches | length) {
            # No progress made, exit to avoid infinite loop
            break
        }
    }

    $result
}

# Interpolate variables in a record (recursively)
# Resolution order: extra-vars > collection env > global vars > built-ins
export def "api vars interpolate-record" [
    data: record
    --extra-vars (-v): record = {}
    --collection (-c): string = ""   # Collection context for variable resolution
    --env-vars (-e): record = {}     # Pre-fetched variables (for backward compat)
] {
    # Return empty record if input is empty
    if ($data | is-empty) {
        return {}
    }

    # Pre-fetch merged variables once for efficiency
    let merged_vars = if not ($env_vars | is-empty) {
        $env_vars | merge $extra_vars
    } else {
        api vars get-merged -c $collection -v $extra_vars
    }

    let rows = ($data | transpose key value | each {|row|
        let new_value = match ($row.value | describe | str replace -r '<.*' '') {
            "string" => (api vars interpolate $row.value -v $extra_vars -c $collection -e $merged_vars)
            "record" => (api vars interpolate-record $row.value -v $extra_vars -c $collection -e $merged_vars)
            "list" => ($row.value | each {|item|
                if ($item | describe | str starts-with "string") {
                    api vars interpolate $item -v $extra_vars -c $collection -e $merged_vars
                } else if ($item | describe | str starts-with "record") {
                    api vars interpolate-record $item -v $extra_vars -c $collection -e $merged_vars
                } else {
                    $item
                }
            })
            _ => $row.value
        }
        { $row.key: $new_value }
    })

    # Handle empty rows after processing
    if ($rows | is-empty) {
        return {}
    }

    $rows | reduce {|it, acc| $acc | merge $it }
}

# List all available variables (global variables and built-ins)
export def "api vars list" [
    --include-secrets (-s)  # Include secret variable names
] {
    mut result = []

    # Built-in variables
    $result = ($result | append ([
        { name: "{{$uuid}}", value: null, type: "builtin", description: "Random UUID v4" }
        { name: "{{$timestamp}}", value: null, type: "builtin", description: "ISO 8601 timestamp" }
        { name: "{{$timestamp_unix}}", value: null, type: "builtin", description: "Unix timestamp (seconds)" }
        { name: "{{$random_int}}", value: null, type: "builtin", description: "Random integer 0-999999" }
        { name: "{{$random_string}}", value: null, type: "builtin", description: "Random 16-char string" }
        { name: "{{$random_email}}", value: null, type: "builtin", description: "Random email address" }
        { name: "{{$date}}", value: null, type: "builtin", description: "Current date (YYYY-MM-DD)" }
        { name: "{{$time}}", value: null, type: "builtin", description: "Current time (HH:MM:SS)" }
    ]))

    # Global variables
    let global_vars = (load-global-vars)
    if not ($global_vars | is-empty) {
        $result = ($result | append ($global_vars | transpose name value | each {|row|
            { name: $"{{($row.name)}}", value: $row.value, type: "global", description: null }
        }))
    }

    # Secret variables (names only, values masked)
    if $include_secrets {
        let secrets = (get-secrets)

        if not ($secrets.tokens | is-empty) {
            $result = ($result | append ($secrets.tokens | transpose name value | each {|row|
                { name: $"{{bearer_token_($row.name)}}", value: "***", type: "secret", description: "Bearer token" }
            }))
        }

        if not ($secrets.api_keys | is-empty) {
            $result = ($result | append ($secrets.api_keys | transpose name value | each {|row|
                { name: $"{{api_key_($row.name)}}", value: "***", type: "secret", description: "API key" }
            }))
        }
    }

    $result
}

# Set a global variable
export def "api vars set" [
    key: string    # Variable name
    value: string  # Variable value
] {
    mut vars = (load-global-vars)
    $vars = ($vars | upsert $key $value)
    save-global-vars $vars
    print $"(ansi green)Global variable set: ($key) = ($value)(ansi reset)"
}

# Remove a global variable
export def "api vars unset" [
    key: string  # Variable name to remove
] {
    mut vars = (load-global-vars)
    if not ($key in $vars) {
        print $"(ansi yellow)Variable '($key)' not found in global variables(ansi reset)"
        return
    }
    $vars = ($vars | reject $key)
    save-global-vars $vars
    print $"(ansi green)Global variable removed: ($key)(ansi reset)"
}

# Test variable interpolation
export def "api vars test" [text: string] {
    print $"(ansi blue)Input:(ansi reset) ($text)"
    let result = (api vars interpolate $text)
    print $"(ansi green)Output:(ansi reset) ($result)"
}

# Extract value from nested data using dot notation path
# e.g., "body.data.user.id" or "headers.Content-Type"
export def "api vars extract" [
    data: any           # Data to extract from
    path: string        # Dot-notation path
] {
    let parts = ($path | split row ".")
    mut current = $data

    for part in $parts {
        if $current == null {
            return null
        }

        # Handle array index notation like "items.0.name"
        if ($part | str contains "[") {
            let base = ($part | parse -r '^([^\[]+)\[(\d+)\]$')
            if not ($base | is-empty) {
                let field = $base.0.capture0
                let index = ($base.0.capture1 | into int)

                if $field != "" {
                    $current = ($current | get -o $field)
                }
                if $current != null {
                    $current = ($current | get -o $index)
                }
            } else {
                $current = ($current | get -o $part)
            }
        } else if ($part =~ '^\d+$') {
            # Plain numeric index
            $current = ($current | get -o ($part | into int))
        } else {
            $current = ($current | get -o $part)
        }
    }

    $current
}
