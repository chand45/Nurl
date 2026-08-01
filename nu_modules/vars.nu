# Variable Interpolation Module
# Handles {{variable}} replacement and built-in dynamic variables

use resource-path.nu [open-state-record open-state-record-or-default resolve-under-base save-state-replace validate-resource-name]
use command-error.nu [fail-command]
use string-compat.nu [optional-get]

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
    open-state-record-or-default $path {} "variables.nuon"
}

# Save global variables to variables.nuon
def save-global-vars [vars: record] {
    let path = (get-global-vars-path)
    save-state-replace ($vars | to nuon) $path
}

# Get collection meta path
def get-collections-dir [] {
    let root = ($env.API_ROOT? | default (pwd))
    resolve-under-base $root "collections" "collections directory" --scope "API workspace"
}

def resolve-collection-dir [collections_dir: string, collection: string] {
    resolve-under-base $collections_dir $collection "collection" --scope "API workspace collections" --base-is-canonical
}

def get-collection-meta-path [collection_dir: string, collection: string] {
    resolve-under-base $collection_dir "meta.nuon" "collection metadata" --scope $"collection '($collection)'" --base-is-canonical
}

# Load collection meta
def load-collection-meta [collection_dir: string, collection: string] {
    let path = (get-collection-meta-path $collection_dir $collection)
    open-state-record-or-default $path {active_environment: null} $"collection '($collection)' metadata"
}

# Get collection environment path
def get-collection-env-path [collection_dir: string, collection: string, env_name: string] {
    let envs_dir = (resolve-under-base $collection_dir "environments" "environment directory" --scope $"collection '($collection)'" --base-is-canonical)
    resolve-under-base $envs_dir $env_name "environment" --suffix ".nuon" --always-suffix --scope $"collection '($collection)'/environments" --base-is-canonical
}

# List all collections in the workspace
def list-collections [] {
    let collections_path = (get-collections-dir)
    if ($collections_path | path exists) {
        ls $collections_path | where type == dir | get name | each {|discovered_path|
            let name = ($discovered_path | path basename)
            {
                name: $name
                path: (resolve-collection-dir $collections_path $name)
            }
        }
    } else {
        []
    }
}

# Truncate a string to max length with ellipsis
def truncate-value [value: any, max_len: int = 10] {
    let str_val = if $value == null { "" } else { $value | into string }
    if ($str_val | str length) > $max_len {
        $"($str_val | str substring 0..$max_len)..."
    } else {
        $str_val
    }
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
    if $collection != "" {
        validate-resource-name "collection" $collection | ignore
    }

    # Layer 1: Start with global variables (lowest priority)
    mut merged = (load-global-vars)

    # Layer 2: Overlay collection's active environment
    if $collection != "" {
        let collections_dir = (get-collections-dir)
        let collection_dir = (resolve-collection-dir $collections_dir $collection)
        let meta = (load-collection-meta $collection_dir $collection)
        let active_env = ($meta.active_environment? | default null)

        if $active_env != null {
            let env_path = (get-collection-env-path $collection_dir $collection $active_env)
            if ($env_path | path exists) {
                let env_data = (open-state-record $env_path $"environment '($active_env)' in collection '($collection)'")
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
        open-state-record $secrets_path "secrets.nuon"
    } else {
        {
            tokens: {}
            saml_tokens: {}
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

def interpolate-resolved-text [text: string, all_vars: record] {
    if not ($text | str contains "{{") {
        return $text
    }
    let pattern = '\{\{([^}]+)\}\}'
    let matches = ($text | parse -r $pattern)
    if ($matches | is-empty) {
        return $text
    }
    let segments = ($text | split row -r '\{\{[^}]+\}\}')
    let chunks = ($matches | enumerate | each {|entry|
        let raw_var_name = $entry.item.capture0
        let var_name = ($raw_var_name | str trim)
        let placeholder = $"{{($raw_var_name)}}"
        let value = if ($var_name | str starts-with "$") {
            get-builtin-var $var_name
        } else if $var_name in $all_vars {
            $all_vars | get $var_name
        } else {
            null
        }
        let following = try { $segments | get ($entry.index + 1) } catch { "" }
        [
            (if $value == null { $placeholder } else { $value | into string })
            $following
        ]
    } | flatten)
    [($segments | first) ...$chunks] | str join
}

def interpolate-resolved-recursive-text [text: string, all_vars: record] {
    mut result = $text
    mut seen = []
    mut depth = 0
    loop {
        if $depth >= 32 {
            fail-command "Variable interpolation exceeded 32 expansion steps; check for cyclic variable references."
        }
        let next = (interpolate-resolved-text $result $all_vars)
        if $next == $result {
            return $result
        }
        if $next in $seen {
            return $result
        }
        $seen = ($seen | append $result)
        $result = $next
        $depth = $depth + 1
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
    --resolved                       # Treat --env-vars as an already-resolved context, even when empty
    --single-pass                    # Do not interpolate placeholders introduced by replacement values
] {
    if $collection != "" {
        validate-resource-name "collection" $collection | ignore
    }
    if not ($text | str contains "{{") {
        return $text
    }

    let all_vars = if $resolved {
        $env_vars | merge $extra_vars
    } else if not ($env_vars | is-empty) {
        $env_vars | merge $extra_vars
    } else {
        api vars get-merged -c $collection -v $extra_vars
    }
    if $single_pass {
        interpolate-resolved-text $text $all_vars
    } else {
        interpolate-resolved-recursive-text $text $all_vars
    }
}

def json-string-content [value: any] {
    $value | into string | to json | split chars | skip 1 | drop 1 | str join
}

def interpolate-json-template [text: string, all_vars: record] {
    if not ($text | str contains "{{") {
        return $text
    }
    let matches = ($text | parse -r '\{\{([^}]+)\}\}')
    let segments = ($text | split row -r '\{\{[^}]+\}\}')
    let chunks = ($matches | enumerate | each {|entry|
        let raw_var_name = $entry.item.capture0
        let var_name = ($raw_var_name | str trim)
        let placeholder = $"{{($raw_var_name)}}"
        let value = if ($var_name | str starts-with "$") {
            get-builtin-var $var_name
        } else if $var_name in $all_vars {
            $all_vars | get $var_name
        } else {
            null
        }
        let following = try { $segments | get ($entry.index + 1) } catch { "" }
        [
            (if $value == null { $placeholder } else { json-string-content $value })
            $following
        ]
    } | flatten)
    [($segments | first) ...$chunks] | str join
}

def interpolate-json-recursive-template [text: string, all_vars: record] {
    mut result = $text
    mut seen = []
    mut depth = 0
    loop {
        if $depth >= 32 {
            fail-command "Structured interpolation exceeded 32 expansion steps; check for cyclic variable references."
        }
        let next = (interpolate-json-template $result $all_vars)
        if $next == $result {
            return $result
        }
        if $next in $seen {
            return $result
        }
        $seen = ($seen | append $result)
        $result = $next
        $depth = $depth + 1
    }
}

def structured-base-type [data: any] {
    $data | describe | str replace -r '<.*' ''
}

def validate-interpolated-key-collisions [data: any, merged_vars: record, recursive: bool] {
    let base_type = (structured-base-type $data)
    if $base_type in ["list" "table"] {
        for item in $data {
            validate-interpolated-key-collisions $item $merged_vars $recursive
        }
        return
    }
    if $base_type != "record" {
        return
    }

    mut observed = []
    for row in ($data | transpose key value) {
        let new_key = if $recursive {
            interpolate-resolved-recursive-text $row.key $merged_vars
        } else {
            interpolate-resolved-text $row.key $merged_vars
        }
        if $new_key in $observed {
            fail-command $"Structured interpolation produced duplicate key '($new_key)'"
        }
        $observed = ($observed | append $new_key)
        validate-interpolated-key-collisions $row.value $merged_vars $recursive
    }
}

def interpolate-structured-value [
    data: any
    merged_vars: record
    single_pass: bool
] {
    let base_type = (structured-base-type $data)
    if $base_type == "string" {
        return (if $single_pass {
            interpolate-resolved-text $data $merged_vars
        } else {
            interpolate-resolved-recursive-text $data $merged_vars
        })
    }
    if $base_type in ["list" "table"] {
        return ($data | reduce -f [] {|item, acc|
            $acc | append [(interpolate-structured-value $item $merged_vars $single_pass)]
        })
    }
    if $base_type != "record" {
        return $data
    }

    $data
    | transpose key value
    | reduce -f {} {|row, acc|
        let new_key = (if $single_pass {
            interpolate-resolved-text $row.key $merged_vars
        } else {
            interpolate-resolved-recursive-text $row.key $merged_vars
        })
        if $new_key in ($acc | columns) {
            fail-command $"Structured interpolation produced duplicate key '($new_key)'"
        }
        let new_value = (interpolate-structured-value $row.value $merged_vars $single_pass)
        $acc | merge { $new_key: $new_value }
    }
}

def interpolate-values-only-value [
    data: any
    merged_vars: record
    single_pass: bool
] {
    let base_type = (structured-base-type $data)
    if $base_type == "string" {
        return (if $single_pass {
            interpolate-resolved-text $data $merged_vars
        } else {
            interpolate-resolved-recursive-text $data $merged_vars
        })
    }
    if $base_type in ["list" "table"] {
        return ($data | reduce -f [] {|item, acc|
            $acc | append [(interpolate-values-only-value $item $merged_vars $single_pass)]
        })
    }
    if $base_type != "record" {
        return $data
    }

    $data
    | transpose key value
    | reduce -f {} {|row, acc|
        let new_value = (interpolate-values-only-value $row.value $merged_vars $single_pass)
        $acc | merge { $row.key: $new_value }
    }
}

# Recursively interpolate record keys/values and list/table elements.
export def interpolate-structured [
    data: any
    --extra-vars (-v): record = {}
    --collection (-c): string = ""
    --env-vars (-e): record = {}
    --resolved                       # Treat --env-vars as an already-resolved context, even when empty
    --single-pass                    # Do not interpolate placeholders introduced by replacement values
] {
    if $collection != "" {
        validate-resource-name "collection" $collection | ignore
    }
    let merged_vars = if $resolved {
        $env_vars | merge $extra_vars
    } else if not ($env_vars | is-empty) {
        $env_vars | merge $extra_vars
    } else {
        api vars get-merged -c $collection -v $extra_vars
    }
    interpolate-structured-value $data $merged_vars $single_pass
}

export def interpolate-record-values [
    data: record
    --extra-vars (-v): record = {}
    --collection (-c): string = ""
    --env-vars (-e): record = {}
    --resolved
    --single-pass
] {
    if $collection != "" {
        validate-resource-name "collection" $collection | ignore
    }
    let merged_vars = if $resolved {
        $env_vars | merge $extra_vars
    } else if not ($env_vars | is-empty) {
        $env_vars | merge $extra_vars
    } else {
        api vars get-merged -c $collection -v $extra_vars
    }
    interpolate-values-only-value $data $merged_vars $single_pass
}

def resolve-trusted-var [
    name: string
    vars: record
    state: record
] {
    if $name in ($state.resolved | columns) {
        return {state: $state, value: ($state.resolved | get $name)}
    }
    if $name in $state.resolving {
        fail-command $"Variable interpolation cycle detected at '($name)'."
    }

    let raw = ($vars | get $name)
    mut next_state = ($state | update resolving ($state.resolving | append $name))
    if ((structured-base-type $raw) == "string") and ($raw | str contains "{{") {
        for match in ($raw | parse -r '\{\{([^}]+)\}\}') {
            let dependency = ($match.capture0 | str trim)
            if (not ($dependency | str starts-with "$")) and ($dependency in ($vars | columns)) {
                let resolved_dependency = (resolve-trusted-var $dependency $vars $next_state)
                $next_state = $resolved_dependency.state
            }
        }
    }

    let value = if (structured-base-type $raw) == "string" {
        interpolate-resolved-recursive-text $raw $next_state.resolved
    } else {
        $raw
    }
    let final_state = (
        $next_state
        | update resolved ($next_state.resolved | merge { $name: $value })
        | update resolving ($next_state.resolving | where {|candidate| $candidate != $name })
    )
    {state: $final_state, value: $value}
}

export def resolve-trusted-vars [vars: record] {
    mut state = {resolved: {}, resolving: []}
    for name in ($vars | columns) {
        $state = (resolve-trusted-var $name $vars $state).state
    }
    $state.resolved
}

def restore-opaque-text [text: string, replacements: list] {
    $replacements | reduce -f $text {|replacement, result|
        if not ($result | str contains $replacement.token) {
            $result
        } else {
            let value = try {
                $replacement.value | into string
            } catch {
                fail-command $"Extracted chain value '($replacement.name? | default 'unknown')' cannot be interpolated into text."
            }
            $result | str replace --all $replacement.token $value
        }
    }
}

def restore-opaque-value [data: any, replacements: list, restore_keys: bool] {
    let base_type = (structured-base-type $data)
    if $base_type == "string" {
        return (restore-opaque-text $data $replacements)
    }
    if $base_type in ["list" "table"] {
        return ($data | reduce -f [] {|item, acc|
            $acc | append [(restore-opaque-value $item $replacements $restore_keys)]
        })
    }
    if $base_type != "record" {
        return $data
    }

    $data
    | transpose key value
    | reduce -f {} {|row, acc|
        let key = if $restore_keys {
            restore-opaque-text $row.key $replacements
        } else {
            $row.key
        }
        if $key in ($acc | columns) {
            fail-command $"Structured interpolation produced duplicate key '($key)'"
        }
        let value = (restore-opaque-value $row.value $replacements $restore_keys)
        $acc | merge { $key: $value }
    }
}

export def restore-opaque-values [
    data: any
    replacements: list
    --keys
] {
    if ($replacements | is-empty) {
        $data
    } else {
        restore-opaque-value $data $replacements $keys
    }
}

export def interpolate-structured-json [
    data: any
    --extra-vars (-v): record = {}
    --collection (-c): string = ""
    --env-vars (-e): record = {}
    --resolved
    --recursive
] {
    if $collection != "" {
        validate-resource-name "collection" $collection | ignore
    }
    let merged_vars = if $resolved {
        $env_vars | merge $extra_vars
    } else if not ($env_vars | is-empty) {
        $env_vars | merge $extra_vars
    } else {
        api vars get-merged -c $collection -v $extra_vars
    }
    let template = if (structured-base-type $data) == "string" {
        $data | to json
    } else {
        $data | to json --raw
    }
    if not ($template | str contains "{{") {
        return $data
    }
    let dynamic_key_pattern = '"([^"\\]|\\.)*\{\{[^}]+\}\}([^"\\]|\\.)*"\s*:'
    if not (($template | parse -r $dynamic_key_pattern) | is-empty) {
        validate-interpolated-key-collisions $data $merged_vars $recursive
    }
    let interpolated = if $recursive {
        interpolate-json-recursive-template $template $merged_vars
    } else {
        interpolate-json-template $template $merged_vars
    }
    $interpolated | from json
}

# Backward-compatible record entry point.
export def "api vars interpolate-record" [
    data: record
    --extra-vars (-v): record = {}
    --collection (-c): string = ""   # Collection context for variable resolution
    --env-vars (-e): record = {}     # Pre-fetched variables (for backward compat)
    --resolved                       # Treat --env-vars as an already-resolved context, even when empty
    --single-pass                    # Do not interpolate placeholders introduced by replacement values
] {
    interpolate-structured $data -v $extra_vars -c $collection -e $env_vars --resolved=$resolved --single-pass=$single_pass
}

# List all available variables (global variables and built-ins)
export def "api vars list" [
    --include-secrets (-s)  # Include secret variable names
    --full (-f)             # Show full values without truncation
] {
    mut result = []

    # Built-in variables
    $result = ($result | append ([
        { name: "{{$uuid}}", value: "", type: "builtin", description: "Random UUID v4" }
        { name: "{{$timestamp}}", value: "", type: "builtin", description: "ISO 8601 timestamp" }
        { name: "{{$timestamp_unix}}", value: "", type: "builtin", description: "Unix timestamp (seconds)" }
        { name: "{{$random_int}}", value: "", type: "builtin", description: "Random integer 0-999999" }
        { name: "{{$random_string}}", value: "", type: "builtin", description: "Random 16-char string" }
        { name: "{{$random_email}}", value: "", type: "builtin", description: "Random email address" }
        { name: "{{$date}}", value: "", type: "builtin", description: "Current date (YYYY-MM-DD)" }
        { name: "{{$time}}", value: "", type: "builtin", description: "Current time (HH:MM:SS)" }
    ]))

    # Global variables
    let global_vars = (load-global-vars)
    if not ($global_vars | is-empty) {
        $result = ($result | append ($global_vars | transpose name value | each {|row|
            { name: $"{{($row.name)}}", value: ($row.value | into string), type: "global", description: "" }
        }))
    }

    # Collection environment variables (from active environment of each collection)
    let collections = (list-collections)
    for collection_entry in $collections {
        let collection = $collection_entry.name
        let collection_dir = $collection_entry.path
        let meta = (load-collection-meta $collection_dir $collection)
        let active_env = ($meta.active_environment? | default null)

        if $active_env != null {
            let env_path = (get-collection-env-path $collection_dir $collection $active_env)
            if ($env_path | path exists) {
                let env_data = (open-state-record $env_path $"environment '($active_env)' in collection '($collection)'")
                let env_vars = ($env_data.variables? | default {})
                if not ($env_vars | is-empty) {
                    let type_label = $"($collection):($active_env)"
                    $result = ($result | append ($env_vars | transpose name value | each {|row|
                        { name: $"{{($row.name)}}", value: ($row.value | into string), type: $type_label, description: "" }
                    }))
                }
            }
        }
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

        let saml_tokens = ($secrets.saml_tokens? | default {})
        if not ($saml_tokens | is-empty) {
            $result = ($result | append ($saml_tokens | transpose name value | each {|row|
                { name: $"{{saml_token_($row.name)}}", value: "***", type: "secret", description: "SAML token" }
            }))
        }
    }

    # Apply truncation for display unless --full flag is set
    if $full {
        $result
    } else {
        $result | each {|row|
            {
                name: $row.name
                value: (truncate-value $row.value 40)
                type: (truncate-value $row.type 20)
                description: (truncate-value $row.description 25)
            }
        }
    }
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

        # Guard: only structured types support `get`; a scalar means the path is invalid
        let current_type = ($current | describe)
        if not (($current_type | str starts-with "record") or ($current_type | str starts-with "list") or ($current_type | str starts-with "table")) {
            return null
        }

        # Handle array index notation like "items.0.name"
        if ($part | str contains "[") {
            let base = ($part | parse -r '^([^\[]+)\[(\d+)\]$')
            if not ($base | is-empty) {
                let field = $base.0.capture0
                let index = ($base.0.capture1 | into int)

                if $field != "" {
                    $current = ($current | optional-get $field)
                }
                if $current != null {
                    $current = ($current | optional-get $index)
                }
            } else {
                $current = ($current | optional-get $part)
            }
        } else if ($part =~ '^\d+$') {
            # Plain numeric index
            $current = ($current | optional-get ($part | into int))
        } else {
            $current = ($current | optional-get $part)
        }
    }

    $current
}
