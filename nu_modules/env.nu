# Environment Management Module
# DEPRECATED: Root-level environments are deprecated.
# Use collection-level environments instead: api collection env <command>

# Helper to show deprecation warning
def show-deprecation-warning [new_command: string] {
    print $"(ansi yellow)DEPRECATED: Root-level environments are deprecated.(ansi reset)"
    print $"Use '($new_command)' instead."
    print ""
}

# Get the environments directory path
def get-envs-dir [] {
    let root = ($env.API_ROOT? | default (pwd))
    $root | path join "environments"
}

# Ensure environments directory exists
def ensure-envs-dir [] {
    let dir = (get-envs-dir)
    if not ($dir | path exists) {
        mkdir $dir
    }
    $dir
}

# Get environment file path
def get-env-path [name: string] {
    (get-envs-dir) | path join $"($name).nuon"
}

# List all environments (DEPRECATED)
export def "api env list" [] {
    show-deprecation-warning "api collection env list <collection>"

    let dir = (get-envs-dir)

    if not ($dir | path exists) {
        print "(ansi yellow)No root-level environments found.(ansi reset)"
        return []
    }

    let envs = try { ls $dir | where name =~ '\.nuon$' | get name | each {|f| $f | path basename | str replace ".nuon" "" } } catch { [] }

    let config_path = (($env.API_ROOT? | default (pwd)) | path join "config.nuon")
    let current = if ($config_path | path exists) {
        (open $config_path).default_environment? | default ""
    } else { "" }

    if ($envs | is-empty) {
        print "(ansi yellow)No root-level environments found.(ansi reset)"
        return []
    }

    $envs | each {|name|
        let marker = if $name == $current { " (active)" } else { "" }
        {
            name: $name
            active: ($name == $current)
            marker: $marker
        }
    } | table
}

# Create a new environment (DEPRECATED)
export def "api env create" [
    name: string  # Environment name (e.g., dev, staging, prod)
    --activate (-a)  # Activate this environment after creation
] {
    show-deprecation-warning "api collection env create <collection> <name>"

    let dir = (ensure-envs-dir)
    let env_path = (get-env-path $name)

    if ($env_path | path exists) {
        print $"(ansi red)Environment '($name)' already exists(ansi reset)"
        return
    }

    {
        name: $name
        description: ""
        variables: {}
        created_at: (date now | format date "%Y-%m-%dT%H:%M:%SZ")
    } | to nuon | save $env_path

    print $"(ansi green)Environment '($name)' created(ansi reset)"

    if $activate {
        api env use $name
    }
}

# Switch to an environment (DEPRECATED)
export def "api env use" [name: string] {
    show-deprecation-warning "api collection env use <collection> <name>"

    let env_path = (get-env-path $name)

    if not ($env_path | path exists) {
        print $"(ansi red)Environment '($name)' not found(ansi reset)"
        print "Available environments:"
        api env list
        return
    }

    let root = ($env.API_ROOT? | default (pwd))
    let config_path = ($root | path join "config.nuon")

    mut config = if ($config_path | path exists) {
        open $config_path
    } else {
        { default_environment: null }
    }

    $config = ($config | upsert default_environment $name)
    $config | to nuon | save -f $config_path

    print $"(ansi green)Switched to environment: ($name)(ansi reset)"
}

# Show environment variables (DEPRECATED)
export def "api env show" [
    name?: string  # Environment name (defaults to current)
] {
    show-deprecation-warning "api collection env show <collection> [name]"

    let target = if $name != null {
        $name
    } else {
        let root = ($env.API_ROOT? | default (pwd))
        let config_path = ($root | path join "config.nuon")
        if ($config_path | path exists) {
            (open $config_path).default_environment?
        } else {
            null
        }
    }

    if $target == null {
        print "(ansi yellow)No environment selected.(ansi reset)"
        return
    }

    let env_path = (get-env-path $target)

    if not ($env_path | path exists) {
        print $"(ansi red)Environment '($target)' not found(ansi reset)"
        return
    }

    let env_data = (open $env_path)

    print $"(ansi blue)Environment: ($target)(ansi reset)"
    if ($env_data.description? | default "" | is-not-empty) {
        print $"Description: ($env_data.description)"
    }
    print ""

    if ($env_data.variables | is-empty) {
        print "(ansi yellow)No variables set(ansi reset)"
    } else {
        $env_data.variables | transpose key value | table
    }
}

# Set a variable in the current environment (DEPRECATED)
export def "api env set" [
    key: string    # Variable name
    value: string  # Variable value
    --target (-t): string  # Target environment (defaults to current)
] {
    show-deprecation-warning "api collection env set <collection> <key> <value>"

    let target_env = if $target != null {
        $target
    } else {
        let root = ($env.API_ROOT? | default (pwd))
        let config_path = ($root | path join "config.nuon")
        if ($config_path | path exists) {
            (open $config_path).default_environment?
        } else {
            null
        }
    }

    if $target_env == null {
        print "(ansi red)No environment selected.(ansi reset)"
        return
    }

    let env_path = (get-env-path $target_env)

    if not ($env_path | path exists) {
        print $"(ansi red)Environment '($target_env)' not found(ansi reset)"
        return
    }

    mut env_data = (open $env_path)
    $env_data = ($env_data | upsert variables ($env_data.variables | upsert $key $value))
    $env_data | to nuon | save -f $env_path

    print $"(ansi green)Set ($key) = ($value) in ($target_env)(ansi reset)"
}

# Unset (remove) a variable from the current environment (DEPRECATED)
export def "api env unset" [
    key: string  # Variable name to remove
    --target (-t): string  # Target environment (defaults to current)
] {
    show-deprecation-warning "api collection env unset <collection> <key>"

    let target_env = if $target != null {
        $target
    } else {
        let root = ($env.API_ROOT? | default (pwd))
        let config_path = ($root | path join "config.nuon")
        if ($config_path | path exists) {
            (open $config_path).default_environment?
        } else {
            null
        }
    }

    if $target_env == null {
        print "(ansi red)No environment selected.(ansi reset)"
        return
    }

    let env_path = (get-env-path $target_env)

    if not ($env_path | path exists) {
        print $"(ansi red)Environment '($target_env)' not found(ansi reset)"
        return
    }

    mut env_data = (open $env_path)

    if not ($key in $env_data.variables) {
        print $"(ansi yellow)Variable '($key)' not found in ($target_env)(ansi reset)"
        return
    }

    $env_data = ($env_data | upsert variables ($env_data.variables | reject $key))
    $env_data | to nuon | save -f $env_path

    print $"(ansi green)Removed ($key) from ($target_env)(ansi reset)"
}

# Delete an environment (DEPRECATED)
export def "api env delete" [
    name: string  # Environment name to delete
    --force (-f)  # Skip confirmation
] {
    show-deprecation-warning "api collection env delete <collection> <name>"

    let env_path = (get-env-path $name)

    if not ($env_path | path exists) {
        print $"(ansi red)Environment '($name)' not found(ansi reset)"
        return
    }

    if not $force {
        let confirm = (input $"Delete environment '($name)'? [y/N] ")
        if $confirm !~ "^[yY]" {
            print "Cancelled"
            return
        }
    }

    rm $env_path

    # Clear default if this was the active environment
    let root = ($env.API_ROOT? | default (pwd))
    let config_path = ($root | path join "config.nuon")
    if ($config_path | path exists) {
        mut config = (open $config_path)
        if ($config.default_environment? == $name) {
            $config = ($config | upsert default_environment null)
            $config | to nuon | save -f $config_path
        }
    }

    print $"(ansi green)Environment '($name)' deleted(ansi reset)"
}

# Copy an environment (DEPRECATED)
export def "api env copy" [
    source: string  # Source environment name
    target: string  # Target environment name
] {
    show-deprecation-warning "Use api collection env create followed by api collection env set"

    let source_path = (get-env-path $source)
    let target_path = (get-env-path $target)

    if not ($source_path | path exists) {
        print $"(ansi red)Source environment '($source)' not found(ansi reset)"
        return
    }

    if ($target_path | path exists) {
        print $"(ansi red)Target environment '($target)' already exists(ansi reset)"
        return
    }

    mut env_data = (open $source_path)
    $env_data = ($env_data | upsert name $target)
    $env_data = ($env_data | upsert created_at (date now | format date "%Y-%m-%dT%H:%M:%SZ"))
    $env_data | to nuon | save $target_path

    print $"(ansi green)Copied environment '($source)' to '($target)'(ansi reset)"
}

# Get all variables from global variables (for backward compatibility)
# This now returns global variables instead of root-level environment variables
export def "api env get-vars" [] {
    # Return global variables for backward compatibility
    let root = ($env.API_ROOT? | default (pwd))
    let vars_path = ($root | path join "variables.nuon")

    if ($vars_path | path exists) {
        open $vars_path
    } else {
        {}
    }
}
