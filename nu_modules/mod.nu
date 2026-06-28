# API Client Module - Main Entry Point
# A Postman-like API testing tool built on curl and nushell

# Get the directory where this module is located
def get-api-root [] {
    $env.API_ROOT? | default (pwd)
}

# Export submodules
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

    # Count global variables
    let vars_path = ($root | path join "variables.nuon")
    let global_vars_count = if ($vars_path | path exists) {
        (open $vars_path) | columns | length
    } else { 0 }

    # Count collections
    let collections_path = ($root | path join "collections")
    let collection_count = if ($collections_path | path exists) {
        ls $collections_path | where type == dir | length
    } else { 0 }

    # Count history entries
    let history_path = ($root | path join "history")
    let history_count = if ($history_path | path exists) {
        let subdirs = try { ls $history_path | where type == dir | get name } catch { [] }
        let sub_counts = ($subdirs | each {|d| try { ls $d | where name =~ '\.nuon$' | length } catch { 0 } })
        if ($sub_counts | is-empty) { 0 } else { $sub_counts | math sum }
    } else { 0 }

    {
        root: $root
        global_vars: $global_vars_count
        collections: $collection_count
        history_entries: $history_count
    }
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
(ansi blue_bold)API Client — curl + nushell Postman replacement(ansi reset)

(ansi yellow)Setup:(ansi reset)
  api init                      Initialize workspace
  api status                    Show current status
  api config get                Show configuration
  api config set <key> <value>  Set configuration
  api help                      Show this help

(ansi yellow)Global Variables:(ansi reset)
  api vars list                 List global variables and built-ins
  api vars set <key> <value>    Set a global variable
  api vars unset <key>          Remove a global variable

(ansi yellow)Collection Environments:(ansi reset)
  api collection env list <c>          List environments for collection
  api collection env create <c> <n>    Create environment in collection
  api collection env use <c> <n>       Switch active environment
  api collection env show <c> [n]      Show environment variables
  api collection env set <c> <k> <v>   Set variable in active/specified env
  api collection env unset <c> <k>     Remove variable from active/specified env
  api collection env delete <c> <n>    Delete environment from collection

(ansi yellow)Authentication — stored credentials:(ansi reset)
  api auth bearer set <n> <t>          Store bearer token
  api auth bearer get <n>              Retrieve bearer token
  api auth bearer delete <n>           Delete bearer token
  api auth basic set <n> <u> <p>       Store basic auth credentials
  api auth basic get <n>               Retrieve basic auth credentials
  api auth basic delete <n>            Delete basic auth credentials
  api auth apikey set <n> <k>          Store API key \(default header: X-API-Key\)
  api auth apikey get <n>              Retrieve API key config
  api auth apikey delete <n>           Delete API key
  api auth oauth2 configure <n> ...    Configure OAuth2 provider
  api auth oauth2 token <n>            Fetch/refresh OAuth2 access token
  api auth oauth2 refresh <n>          Force-refresh OAuth2 token
  api auth oauth2 delete <n>           Delete OAuth2 config
  api auth list                        List all stored credential names
  api auth show                        Show auth status summary

(ansi yellow)Authentication — inline on any request via -a / --auth <record>:(ansi reset)
  Bearer token \(stored\):    -a {type: bearer, token_ref: mytoken}
  Bearer token \(inline\):    -a {type: bearer, token: "abc123"}
  Basic auth \(stored\):      -a {type: basic, creds_ref: mycreds}
  Basic auth \(inline\):      -a {type: basic, username: "u", password: "p"}
  API key \(stored\):         -a {type: apikey, key_ref: mykey}
  API key \(inline header\):  -a {type: apikey, key: "k", header: "X-API-Key"}
  OAuth2 \(stored\):          -a {type: oauth2, ref: myoauth}

(ansi yellow)Requests:(ansi reset)
  api get <url>                    GET request
  api post <url> -b <body>         POST request
  api put <url> -b <body>          PUT request
  api patch <url> -b <body>        PATCH request
  api delete <url>                 DELETE request
  api head <url>                   HEAD request — returns headers only, no body
  api options <url>                OPTIONS request
  api request <method> <url>       Generic request \(any HTTP method\)
  api send <name> -c <coll>        Send saved request; runs response assertions if defined

(ansi yellow)Common Request Flags:(ansi reset)
  -H, --headers <record>        Extra request headers, e.g. {"X-Custom": "value"}
  -a, --auth <record>           Inline auth spec \(see Authentication section above\)
  -o, --output <mode>           Output mode \(default: pretty\)
                                  pretty    print colored status+body, return null  [interactive]
                                  status    return HTTP status int, no print        [scripting]
                                  body      return parsed body value, no print      [scripting]
                                  headers   return response headers record, no print [scripting]
                                  json      return full result as JSON string, no print [scripting]
                                  none      return null, print nothing               [silent]
  -s, --select <path>           Return one field value, no print — e.g. body.id, status
                                  Shorthand body.* and headers.* expand automatically
  -r, --raw                     Return full result record, print nothing — best for scripting
  -v, --verbose                 Show request + response headers \(curl-style output\)
  -I, --include                 Include response headers above body in output
  -L, --follow-redirects        Follow HTTP redirects automatically
  -S, --save <file>             Save response body to file
  -B, --binary-save <file>      Save binary response directly to file \(no decode\)
  --retries <n>                 Retry count on 5xx/connection failure \(default: 0\)
  --retry-delay <s>             Seconds between retries \(default: 1\)
  --no-history                  Skip saving this request to history
  -d, --dry-run                 Print the curl command without executing it
  --debug                       Show full curl verbose output for debugging

(ansi yellow)Body Flags \(POST / PUT / PATCH / request\):(ansi reset)
  -b, --body <record|string>    Request body — records are JSON-serialized automatically
  -f, --body-file <file>        Read request body from a file
  -F, --form <record>           Form-encoded body — sets Content-Type to application/x-www-form-urlencoded

(ansi dark_gray)Note: on `api send`, -v is short for --vars \(variable substitution\). Use --verbose \(long form\) there.(ansi reset)

(ansi yellow)Saved Requests:(ansi reset)
  api request create <n> <m> <u>    Create saved request \(name method url\)
  api request list                   List saved requests across collections
  api request show <name>            Show request details
  api request update <name>          Update request fields
  api request delete <name>          Delete saved request
  api request export <name>          Print curl equivalent for saved request

(ansi yellow)Response Assertions \(in saved requests\):(ansi reset)
  A saved request may carry a `tests` record evaluated when run via `api send`.
  Keys:   status,  body.<dotpath>,  headers.<Name>
  Values: a bare literal \(exact match\), or a matcher record:
    {equals: VALUE}   exact match
    {contains: STR}   substring / list membership check
    {gt: N}           greater than
    {lt: N}           less than
    {not_null: true}  field must be present and non-null
  `api send` prints per-assertion pass/fail and sets tests_passed on the result.
  In --raw or other scripting output modes, assertion output is suppressed.

(ansi yellow)History:(ansi reset)
  api history list              List recent requests — indexed for speed
  api history show <id>         Show full request/response details
  api history resend <id>       Resend a past request
  api history search <query>    Full-text search across history
  api history rebuild-index     Rebuild the history index from raw files
  api history clear             Delete all history entries
  api history export <file>     Export history entries to a file

(ansi yellow)Collections:(ansi reset)
  api collection list              List collections
  api collection create <name>     Create collection
  api collection show <name>       Show collection details
  api collection delete <name>     Delete collection and all its requests
  api collection copy <src> <dst>  Copy collection to a new name

(ansi yellow)Chaining:(ansi reset)
  api chain create <name>       Create a new request chain
  api chain list                List all saved chains
  api chain show <name>         Show chain details and steps
  api chain delete <name>       Delete a chain
  api chain run <file>          Run a chain from a NUON definition file
  api chain exec <file>         Execute chain steps with context propagation

(ansi yellow)Response Helpers \(pass a --raw result record\):(ansi reset)
  api summary <result>          Compact one-line summary of a --raw result
  api explore <result>          Browse a --raw response interactively
  api pretty <result>           Pretty-print a stored --raw result

(ansi yellow)TUI:(ansi reset)
  api tui                       Launch the terminal UI

(ansi yellow)Scripting:(ansi reset)
  --raw / --output / --select modes RETURN typed values and print nothing — pipe cleanly.
  Default `pretty` mode prints to terminal and returns null \(interactive use\).

  api get URL -o body             # returns parsed body, prints nothing
  api get URL -s body.id          # returns one field value
  api get URL -o status           # returns HTTP status int
  api send create-user -c users -v {name: alice}
  let r = api get URL --raw
  \$r.response.status             # inspect status int
  \$r.response.body               # inspect full body
  \$r.response.headers            # inspect response headers record

(ansi dark_gray)Variable Resolution Order [narrowest wins]:(ansi reset)
  1. Request --vars flag \(api send only\)
  2. Collection active environment
  3. Global variables
  4. Built-in vars

Run `api <command> --help` for full flags on any command.
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
        return []
    }

    $collections
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
    } | to nuon --indent 4 | save ($collection_dir | path join "collection.nuon")

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

    # List requests
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
        $meta | to nuon --indent 4 | save -f $coll_file
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
    $meta | to nuon --indent 4 | save -f $path
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
    }
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
    } | to nuon --indent 4 | save $env_path

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
    if not (check-collection-exists $collection) { return null }

    let meta = (load-coll-meta $collection)

    let target = if $name != null {
        $name
    } else {
        $meta.active_environment? | default null
    }

    if $target == null {
        print $"(ansi yellow)No active environment for collection '($collection)'(ansi reset)"
        print $"Use 'api collection env use ($collection) <name>' to activate one."
        return null
    }

    let env_path = (get-coll-env-path $collection $target)

    if not ($env_path | path exists) {
        print $"(ansi red)Environment '($target)' not found in collection '($collection)'(ansi reset)"
        return null
    }

    let env_data = (open $env_path)

    {
        collection: $collection
        environment: $target
        description: ($env_data.description? | default "")
        variables: ($env_data.variables? | default {} | transpose key value)
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
    $env_data | to nuon --indent 4 | save -f $env_path

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
    $env_data | to nuon --indent 4 | save -f $env_path

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
