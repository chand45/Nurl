# Authentication Module
# Handles Bearer, Basic, API Key, and OAuth2 authentication

# Get secrets file path
def get-secrets-path [] {
    let root = ($env.API_ROOT? | default (pwd))
    $root | path join "secrets.nuon"
}

# Load secrets
def load-secrets [] {
    let path = (get-secrets-path)
    if ($path | path exists) {
        open $path
    } else {
        {
            tokens: {}
            oauth: {}
            api_keys: {}
            basic_auth: {}
        }
    }
}

# Save secrets
def save-secrets [secrets: record] {
    let path = (get-secrets-path)
    $secrets | to nuon | save -f $path
}

# --- Bearer Token Authentication ---

# Set a bearer token
export def "api auth bearer set" [
    name: string   # Token name/identifier
    token: string  # The bearer token
] {
    mut secrets = (load-secrets)
    $secrets = ($secrets | upsert tokens ($secrets.tokens | upsert $name { bearer: $token }))
    save-secrets $secrets
    print $"(ansi green)Bearer token '($name)' saved(ansi reset)"
}

# Get bearer token by name
export def "api auth bearer get" [name: string] {
    let secrets = (load-secrets)
    $secrets.tokens | get -o $name | get -o bearer
}

# Delete bearer token
export def "api auth bearer delete" [name: string] {
    mut secrets = (load-secrets)
    if $name in $secrets.tokens {
        $secrets = ($secrets | upsert tokens ($secrets.tokens | reject $name))
        save-secrets $secrets
        print $"(ansi green)Bearer token '($name)' deleted(ansi reset)"
    } else {
        print $"(ansi yellow)Token '($name)' not found(ansi reset)"
    }
}

# --- Basic Authentication ---

# Set basic auth credentials
export def "api auth basic set" [
    name: string      # Credentials name
    username: string  # Username
    password: string  # Password
] {
    mut secrets = (load-secrets)
    $secrets = ($secrets | upsert basic_auth ($secrets.basic_auth | upsert $name {
        username: $username
        password: $password
    }))
    save-secrets $secrets
    print $"(ansi green)Basic auth '($name)' saved(ansi reset)"
}

# Get basic auth credentials
export def "api auth basic get" [name: string] {
    let secrets = (load-secrets)
    $secrets.basic_auth | get -o $name
}

# Delete basic auth
export def "api auth basic delete" [name: string] {
    mut secrets = (load-secrets)
    if $name in $secrets.basic_auth {
        $secrets = ($secrets | upsert basic_auth ($secrets.basic_auth | reject $name))
        save-secrets $secrets
        print $"(ansi green)Basic auth '($name)' deleted(ansi reset)"
    } else {
        print $"(ansi yellow)Basic auth '($name)' not found(ansi reset)"
    }
}

# --- API Key Authentication ---

# Set API key
export def "api auth apikey set" [
    name: string                       # Key name
    key: string                        # The API key
    --header (-H): string = "X-API-Key"  # Header name (default: X-API-Key)
    --query (-q): string = ""          # Query parameter name (alternative to header)
] {
    mut secrets = (load-secrets)

    let key_config = if $query != "" {
        { key: $key, type: "query", param_name: $query }
    } else {
        { key: $key, type: "header", header_name: $header }
    }

    $secrets = ($secrets | upsert api_keys ($secrets.api_keys | upsert $name $key_config))
    save-secrets $secrets

    if $query != "" {
        print $"(ansi green)API key '($name)' saved [query param: ($query)](ansi reset)"
    } else {
        print $"(ansi green)API key '($name)' saved [header: ($header)](ansi reset)"
    }
}

# Get API key
export def "api auth apikey get" [name: string] {
    let secrets = (load-secrets)
    $secrets.api_keys | get -o $name
}

# Delete API key
export def "api auth apikey delete" [name: string] {
    mut secrets = (load-secrets)
    if $name in $secrets.api_keys {
        $secrets = ($secrets | upsert api_keys ($secrets.api_keys | reject $name))
        save-secrets $secrets
        print $"(ansi green)API key '($name)' deleted(ansi reset)"
    } else {
        print $"(ansi yellow)API key '($name)' not found(ansi reset)"
    }
}

# --- OAuth2 Authentication ---

# Configure OAuth2 client
export def "api auth oauth2 configure" [
    name: string                    # OAuth2 configuration name
    --client-id (-c): string        # Client ID
    --client-secret (-s): string    # Client secret
    --auth-url (-a): string = ""    # Authorization URL (for auth code flow)
    --token-url (-t): string        # Token URL
    --scope: string = ""            # OAuth scopes
    --redirect-uri: string = "http://localhost:8080/callback"  # Redirect URI
] {
    mut secrets = (load-secrets)

    $secrets = ($secrets | upsert oauth ($secrets.oauth | upsert $name {
        client_id: $client_id
        client_secret: $client_secret
        auth_url: $auth_url
        token_url: $token_url
        scope: $scope
        redirect_uri: $redirect_uri
        access_token: null
        refresh_token: null
        expires_at: null
    }))
    save-secrets $secrets
    print $"(ansi green)OAuth2 '($name)' configured(ansi reset)"
}

# Get OAuth2 access token (client credentials flow)
export def "api auth oauth2 token" [
    name: string  # OAuth2 configuration name
    --force (-f)  # Force refresh even if not expired
] {
    let secrets = (load-secrets)
    let config = ($secrets.oauth | get -o $name)

    if $config == null {
        print $"(ansi red)OAuth2 '($name)' not configured(ansi reset)"
        return null
    }

    # Check if we have a valid token
    if not $force and ($config.access_token? | default null) != null {
        let expires_at = ($config.expires_at? | default null)
        if $expires_at != null {
            let expiry = ($expires_at | into datetime)
            if (date now) < $expiry {
                return $config.access_token
            }
        }
    }

    # Request new token using client credentials
    let body = $"grant_type=client_credentials&client_id=($config.client_id)&client_secret=($config.client_secret)"
    let scope_param = if ($config.scope | default "" | is-not-empty) {
        $"&scope=($config.scope)"
    } else { "" }

    let output = (curl -s -X POST $config.token_url
        -H "Content-Type: application/x-www-form-urlencoded"
        -d $"($body)($scope_param)"
        | complete)

    if $output.exit_code != 0 {
        print $"(ansi red)OAuth2 token request failed(ansi reset)"
        return null
    }

    let response = try {
        $output.stdout | from json
    } catch {
        print $"(ansi red)Failed to parse OAuth2 response(ansi reset)"
        return null
    }

    if ($response.error? | default null) != null {
        print $"(ansi red)OAuth2 error: ($response.error) - ($response.error_description? | default '')(ansi reset)"
        return null
    }

    # Save token
    let expires_in = ($response.expires_in? | default 3600)
    let expires_at = ((date now) + ($expires_in | into duration --unit sec) | format date "%Y-%m-%dT%H:%M:%SZ")

    mut new_secrets = (load-secrets)
    mut oauth_config = ($new_secrets.oauth | get $name)
    $oauth_config = ($oauth_config | upsert access_token $response.access_token)
    $oauth_config = ($oauth_config | upsert expires_at $expires_at)
    if ($response.refresh_token? | default null) != null {
        $oauth_config = ($oauth_config | upsert refresh_token $response.refresh_token)
    }
    $new_secrets = ($new_secrets | upsert oauth ($new_secrets.oauth | upsert $name $oauth_config))
    save-secrets $new_secrets

    print $"(ansi green)OAuth2 token obtained, expires: ($expires_at)(ansi reset)"
    $response.access_token
}

# Refresh OAuth2 token
export def "api auth oauth2 refresh" [name: string] {
    let secrets = (load-secrets)
    let config = ($secrets.oauth | get -o $name)

    if $config == null {
        print $"(ansi red)OAuth2 '($name)' not configured(ansi reset)"
        return null
    }

    let refresh_token = ($config.refresh_token? | default null)
    if $refresh_token == null {
        print $"(ansi yellow)No refresh token available, getting new token...(ansi reset)"
        return (api auth oauth2 token $name --force)
    }

    let body = $"grant_type=refresh_token&refresh_token=($refresh_token)&client_id=($config.client_id)&client_secret=($config.client_secret)"

    let output = (curl -s -X POST $config.token_url
        -H "Content-Type: application/x-www-form-urlencoded"
        -d $body
        | complete)

    if $output.exit_code != 0 {
        print $"(ansi red)OAuth2 refresh failed(ansi reset)"
        return null
    }

    let response = try {
        $output.stdout | from json
    } catch {
        print $"(ansi red)Failed to parse OAuth2 response(ansi reset)"
        return null
    }

    if ($response.error? | default null) != null {
        print $"(ansi yellow)Refresh failed, getting new token...(ansi reset)"
        return (api auth oauth2 token $name --force)
    }

    # Save new token
    let expires_in = ($response.expires_in? | default 3600)
    let expires_at = ((date now) + ($expires_in | into duration --unit sec) | format date "%Y-%m-%dT%H:%M:%SZ")

    mut new_secrets = (load-secrets)
    mut oauth_config = ($new_secrets.oauth | get $name)
    $oauth_config = ($oauth_config | upsert access_token $response.access_token)
    $oauth_config = ($oauth_config | upsert expires_at $expires_at)
    if ($response.refresh_token? | default null) != null {
        $oauth_config = ($oauth_config | upsert refresh_token $response.refresh_token)
    }
    $new_secrets = ($new_secrets | upsert oauth ($new_secrets.oauth | upsert $name $oauth_config))
    save-secrets $new_secrets

    print $"(ansi green)OAuth2 token refreshed, expires: ($expires_at)(ansi reset)"
    $response.access_token
}

# Delete OAuth2 configuration
export def "api auth oauth2 delete" [name: string] {
    mut secrets = (load-secrets)
    if $name in $secrets.oauth {
        $secrets = ($secrets | upsert oauth ($secrets.oauth | reject $name))
        save-secrets $secrets
        print $"(ansi green)OAuth2 '($name)' deleted(ansi reset)"
    } else {
        print $"(ansi yellow)OAuth2 '($name)' not found(ansi reset)"
    }
}

# --- Utility Functions ---

# Get auth configuration for request
export def "api auth get-config" [auth_spec: record] {
    let auth_type = ($auth_spec.type? | default "none")
    let ref = ($auth_spec.token_ref? | default ($auth_spec.ref? | default ""))

    match $auth_type {
        "bearer" => {
            let token = if $ref != "" {
                api auth bearer get $ref
            } else {
                $auth_spec.token? | default ""
            }
            { type: "bearer", token: $token }
        }
        "basic" => {
            let creds = if $ref != "" {
                api auth basic get $ref
            } else {
                { username: ($auth_spec.username? | default ""), password: ($auth_spec.password? | default "") }
            }
            { type: "basic", username: $creds.username, password: $creds.password }
        }
        "api_key" | "apikey" => {
            let key_config = if $ref != "" {
                api auth apikey get $ref
            } else {
                { key: ($auth_spec.key? | default ""), type: "header", header_name: ($auth_spec.header? | default "X-API-Key") }
            }

            if ($key_config.type? | default "header") == "query" {
                { type: "apikey_query", key: $key_config.key, param_name: $key_config.param_name }
            } else {
                { type: "apikey_header", key: $key_config.key, header_name: $key_config.header_name }
            }
        }
        "oauth2" => {
            let token = (api auth oauth2 token $ref)
            { type: "bearer", token: $token }
        }
        _ => {}
    }
}

# Show all authentication configurations
export def "api auth show" [] {
    let secrets = (load-secrets)

    print $"(ansi blue)Bearer Tokens:(ansi reset)"
    if ($secrets.tokens | is-empty) {
        print "  (none)"
    } else {
        $secrets.tokens | transpose name config | each {|row|
            let masked = ($row.config.bearer | str substring 0..10) + "..."
            print $"  - ($row.name): ($masked)"
        } | ignore
    }

    print ""
    print $"(ansi blue)Basic Auth:(ansi reset)"
    if ($secrets.basic_auth | is-empty) {
        print "  (none)"
    } else {
        $secrets.basic_auth | transpose name config | each {|row|
            print $"  - ($row.name): ($row.config.username)"
        } | ignore
    }

    print ""
    print $"(ansi blue)API Keys:(ansi reset)"
    if ($secrets.api_keys | is-empty) {
        print "  (none)"
    } else {
        $secrets.api_keys | transpose name config | each {|row|
            let masked = ($row.config.key | str substring 0..10) + "..."
            let location = if ($row.config.type? | default "header") == "query" {
                $"query:($row.config.param_name)"
            } else {
                $"header:($row.config.header_name)"
            }
            print $"  - ($row.name): ($masked) (($location))"
        } | ignore
    }

    print ""
    print $"(ansi blue)OAuth2:(ansi reset)"
    if ($secrets.oauth | is-empty) {
        print "  (none)"
    } else {
        $secrets.oauth | transpose name config | each {|row|
            let status = if ($row.config.access_token? | default null) != null {
                let expires = ($row.config.expires_at? | default "")
                if $expires != "" {
                    $"(ansi green)active(ansi reset) \(expires: ($expires)\)"
                } else {
                    $"(ansi green)active(ansi reset)"
                }
            } else {
                $"(ansi yellow)not authenticated(ansi reset)"
            }
            print $"  - ($row.name): ($status)"
        } | ignore
    }
}

# List authentication names
export def "api auth list" [] {
    let secrets = (load-secrets)

    mut auth_list = []

    for item in ($secrets.tokens | transpose name value) {
        $auth_list = ($auth_list | append { name: $item.name, type: "bearer" })
    }

    for item in ($secrets.basic_auth | transpose name value) {
        $auth_list = ($auth_list | append { name: $item.name, type: "basic" })
    }

    for item in ($secrets.api_keys | transpose name value) {
        $auth_list = ($auth_list | append { name: $item.name, type: "apikey" })
    }

    for item in ($secrets.oauth | transpose name value) {
        $auth_list = ($auth_list | append { name: $item.name, type: "oauth2" })
    }

    $auth_list | table
}
