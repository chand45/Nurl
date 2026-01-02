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
            default_environment: null
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
    print "  - secrets.nuon: Credentials storage (gitignored)"
    print "  - collections/: Request collections"
    print "  - history/: Request/response history"
}

# Show current API client status
export def "api status" [] {
    let root = (get-api-root)
    let config = (api config get)

    print $"(ansi blue)API Client Status(ansi reset)"
    print $"Root: ($root)"
    print $"Current Environment: ($config.default_environment? | default 'none')"

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
            default_environment: null
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

(ansi yellow)Environments:(ansi reset)
  api env list                  List all environments
  api env create <name>         Create new environment
  api env use <name>            Switch active environment
  api env show [name]           Show environment variables
  api env set <key> <value>     Set variable in current env
  api env delete <name>         Delete environment

(ansi yellow)Authentication:(ansi reset)
  api auth bearer set <n> <t>   Set bearer token
  api auth basic set <n> <u> <p> Set basic auth
  api auth apikey set <n> <k>   Set API key
  api auth oauth2 configure ... Configure OAuth2
  api auth show                 Show auth status

(ansi yellow)Requests:(ansi reset)
  api get <url>                 GET request
  api post <url> -b <body>      POST request
  api put <url> -b <body>       PUT request
  api patch <url> -b <body>     PATCH request
  api delete <url>              DELETE request
  api send <name>               Send saved request
  api request create <name>     Create new request

(ansi yellow)History:(ansi reset)
  api history list              List recent requests
  api history show <id>         Show request details
  api history resend <id>       Resend a request
  api history search <query>    Search history

(ansi yellow)Collections:(ansi reset)
  api collection list           List collections
  api collection create <name>  Create collection
  api collection export <name>  Export collection
  api collection import <file>  Import collection

(ansi yellow)Chaining:(ansi reset)
  api chain run <file>          Run request chain

(ansi yellow)TUI:(ansi reset)
  api tui                       Launch terminal UI
"
}

# --- Collection Management ---

# List all collections
export def "api collection list" [] {
    let root = (get-api-root)
    let collections_dir = ($root | path join "collections")

    if not ($collections_dir | path exists) {
        print "(ansi yellow)No collections found(ansi reset)"
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
        print "(ansi yellow)No collections found(ansi reset)"
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
    print ""

    # List requests
    let requests_dir = ($collection_dir | path join "requests")
    if ($requests_dir | path exists) {
        let request_files = try { ls $requests_dir | where name =~ '\.nuon$' | get name } catch { [] }
        let requests = $request_files | each {|f|
            let req = (open $f)
            {
                name: ($req.name? | default ($f | path basename | str replace ".nuon" ""))
                method: ($req.method? | default "GET")
                url: ($req.url? | default "" | str substring 0..50)
            }
        }

        if not ($requests | is-empty) {
            print "(ansi yellow)Requests:(ansi reset)"
            $requests | table
        }
    }

    # List collection environments
    let envs_dir = ($collection_dir | path join "environments")
    if ($envs_dir | path exists) {
        let envs = try { ls $envs_dir | where name =~ '\.nuon$' | get name | each {|f| $f | path basename | str replace ".nuon" "" } } catch { [] }

        if not ($envs | is-empty) {
            print ""
            print "(ansi yellow)Environments:(ansi reset)"
            $envs | each {|e| print $"  - ($e)" }
        }
    }

    $meta
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
