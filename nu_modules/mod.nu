# API Client Module - Main Entry Point
# A Postman-like API testing tool built on curl and nushell

# Get the directory where this module is located
def get-api-root [] {
    $env.API_ROOT? | default (pwd)
}

# Export submodules
export use env.nu *
export use vars.nu *
export use http.nu *
export use auth.nu *
export use history.nu *
export use chain.nu *
export use tui.nu *

# Initialize the API client workspace
export def "api init" [] {
    let root = (get-api-root)

    # Create directories if they don't exist
    let dirs = [
        ($root | path join "collections")
        ($root | path join "history")
        ($root | path join "nu_modules")
    ]

    for dir in $dirs {
        if not ($dir | path exists) {
            mkdir $dir
        }
    }

    # Create config if it doesn't exist
    let config_path = ($root | path join "config.nuon")
    if not ($config_path | path exists) {
        {
            default_headers: {
                "Content-Type": "application/json"
                "Accept": "application/json"
            }
            timeout_seconds: 30
            history_retention_days: 30
            editor: "code"
            colors: {
                success: "green"
                error: "red"
                warning: "yellow"
                info: "blue"
            }
        } | to nuon | save $config_path
    }

    # Create global variables if it doesn't exist
    let vars_path = ($root | path join "variables.nuon")
    if not ($vars_path | path exists) {
        {} | to nuon | save $vars_path
    }

    # Create secrets if it doesn't exist
    let secrets_path = ($root | path join "secrets.nuon")
    if not ($secrets_path | path exists) {
        {
            tokens: {}
            oauth: {}
            api_keys: {}
            basic_auth: {}
        } | to nuon | save $secrets_path
    }

    print $"(ansi green)API workspace initialized at: ($root)(ansi reset)"
    print "  - config.nuon: Global configuration"
    print "  - variables.nuon: Global variables"
    print "  - secrets.nuon: Credentials storage (gitignored)"
    print "  - collections/: Request collections (with per-collection environments)"
    print "  - history/: Request/response history"
}

# Show current API client status
export def "api status" [] {
    let root = (get-api-root)

    print $"(ansi blue)API Client Status(ansi reset)"
    print $"Root: ($root)"

    # Count global variables
    let vars_path = ($root | path join "variables.nuon")
    let global_vars_count = if ($vars_path | path exists) {
        (open $vars_path) | columns | length
    } else { 0 }
    print $"Global Variables: ($global_vars_count)"

    # Count collections
    let collections_path = ($root | path join "collections")
    let collection_count = if ($collections_path | path exists) {
        ls $collections_path | where type == dir | length
    } else { 0 }
    print $"Collections: ($collection_count)"

    # Count history entries
    let history_path = ($root | path join "history")
    let history_count = if ($history_path | path exists) {
        let subdirs = try { ls $history_path | where type == dir | get name } catch { [] }
        $subdirs | each {|d| try { ls $d | where name =~ '\.nuon$' | length } catch { 0 } } | math sum
    } else { 0 }
    print $"History entries: ($history_count)"
}

# Get configuration
export def "api config get" [] {
    let root = (get-api-root)
    let config_path = ($root | path join "config.nuon")

    if ($config_path | path exists) {
        open $config_path
    } else {
        {
            default_headers: {
                "Content-Type": "application/json"
                "Accept": "application/json"
            }
            timeout_seconds: 30
            history_retention_days: 30
            editor: "code"
        }
    }
}

# Set configuration value
export def "api config set" [key: string, value: any] {
    let root = (get-api-root)
    let config_path = ($root | path join "config.nuon")

    mut config = (api config get)
    $config = ($config | upsert $key $value)
    $config | to nuon | save -f $config_path

    print $"(ansi green)Config updated: ($key) = ($value)(ansi reset)"
}

# Show help
export def "api help" [] {
    print $"
(ansi blue_bold)API Client - curl + nushell Postman replacement(ansi reset)

(ansi yellow)Setup:(ansi reset)
  api init                      Initialize workspace
  api status                    Show current status
  api config get                Show configuration
  api config set <key> <value>  Set configuration

(ansi yellow)Global Variables:(ansi reset)
  api vars list                 List global variables and built-ins
  api vars set <key> <value>    Set a global variable
  api vars unset <key>          Remove a global variable

(ansi yellow)Collection Environments:(ansi reset)
  api collection env list <c>        List environments for collection
  api collection env create <c> <n>  Create environment in collection
  api collection env use <c> <n>     Switch active environment
  api collection env show <c> [n]    Show environment variables
  api collection env set <c> <k> <v> Set variable in active/specified env
  api collection env unset <c> <k>   Remove variable from active/specified env
  api collection env delete <c> <n>  Delete environment from collection

(ansi yellow)Authentication:(ansi reset)
  api auth bearer set <n> <t>   Set bearer token
  api auth basic set <n> <u> <p> Set basic auth
  api auth apikey set <n> <k>   Set API key
  api auth oauth2 configure ... Configure OAuth2
  api auth show                 Show auth status

(ansi yellow)Requests:(ansi reset)
  api get <url>                 GET request [global vars]
  api post <url> -b <body>      POST request
  api put <url> -b <body>       PUT request
  api patch <url> -b <body>     PATCH request
  api delete <url>              DELETE request
  api send <name> -c <coll>     Send saved request [collection env]
  api request create <name>     Create new request

(ansi yellow)History:(ansi reset)
  api history list              List recent requests
  api history show <id>         Show request details
  api history resend <id>       Resend a request
  api history search <query>    Search history

(ansi yellow)Collections:(ansi reset)
  api collection list           List collections
  api collection create <name>  Create collection
  api collection show <name>    Show collection details
  api collection export <name>  Export collection
  api collection import <file>  Import collection

(ansi yellow)Chaining:(ansi reset)
  api chain run <file>          Run request chain
  api chain exec <file>         Execute chain from file

(ansi yellow)TUI:(ansi reset)
  api tui                       Launch terminal UI

(ansi dark_gray)Variable Resolution Order [narrowest wins]:(ansi reset)
  1. Request --vars flag
  2. Collection active environment
  3. Global variables
  4. Built-in vars
"
}

# --- Collection Management ---

# List all collections
export def "api collection list" [] {
    let root = (get-api-root)
    let collections_dir = ($root | path join "collections")

    if not ($collections_dir | path exists) {
        print $"(ansi yellow)No collections found(ansi reset)"
        return []
    }

    let collections = ls $collections_dir | where type == dir | each {|d|
        let coll_file = ($d.name | path join "collection.nuon")
        let meta = if ($coll_file | path exists) {
            open $coll_file
        } else {
            { name: ($d.name | path basename), description: "" }
        }

        let requests_dir = ($d.name | path join "requests")
        let request_count = if ($requests_dir | path exists) {
            try { ls $requests_dir | where name =~ '\.nuon$' | length } catch { 0 }
        } else { 0 }

        {
            name: ($meta.name? | default ($d.name | path basename))
            description: ($meta.description? | default "")
            requests: $request_count
        }
    }

    if ($collections | is-empty) {
        print $"(ansi yellow)No collections found(ansi reset)"
    } else {
        $collections | table
    }
}

# Create a new collection
export def "api collection create" [
    name: string                     # Collection name
    --description (-d): string = ""  # Collection description
] {
    let root = (get-api-root)
    let collection_dir = ($root | path join "collections" $name)

    if ($collection_dir | path exists) {
        print $"(ansi red)Collection '($name)' already exists(ansi reset)"
        return
    }

    mkdir $collection_dir
    mkdir ($collection_dir | path join "requests")
    mkdir ($collection_dir | path join "environments")

    {
        name: $name
        description: $description
        created_at: (date now | format date "%Y-%m-%dT%H:%M:%SZ")
        version: "1.0"
    } | to nuon | save ($collection_dir | path join "collection.nuon")

    print $"(ansi green)Collection '($name)' created(ansi reset)"
}

# Delete a collection
export def "api collection delete" [
    name: string  # Collection name
    --force (-f)  # Skip confirmation
] {
    let root = (get-api-root)
    let collection_dir = ($root | path join "collections" $name)

    if not ($collection_dir | path exists) {
        print $"(ansi red)Collection '($name)' not found(ansi reset)"
        return
    }

    if not $force {
        let confirm = (input $"Delete collection '($name)' and all its requests? [y/N] ")
        if $confirm !~ "^[yY]" {
            print "Cancelled"
            return
        }
    }

    rm -rf $collection_dir
    print $"(ansi green)Collection '($name)' deleted(ansi reset)"
}

# Export collection to a zip file
export def "api collection export" [
    name: string                  # Collection name
    --output (-o): string = ""    # Output file path
] {
    let root = (get-api-root)
    let collection_dir = ($root | path join "collections" $name)

    if not ($collection_dir | path exists) {
        print $"(ansi red)Collection '($name)' not found(ansi reset)"
        return
    }

    let output_file = if $output != "" {
        $output
    } else {
        $"($name)-collection.zip"
    }

    # Create a temporary export directory
    let export_dir = ($root | path join ".export-temp" $name)
    mkdir $export_dir

    # Copy collection files (excluding any local-only files)
    cp -r $collection_dir $export_dir

    # Create zip using tar (cross-platform)
    cd ($root | path join ".export-temp")
    tar -czf $"../($output_file)" $name
    cd $root

    # Cleanup
    rm -rf ($root | path join ".export-temp")

    print $"(ansi green)Collection exported to: ($output_file)(ansi reset)"
}

# Import collection from a file
export def "api collection import" [
    file: string  # Path to collection archive
] {
    let root = (get-api-root)

    if not ($file | path exists) {
        print $"(ansi red)File not found: ($file)(ansi reset)"
        return
    }

    # Extract to temporary directory
    let temp_dir = ($root | path join ".import-temp")
    mkdir $temp_dir

    tar -xzf $file -C $temp_dir

    # Find collection directory
    let imported = ls $temp_dir | where type == dir | first

    if $imported == null {
        rm -rf $temp_dir
        print $"(ansi red)Invalid collection archive(ansi reset)"
        return
    }

    let collection_name = ($imported.name | path basename)
    let target_dir = ($root | path join "collections" $collection_name)

    if ($target_dir | path exists) {
        let confirm = (input $"Collection '($collection_name)' already exists. Overwrite? [y/N] ")
        if $confirm !~ "^[yY]" {
            rm -rf $temp_dir
            print "Cancelled"
            return
        }
        rm -rf $target_dir
    }

    mv $imported.name $target_dir

    rm -rf $temp_dir

    print $"(ansi green)Collection '($collection_name)' imported(ansi reset)"
}

# Show collection details
export def "api collection show" [name: string] {
    let root = (get-api-root)
    let collection_dir = ($root | path join "collections" $name)

    if not ($collection_dir | path exists) {
        print $"(ansi red)Collection '($name)' not found(ansi reset)"
        return null
    }

    let coll_file = ($collection_dir | path join "collection.nuon")
    let meta = if ($coll_file | path exists) {
        open $coll_file
    } else {
        { name: $name, description: "" }
    }

    print $"(ansi blue)Collection: ($meta.name)(ansi reset)"
    if ($meta.description? | default "") != "" {
        print $"Description: ($meta.description)"
    }

    # List collection environments
    let envs_dir = ($collection_dir | path join "environments")
    if ($envs_dir | path exists) {
        let env_files = try { ls $envs_dir | where name =~ '\.nuon$' | get name } catch { [] }
        let envs = $env_files | each {|f|
            let data = (open $f)
            {
                name: ($data.name? | default ($f | path basename | str replace ".nuon" ""))
                description: ($data.description? | default "" | str substring 0..40)
                variables: ($data.variables? | default {} | columns | length)
            }
        }

        if not ($envs | is-empty) {
            print $"(ansi yellow)Environments:(ansi reset)"
            print ($envs | table)
        }
    }
    print ""

    # List requests
    print $"(ansi yellow)Requests:(ansi reset)"
    let requests_dir = ($collection_dir | path join "requests")
    let requests = if ($requests_dir | path exists) {
        let request_files = try { ls $requests_dir | where name =~ '\.nuon$' | get name } catch { [] }
        $request_files | each {|f|
            let req = (open $f)
            {
                name: ($req.name? | default ($f | path basename | str replace ".nuon" ""))
                method: ($req.method? | default "GET")
                url: ($req.url? | default "" | str substring 0..50)
            }
        }
    } else {
        []
    }

    $requests
}

# Copy a collection
export def "api collection copy" [
    source: string  # Source collection name
    target: string  # Target collection name
] {
    let root = (get-api-root)
    let source_dir = ($root | path join "collections" $source)
    let target_dir = ($root | path join "collections" $target)

    if not ($source_dir | path exists) {
        print $"(ansi red)Source collection '($source)' not found(ansi reset)"
        return
    }

    if ($target_dir | path exists) {
        print $"(ansi red)Target collection '($target)' already exists(ansi reset)"
        return
    }

    cp -r $source_dir $target_dir

    # Update collection metadata
    let coll_file = ($target_dir | path join "collection.nuon")
    if ($coll_file | path exists) {
        mut meta = (open $coll_file)
        $meta = ($meta | upsert name $target)
        $meta = ($meta | upsert created_at (date now | format date "%Y-%m-%dT%H:%M:%SZ"))
        $meta | to nuon | save -f $coll_file
    }

    print $"(ansi green)Collection '($source)' copied to '($target)'(ansi reset)"
}

# --- Collection Environment Management ---

# Helper: Get collection meta path
def get-coll-meta-path [collection: string] {
    let root = (get-api-root)
    $root | path join "collections" $collection "meta.nuon"
}

# Helper: Load collection meta
def load-coll-meta [collection: string] {
    let path = (get-coll-meta-path $collection)
    if ($path | path exists) {
        open $path
    } else {
        { active_environment: null }
    }
}

# Helper: Save collection meta
def save-coll-meta [collection: string, meta: record] {
    let path = (get-coll-meta-path $collection)
    $meta | to nuon | save -f $path
}

# Helper: Get collection environment file path
def get-coll-env-path [collection: string, env_name: string] {
    let root = (get-api-root)
    $root | path join "collections" $collection "environments" $"($env_name).nuon"
}

# Helper: Check if collection exists
def check-collection-exists [collection: string] {
    let root = (get-api-root)
    let collection_dir = ($root | path join "collections" $collection)
    if not ($collection_dir | path exists) {
        print $"(ansi red)Collection '($collection)' not found(ansi reset)"
        return false
    }
    true
}

# List environments for a collection
export def "api collection env list" [
    collection: string  # Collection name
] {
    if not (check-collection-exists $collection) { return [] }

    let root = (get-api-root)
    let envs_dir = ($root | path join "collections" $collection "environments")

    if not ($envs_dir | path exists) {
        print $"(ansi yellow)No environments found for collection '($collection)'(ansi reset)"
        print $"Use 'api collection env create ($collection) <name>' to create one."
        return []
    }

    let meta = (load-coll-meta $collection)
    let active = ($meta.active_environment? | default "")

    let env_files = try { ls $envs_dir | where name =~ '\.nuon$' | get name } catch { [] }

    if ($env_files | is-empty) {
        print $"(ansi yellow)No environments found for collection '($collection)'(ansi reset)"
        print $"Use 'api collection env create ($collection) <name>' to create one."
        return []
    }

    $env_files | each {|f|
        let data = (open $f)
        let name = ($data.name? | default ($f | path basename | str replace ".nuon" ""))
        {
            name: $name
            active: (if $name == $active { "✓" } else { "" })
            variables: ($data.variables? | default {} | columns | length)
            description: ($data.description? | default "" | str substring 0..40)
        }
    } | table
}

# Create a new environment for a collection
export def "api collection env create" [
    collection: string  # Collection name
    name: string        # Environment name
    --activate (-a)     # Activate after creation
] {
    if not (check-collection-exists $collection) { return }

    let root = (get-api-root)
    let envs_dir = ($root | path join "collections" $collection "environments")

    if not ($envs_dir | path exists) {
        mkdir $envs_dir
    }

    let env_path = ($envs_dir | path join $"($name).nuon")

    if ($env_path | path exists) {
        print $"(ansi red)Environment '($name)' already exists in collection '($collection)'(ansi reset)"
        return
    }

    {
        name: $name
        description: ""
        variables: {}
        created_at: (date now | format date "%Y-%m-%dT%H:%M:%SZ")
    } | to nuon | save $env_path

    print $"(ansi green)Environment '($name)' created in collection '($collection)'(ansi reset)"

    if $activate {
        api collection env use $collection $name
    }
}

# Switch active environment for a collection
export def "api collection env use" [
    collection: string  # Collection name
    name: string        # Environment name
] {
    if not (check-collection-exists $collection) { return }

    let env_path = (get-coll-env-path $collection $name)

    if not ($env_path | path exists) {
        print $"(ansi red)Environment '($name)' not found in collection '($collection)'(ansi reset)"
        print "Available environments:"
        api collection env list $collection
        return
    }

    mut meta = (load-coll-meta $collection)
    $meta = ($meta | upsert active_environment $name)
    save-coll-meta $collection $meta

    print $"(ansi green)Switched to environment '($name)' for collection '($collection)'(ansi reset)"
}

# Show environment variables for a collection
export def "api collection env show" [
    collection: string  # Collection name
    name?: string       # Environment name (defaults to active)
] {
    if not (check-collection-exists $collection) { return }

    let meta = (load-coll-meta $collection)

    let target = if $name != null {
        $name
    } else {
        $meta.active_environment? | default null
    }

    if $target == null {
        print $"(ansi yellow)No active environment for collection '($collection)'(ansi reset)"
        print $"Use 'api collection env use ($collection) <name>' to activate one."
        return
    }

    let env_path = (get-coll-env-path $collection $target)

    if not ($env_path | path exists) {
        print $"(ansi red)Environment '($target)' not found in collection '($collection)'(ansi reset)"
        return
    }

    let env_data = (open $env_path)

    print $"(ansi blue)Collection: ($collection)(ansi reset)"
    print $"(ansi blue)Environment: ($target)(ansi reset)"
    if ($env_data.description? | default "" | is-not-empty) {
        print $"Description: ($env_data.description)"
    }
    print ""

    if ($env_data.variables? | default {} | is-empty) {
        print "(ansi yellow)No variables set(ansi reset)"
    } else {
        $env_data.variables | transpose key value | table
    }
}

# Set a variable in a collection's environment
export def "api collection env set" [
    collection: string  # Collection name
    key: string         # Variable name
    value: string       # Variable value
    --target (-t): string  # Target environment (defaults to active)
] {
    if not (check-collection-exists $collection) { return }

    let meta = (load-coll-meta $collection)

    let target_env = if $target != null {
        $target
    } else {
        $meta.active_environment? | default null
    }

    if $target_env == null {
        print $"(ansi red)No active environment for collection '($collection)'(ansi reset)"
        print "Use --target to specify an environment or activate one first."
        return
    }

    let env_path = (get-coll-env-path $collection $target_env)

    if not ($env_path | path exists) {
        print $"(ansi red)Environment '($target_env)' not found in collection '($collection)'(ansi reset)"
        return
    }

    mut env_data = (open $env_path)
    $env_data = ($env_data | upsert variables ($env_data.variables | upsert $key $value))
    $env_data | to nuon | save -f $env_path

    print $"(ansi green)Set ($key) = ($value) in ($collection)/($target_env)(ansi reset)"
}

# Unset a variable in a collection's environment
export def "api collection env unset" [
    collection: string  # Collection name
    key: string         # Variable name to remove
    --target (-t): string  # Target environment (defaults to active)
] {
    if not (check-collection-exists $collection) { return }

    let meta = (load-coll-meta $collection)

    let target_env = if $target != null {
        $target
    } else {
        $meta.active_environment? | default null
    }

    if $target_env == null {
        print $"(ansi red)No active environment for collection '($collection)'(ansi reset)"
        print "Use --target to specify an environment or activate one first."
        return
    }

    let env_path = (get-coll-env-path $collection $target_env)

    if not ($env_path | path exists) {
        print $"(ansi red)Environment '($target_env)' not found in collection '($collection)'(ansi reset)"
        return
    }

    mut env_data = (open $env_path)

    if not ($key in ($env_data.variables? | default {})) {
        print $"(ansi yellow)Variable '($key)' not found in ($collection)/($target_env)(ansi reset)"
        return
    }

    $env_data = ($env_data | upsert variables ($env_data.variables | reject $key))
    $env_data | to nuon | save -f $env_path

    print $"(ansi green)Removed ($key) from ($collection)/($target_env)(ansi reset)"
}

# Delete an environment from a collection
export def "api collection env delete" [
    collection: string  # Collection name
    name: string        # Environment name to delete
    --force (-f)        # Skip confirmation
] {
    if not (check-collection-exists $collection) { return }

    let env_path = (get-coll-env-path $collection $name)

    if not ($env_path | path exists) {
        print $"(ansi red)Environment '($name)' not found in collection '($collection)'(ansi reset)"
        return
    }

    if not $force {
        let confirm = (input $"Delete environment '($name)' from collection '($collection)'? [y/N] ")
        if $confirm !~ "^[yY]" {
            print "Cancelled"
            return
        }
    }

    rm $env_path

    # Clear active environment if this was it
    mut meta = (load-coll-meta $collection)
    if ($meta.active_environment? == $name) {
        $meta = ($meta | upsert active_environment null)
        save-coll-meta $collection $meta
    }

    print $"(ansi green)Environment '($name)' deleted from collection '($collection)'(ansi reset)"
}

# --- Migration Helper ---

# Migrate root-level environments to a collection
export def "api migrate-envs" [
    collection: string  # Target collection to migrate environments to
] {
    let root = (get-api-root)
    let old_envs_dir = ($root | path join "environments")

    if not ($old_envs_dir | path exists) {
        print "(ansi yellow)No root-level environments to migrate(ansi reset)"
        return
    }

    let env_files = try { ls $old_envs_dir | where name =~ '\.nuon$' | get name } catch { [] }

    if ($env_files | is-empty) {
        print "(ansi yellow)No environment files found in environments/(ansi reset)"
        return
    }

    # Check if collection exists
    if not (check-collection-exists $collection) {
        print $"Creating collection '($collection)'..."
        api collection create $collection
    }

    let new_envs_dir = ($root | path join "collections" $collection "environments")
    if not ($new_envs_dir | path exists) {
        mkdir $new_envs_dir
    }

    print $"(ansi blue)Migrating environments to collection '($collection)':(ansi reset)"

    for file in $env_files {
        let env_data = (open $file)
        let name = ($file | path basename)
        let new_path = ($new_envs_dir | path join $name)

        if ($new_path | path exists) {
            print $"  (ansi yellow)Skipped: ($name) (already exists)(ansi reset)"
        } else {
            cp $file $new_path
            print $"  (ansi green)Migrated: ($name)(ansi reset)"
        }
    }

    print ""
    print $"(ansi green)Migration complete!(ansi reset)"
    print ""
    print "Next steps:"
    print $"  1. Set active environment: api collection env use ($collection) <env-name>"
    print $"  2. Delete old environments folder: rm -rf ($old_envs_dir)"
    print $"  3. Remove 'default_environment' from config.nuon if present"
}
