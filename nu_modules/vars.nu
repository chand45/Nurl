# Variable Interpolation Module
# Handles {{variable}} replacement and built-in dynamic variables

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
export def "api vars interpolate" [
    text: string                   # Text containing {{variables}}
    --extra-vars (-v): record = {} # Additional variables to use
    --env-vars (-e): record = {}   # Pre-fetched environment variables
] {
    # Get environment variables if not provided
    let env_variables = if ($env_vars | is-empty) {
        api env get-vars
    } else {
        $env_vars
    }

    # Merge all variable sources (extra-vars take precedence)
    let all_vars = ($env_variables | merge $extra_vars)

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
export def "api vars interpolate-record" [
    data: record
    --extra-vars (-v): record = {}
    --env-vars (-e): record = {}
] {
    # Return empty record if input is empty
    if ($data | is-empty) {
        return {}
    }

    let env_variables = if ($env_vars | is-empty) {
        api env get-vars
    } else {
        $env_vars
    }

    let rows = ($data | transpose key value | each {|row|
        let new_value = match ($row.value | describe | str replace -r '<.*' '') {
            "string" => (api vars interpolate $row.value -v $extra_vars -e $env_variables)
            "record" => (api vars interpolate-record $row.value -v $extra_vars -e $env_variables)
            "list" => ($row.value | each {|item|
                if ($item | describe | str starts-with "string") {
                    api vars interpolate $item -v $extra_vars -e $env_variables
                } else if ($item | describe | str starts-with "record") {
                    api vars interpolate-record $item -v $extra_vars -e $env_variables
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

# List all available variables
export def "api vars list" [
    --include-secrets (-s)  # Include secret variable names
] {
    print $"(ansi blue)Built-in Variables:(ansi reset)"
    [
        { name: "{{$uuid}}", description: "Random UUID v4" }
        { name: "{{$timestamp}}", description: "ISO 8601 timestamp" }
        { name: "{{$timestamp_unix}}", description: "Unix timestamp (seconds)" }
        { name: "{{$random_int}}", description: "Random integer 0-999999" }
        { name: "{{$random_string}}", description: "Random 16-char string" }
        { name: "{{$random_email}}", description: "Random email address" }
        { name: "{{$date}}", description: "Current date (YYYY-MM-DD)" }
        { name: "{{$time}}", description: "Current time (HH:MM:SS)" }
    ] | table

    print ""
    print $"(ansi blue)Environment Variables:(ansi reset)"
    let env_vars = (api env get-vars)
    if ($env_vars | is-empty) {
        print "(ansi yellow)No environment variables set(ansi reset)"
    } else {
        $env_vars | transpose name value | each {|row|
            { name: $"{{($row.name)}}", value: $row.value }
        } | table
    }

    if $include_secrets {
        print ""
        print $"(ansi blue)Secret Variables:(ansi reset)"
        let secrets = (get-secrets)

        if not ($secrets.tokens | is-empty) {
            print "  Tokens:"
            $secrets.tokens | transpose name value | each {|row|
                print $"    - {{bearer_token_($row.name)}}"
            }
        }

        if not ($secrets.api_keys | is-empty) {
            print "  API Keys:"
            $secrets.api_keys | transpose name value | each {|row|
                print $"    - {{api_key_($row.name)}}"
            }
        }
    }
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
