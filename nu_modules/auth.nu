# Authentication Module
# Handles Bearer, SAML, Basic, API Key, and OAuth2 authentication

use command-error.nu [fail-command]
use string-compat.nu [ascii-upcase optional-get]

export const SAML_AUTH_SCHEME = "http://schemas.microsoft.com/dsts/saml2-bearer"

# Truncate a string to max length with ellipsis
def truncate-value [value: any, max_len: int = 40] {
    let str_val = if $value == null { "" } else { $value | into string }
    if ($str_val | str length) > $max_len {
        $"($str_val | str substring 0..$max_len)..."
    } else {
        $str_val
    }
}

# Get secrets file path
def get-secrets-path [] {
    let root = ($env.API_ROOT? | default (pwd))
    $root | path join "secrets.nuon"
}

# Default shape for newly created secret stores.
def default-secrets [] {
    {
        tokens: {}
        saml_tokens: {}
        oauth: {}
        api_keys: {}
        basic_auth: {}
    }
}

# Load secrets. Legacy files intentionally remain without saml_tokens until a SAML mutation.
def load-secrets [] {
    let path = (get-secrets-path)
    if ($path | path exists) {
        (default-secrets | reject saml_tokens) | merge (open $path)
    } else {
        default-secrets
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
    $secrets.tokens | optional-get $name | optional-get bearer
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

# --- SAML Authentication ---

def validate-saml-reference [value: any] {
    if (
        ($value | describe) != "string"
        or ($value | str trim | is-empty)
        or ($value | str contains "\r")
        or ($value | str contains "\n")
    ) {
        fail-command "SAML token reference must be a non-empty string"
    }
    $value
}

def saml-token-validation-error [value: any] {
    if ($value | describe) != "string" or ($value | str trim | is-empty) {
        return "empty"
    }
    if ($value | str contains "\r") or ($value | str contains "\n") {
        return "line-break"
    }
    if $value =~ ('(?i)^\s*' + ($SAML_AUTH_SCHEME | str replace --all "." '\.') + '(?:\s+|$)') {
        return "prefixed"
    }
    null
}

def validate-saml-token [value: any] {
    match (saml-token-validation-error $value) {
        "empty" => { fail-command "SAML token must be a non-empty string" }
        "line-break" => { fail-command "SAML token must not contain CR or LF" }
        "prefixed" => { fail-command "SAML token must be a bare token without an authentication scheme" }
        _ => {}
    }
    $value
}

def saved-saml-token [config: record, name: string, --metadata-only] {
    let token = ($config | optional-get "token")
    if (saml-token-validation-error $token) != null {
        fail-command $"SAML token '($name)' is malformed"
    }
    if $metadata_only { null } else { $token }
}

# Store a bare SAML token.
export def "api auth saml set" [
    name: any   # Token name/identifier
    token: any  # Bare SAML token
] {
    let validated_name = (validate-saml-reference $name)
    let validated_token = (validate-saml-token $token)
    mut secrets = (load-secrets)
    let saml_tokens = ($secrets.saml_tokens? | default {})
    $secrets = ($secrets | upsert saml_tokens ($saml_tokens | upsert $validated_name {token: $validated_token}))
    save-secrets $secrets
    print $"(ansi green)SAML token '($validated_name)' saved(ansi reset)"
}

# Get a SAML token by name.
export def "api auth saml get" [name: any] {
    let validated_name = (validate-saml-reference $name)
    let secrets = (load-secrets)
    let config = (($secrets.saml_tokens? | default {}) | optional-get $validated_name)
    if $config == null {
        null
    } else if not (($config | describe) | str starts-with "record") {
        fail-command $"SAML token '($validated_name)' is malformed"
    } else {
        saved-saml-token $config $validated_name
    }
}

# Delete a SAML token.
export def "api auth saml delete" [name: any] {
    let validated_name = (validate-saml-reference $name)
    mut secrets = (load-secrets)
    let saml_tokens = ($secrets.saml_tokens? | default {})
    if $validated_name in $saml_tokens {
        $secrets = ($secrets | upsert saml_tokens ($saml_tokens | reject $validated_name))
        save-secrets $secrets
        print $"(ansi green)SAML token '($validated_name)' deleted(ansi reset)"
    } else {
        print $"(ansi yellow)SAML token '($validated_name)' not found(ansi reset)"
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
    $secrets.basic_auth | optional-get $name
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
    $secrets.api_keys | optional-get $name
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

# Get an OAuth2 access token without exposing it through the public command.
def acquire-oauth2-token [
    name: string
    --force
] {
    let secrets = (load-secrets)
    let config = ($secrets.oauth | optional-get $name)

    if $config == null {
        fail-command $"OAuth2 '($name)' not configured"
    }

    # Check if we have a valid token
    if (not $force) and ($config.access_token? | default null) != null {
        let expires_at = ($config.expires_at? | default null)
        if $expires_at != null {
            let expiry = ($expires_at | into datetime)
            if (date now) < $expiry {
                return {
                    token: $config.access_token
                    expires_at: $expires_at
                }
            }
        }
    }

    # Request new token using client credentials
    let body = $"grant_type=client_credentials&client_id=($config.client_id)&client_secret=($config.client_secret)"
    let scope_param = if not ($config.scope | default "" | is-empty) {
        $"&scope=($config.scope)"
    } else { "" }

    let output = (do {
        curl -s -X POST $config.token_url -H "Content-Type: application/x-www-form-urlencoded" -d $"($body)($scope_param)" --write-out "\n%{http_code}"
    } | complete)

    let parsed = (parse-oauth-provider-response $output "OAuth2 token request failed")
    let response = $parsed.response

    # Save token
    let expires_in = $parsed.expires_in
    let expires_at = ((date now) + ($expires_in | into duration --unit sec) | format date "%Y-%m-%dT%H:%M:%SZ")

    mut new_secrets = (load-secrets)
    mut oauth_config = ($new_secrets.oauth | get $name)
    $oauth_config = ($oauth_config | upsert access_token $response.access_token)
    $oauth_config = ($oauth_config | upsert expires_at $expires_at)
    if $parsed.refresh_token != null {
        $oauth_config = ($oauth_config | upsert refresh_token $parsed.refresh_token)
    }
    $new_secrets = ($new_secrets | upsert oauth ($new_secrets.oauth | upsert $name $oauth_config))
    save-secrets $new_secrets

    {
        token: $response.access_token
        expires_at: $expires_at
    }
}

# Get OAuth2 access token (client credentials flow)
export def "api auth oauth2 token" [
    name: string  # OAuth2 configuration name
    --force (-f)  # Force refresh even if not expired
] {
    let result = (acquire-oauth2-token $name --force=$force)
    print $"(ansi green)OAuth2 token obtained, expires: ($result.expires_at)(ansi reset)"
}

def refresh-oauth2-token [name: string] {
    let secrets = (load-secrets)
    let config = ($secrets.oauth | optional-get $name)

    if $config == null {
        fail-command $"OAuth2 '($name)' not configured"
    }

    let refresh_token = ($config.refresh_token? | default null)
    if $refresh_token == null {
        return (acquire-oauth2-token $name --force)
    }

    let body = $"grant_type=refresh_token&refresh_token=($refresh_token)&client_id=($config.client_id)&client_secret=($config.client_secret)"

    let output = (do {
        curl -s -X POST $config.token_url -H "Content-Type: application/x-www-form-urlencoded" -d $body --write-out "\n%{http_code}"
    } | complete)

    let parsed = (parse-oauth-provider-response $output "OAuth2 refresh failed")
    let response = $parsed.response

    # Save new token
    let expires_in = $parsed.expires_in
    let expires_at = ((date now) + ($expires_in | into duration --unit sec) | format date "%Y-%m-%dT%H:%M:%SZ")

    mut new_secrets = (load-secrets)
    mut oauth_config = ($new_secrets.oauth | get $name)
    $oauth_config = ($oauth_config | upsert access_token $response.access_token)
    $oauth_config = ($oauth_config | upsert expires_at $expires_at)
    if $parsed.refresh_token != null {
        $oauth_config = ($oauth_config | upsert refresh_token $parsed.refresh_token)
    }
    $new_secrets = ($new_secrets | upsert oauth ($new_secrets.oauth | upsert $name $oauth_config))
    save-secrets $new_secrets

    {
        token: $response.access_token
        expires_at: $expires_at
    }
}

# Refresh OAuth2 token
export def "api auth oauth2 refresh" [name: string] {
    let result = (refresh-oauth2-token $name)
    print $"(ansi green)OAuth2 token refreshed, expires: ($result.expires_at)(ansi reset)"
}

# Delete OAuth2 configuration
export def "api auth oauth2 delete" [name: string] {
    mut secrets = (load-secrets)
    if $name in $secrets.oauth {
        $secrets = ($secrets | upsert oauth ($secrets.oauth | reject $name))
        save-secrets $secrets
        print $"(ansi green)OAuth2 '($name)' deleted(ansi reset)"
    } else {
        fail-command $"OAuth2 '($name)' not found"
    }
}

# --- Utility Functions ---

def parse-oauth-provider-response [output: record, failure_message: string] {
    if $output.exit_code != 0 {
        fail-command $failure_message
    }
    let parts = ($output.stdout | split row "\n")
    let status_text = ($parts | last | str trim)
    if not ($status_text =~ '^[0-9]{3}$') {
        fail-command "Failed to parse OAuth2 response"
    }
    let status = ($status_text | into int)
    let decoded = try {
        {value: ($parts | drop 1 | str join "\n" | from json), valid: true}
    } catch {
        {value: null, valid: false}
    }
    if $status < 200 or $status >= 300 {
        fail-oauth-provider-error $decoded.value $status
    }
    if (not $decoded.valid) or (not (($decoded.value | describe) | str starts-with "record")) {
        fail-oauth-invalid-response $status "expected a JSON object"
    }

    let response = $decoded.value
    if ($response.error? | default null) != null {
        fail-oauth-provider-error $response $status
    }
    let access_token = ($response.access_token? | default null)
    if $access_token == null or ($access_token | describe) != "string" or ($access_token | str trim | is-empty) {
        fail-oauth-invalid-response $status "access_token must be a non-empty string"
    }
    let refresh_token = ($response.refresh_token? | default null)
    if $refresh_token != null and (
        ($refresh_token | describe) != "string" or ($refresh_token | str trim | is-empty)
    ) {
        fail-oauth-invalid-response $status "refresh_token must be a non-empty string when present"
    }
    let token_type = ($response.token_type? | default null)
    if $token_type != null and (
        ($token_type | describe) != "string"
        or ($token_type | str trim | is-empty)
        or ($token_type | ascii-upcase) != "BEARER"
    ) {
        fail-oauth-invalid-response $status "token_type must be Bearer when present"
    }
    let expires_in = ($response.expires_in? | default 3600)
    if ($expires_in | describe) != "int" or $expires_in < 1 or $expires_in > 315360000 {
        fail-oauth-invalid-response $status "expires_in must be an integer between 1 and 315360000"
    }

    {
        response: $response
        status: $status
        expires_in: $expires_in
        refresh_token: $refresh_token
    }
}

def oauth-provider-error-code [response: any] {
    let raw_code = if (($response | describe) | str starts-with "record") {
        $response.error? | default "unknown_error"
    } else {
        "unknown_error"
    }
    let allowed_codes = [
        "invalid_request"
        "invalid_client"
        "invalid_grant"
        "unauthorized_client"
        "unsupported_grant_type"
        "invalid_scope"
        "server_error"
        "temporarily_unavailable"
        "invalid_token"
        "insufficient_scope"
        "unsupported_token_type"
        "invalid_target"
        "interaction_required"
        "login_required"
        "account_selection_required"
        "consent_required"
    ]
    let code = if ($raw_code | describe) == "string" and $raw_code in $allowed_codes {
        $raw_code
    } else {
        "unknown_error"
    }
    $code
}

def fail-oauth-provider-error [response: any, status: int] {
    let code = (oauth-provider-error-code $response)
    fail-command $"OAuth2 provider error: ($code) \(HTTP ($status)\)"
}

def fail-oauth-invalid-response [status: int, reason: string] {
    fail-command $"OAuth2 provider error: invalid_response \(HTTP ($status)\); ($reason)"
}

def auth-field [auth_spec: record, names: list<string>] {
    for name in $names {
        if $name in ($auth_spec | columns) {
            return {present: true, name: $name, value: ($auth_spec | optional-get $name)}
        }
    }
    {present: false, name: "", value: null}
}

def auth-reference [auth_spec: record, names: list<string>, label: string] {
    let field = (auth-field $auth_spec $names)
    if not $field.present {
        return ""
    }
    if ($field.value | describe) != "string" or ($field.value | str trim | is-empty) {
        fail-command $"($label) reference must be a non-empty string"
    }
    $field.value
}

def get-saved-auth-record [bucket: string, name: string, label: string] {
    let secrets = (load-secrets)
    let saved = ($secrets | optional-get $bucket)
    let config = if $saved == null { null } else { $saved | optional-get $name }
    if $config == null {
        fail-command $"($label) '($name)' not found"
    }
    if not (($config | describe) | str starts-with "record") {
        fail-command $"($label) '($name)' is malformed"
    }
    $config
}

def require-auth-string [
    config: record
    field: string
    label: string
    --allow-empty
] {
    let value = ($config | optional-get $field)
    if $value == null or ($value | describe) != "string" {
        fail-command $"($label) is malformed"
    }
    if (not $allow_empty) and ($value | str trim | is-empty) {
        fail-command $"($label) is malformed"
    }
    $value
}

def resolve-bearer-reference [name: string, --metadata-only] {
    let label = $"Bearer token '($name)'"
    let config = (get-saved-auth-record "tokens" $name "Bearer token")
    let token = (require-auth-string $config "bearer" $label)
    if $metadata_only { null } else { $token }
}

def resolve-saml-reference [name: string, --metadata-only] {
    let validated_name = (validate-saml-reference $name)
    let config = (get-saved-auth-record "saml_tokens" $validated_name "SAML token")
    saved-saml-token $config $validated_name --metadata-only=$metadata_only
}

def resolve-basic-reference [name: string, --metadata-only] {
    let label = $"Basic credentials '($name)'"
    let config = (get-saved-auth-record "basic_auth" $name "Basic credentials")
    let credentials = {
        username: (require-auth-string $config "username" $label --allow-empty)
        password: (require-auth-string $config "password" $label --allow-empty)
    }
    if $metadata_only { null } else { $credentials }
}

def resolve-apikey-reference [name: string, --metadata-only] {
    let label = $"API key '($name)'"
    let config = (get-saved-auth-record "api_keys" $name "API key")
    let location = (require-auth-string $config "type" $label | ascii-upcase)
    let key = if $metadata_only {
        require-auth-string $config "key" $label | ignore
        null
    } else {
        require-auth-string $config "key" $label
    }

    match $location {
        "HEADER" => {
            {
                type: "apikey_header"
                key: $key
                header_name: (require-auth-string $config "header_name" $label)
            }
        }
        "QUERY" => {
            {
                type: "apikey_query"
                key: $key
                param_name: (require-auth-string $config "param_name" $label)
            }
        }
        _ => { fail-command $"($label) is malformed" }
    }
}

def resolve-inline-apikey-shape [auth_spec: record] {
    let param = (auth-field $auth_spec ["param_name" "query"])
    let location = ($auth_spec.location? | default "" | into string | ascii-upcase)
    let query_mode = $param.present or $location == "QUERY"

    if $query_mode {
        if (not $param.present) or ($param.value | describe) != "string" or ($param.value | str trim | is-empty) {
            fail-command "Inline API key query authentication requires a non-empty parameter name"
        }
        {type: "apikey_query", param_name: $param.value}
    } else {
        let header = (auth-field $auth_spec ["header_name" "header"])
        let header_name = if $header.present { $header.value } else { "X-API-Key" }
        if ($header_name | describe) != "string" or ($header_name | str trim | is-empty) {
            fail-command "Inline API key header authentication requires a non-empty header name"
        }
        {type: "apikey_header", header_name: $header_name}
    }
}

def validate-oauth-reference [name: string] {
    let label = $"OAuth2 '($name)'"
    let config = (get-saved-auth-record "oauth" $name "OAuth2")
    require-auth-string $config "client_id" $label | ignore
    require-auth-string $config "client_secret" $label | ignore
    require-auth-string $config "token_url" $label | ignore
    for field in ["access_token" "refresh_token"] {
        let value = ($config | optional-get $field)
        if $value != null and (
            ($value | describe) != "string" or ($value | str trim | is-empty)
        ) {
            fail-command $"($label) is malformed"
        }
    }
    let expires_at = ($config.expires_at? | default null)
    if $expires_at != null {
        if ($expires_at | describe) != "string" or ($expires_at | str trim | is-empty) {
            fail-command $"($label) is malformed"
        }
        try {
            $expires_at | into datetime | ignore
        } catch {
            fail-command $"($label) is malformed"
        }
    }
}

def normalize-sensitive-name [name: string] {
    $name
    | ascii-upcase
    | str replace --all --regex '[-.\s]+' "_"
}

def sensitive-credential-name [name: string] {
    let normalized = (normalize-sensitive-name $name)
    $normalized in [
        "ACCESS_TOKEN"
        "ACCESSTOKEN"
        "REFRESH_TOKEN"
        "REFRESHTOKEN"
        "CLIENT_SECRET"
        "CLIENTSECRET"
        "AUTH_TOKEN"
        "AUTHTOKEN"
        "AUTHORIZATION_TOKEN"
        "AUTHORIZATIONTOKEN"
        "BEARER_TOKEN"
        "BEARERTOKEN"
        "ID_TOKEN"
        "IDTOKEN"
        "TOKEN"
        "API_KEY"
        "APIKEY"
        "API_TOKEN"
        "APITOKEN"
        "X_API_KEY"
        "X_API_TOKEN"
        "X_AUTH_TOKEN"
        "X_ACCESS_TOKEN"
        "X_TOKEN"
        "KEY"
        "PASSWORD"
        "PASSWD"
        "PWD"
        "X_PASSWORD"
        "X_PASSWD"
        "X_PWD"
    ]
}

def validate-url-parameter-name [raw_name: string, location: string] {
    let percent_residue = (
        $raw_name | str replace --all --regex '%[0-9A-Fa-f]{2}' ""
    )
    if ($percent_residue | str contains "%") {
        fail-command $"Malformed percent encoding in URL ($location) parameter name"
    }
    let decoded_result = try {
        {value: ($raw_name | url decode), error: null}
    } catch {
        {value: null, error: true}
    }
    if $decoded_result.error != null {
        fail-command $"Malformed percent encoding in URL ($location) parameter name"
    }
    if (sensitive-credential-name $decoded_result.value) {
        let safe_name = (normalize-sensitive-name $decoded_result.value)
        fail-command $"Unsafe URL ($location) parameter '($safe_name)' may contain credentials; use Nurl managed authentication with a named reference"
    }
}

def validate-url-parameter-list [parameters: string, location: string] {
    for parameter in ($parameters | split row "&") {
        let raw_name = ($parameter | split row -n 2 "=" | first)
        validate-url-parameter-name $raw_name $location
    }
}

export def validate-secret-safe-url [url: string] {
    let absolute_authority = ($url | parse -r '^[A-Za-z][A-Za-z0-9+.-]*://(?<authority>[^/?#]*)')
    let relative_authority = ($url | parse -r '^//(?<authority>[^/?#]*)')
    let authority = if not ($absolute_authority | is-empty) {
        $absolute_authority | first | get authority
    } else if not ($relative_authority | is-empty) {
        $relative_authority | first | get authority
    } else {
        null
    }
    if $authority != null and ($authority | str contains "@") {
        fail-command "Unsafe URL userinfo may contain credentials; use Nurl managed authentication with a named reference"
    }

    let fragment_parts = ($url | split row -n 2 "#")
    let before_fragment = ($fragment_parts | first)
    let query_parts = ($before_fragment | split row -n 2 "?")
    if ($query_parts | length) == 2 {
        validate-url-parameter-list ($query_parts | last) "query"
    }

    if ($fragment_parts | length) == 2 {
        let fragment = ($fragment_parts | last)
        if (
            ($fragment | str contains "=")
            or ($fragment | str contains "?")
            or ($fragment | str contains "&")
        ) {
            for component in ($fragment | split row --regex '[?&]') {
                let raw_name = ($component | split row -n 2 "=" | first)
                validate-url-parameter-name $raw_name "fragment"
            }
        }
    }

    $url
}

export def sensitive-header [name: string, value: any] {
    let normalized = (normalize-sensitive-name $name)
    let sensitive_name = (
        $normalized in [
            "AUTHORIZATION"
            "PROXY_AUTHORIZATION"
            "COOKIE"
            "SET_COOKIE"
            "X_TOKEN"
        ]
        or (sensitive-credential-name $name)
        or ($normalized =~ '(^|_)(TOKEN|SECRET|SESSION|API_?KEY)(_|$)')
    )
    $sensitive_name or (($value | into string) =~ '(?i)^\s*(bearer|basic|http://schemas\.microsoft\.com/dsts/saml2-bearer)\s+')
}

export def redact-sensitive-headers [headers: record] {
    $headers | transpose key value | reduce -f {} {|header, redacted|
        $redacted | upsert $header.key (
            if (sensitive-header $header.key $header.value) {
                "******"
            } else {
                $header.value
            }
        )
    }
}

def non-replayable-apikey-history [auth_spec: record, auth_type: string] {
    let shape = match $auth_type {
        "APIKEY_QUERY" => {
            let name = (require-auth-string $auth_spec "param_name" "Inline API key query authentication")
            {location: "query", param_name: $name}
        }
        "APIKEY_HEADER" => {
            let name = (require-auth-string $auth_spec "header_name" "Inline API key header authentication")
            {location: "header", header_name: $name}
        }
        _ => {
            let resolved = (resolve-inline-apikey-shape $auth_spec)
            if $resolved.type == "apikey_query" {
                {location: "query", param_name: $resolved.param_name}
            } else {
                {location: "header", header_name: $resolved.header_name}
            }
        }
    }
    {type: "api_key", replayable: false} | merge $shape
}

# Convert caller, wire, or already-canonical auth into secret-free history metadata.
export def auth-history-projection [auth_spec: record] {
    if ($auth_spec | is-empty) {
        return null
    }

    let raw_type = ($auth_spec.type? | default null)
    if $raw_type == null or ($raw_type | describe) != "string" or ($raw_type | str trim | is-empty) {
        fail-command "Authentication type must be a non-empty string"
    }
    let auth_type = ($raw_type | ascii-upcase)
    let replayable = ($auth_spec.replayable? | default null)

    match $auth_type {
        "NONE" => { null }
        "BEARER" => {
            let ref = (auth-reference $auth_spec ["token_ref" "ref"] "******")
            if not ($ref | is-empty) {
                resolve-bearer-reference $ref --metadata-only | ignore
                {type: "bearer", ref: $ref, replayable: true}
            } else if ("token" in ($auth_spec | columns)) or $replayable == false {
                if "token" in ($auth_spec | columns) {
                    require-auth-string $auth_spec "token" "Inline bearer authentication" | ignore
                }
                {type: "bearer", replayable: false}
            } else {
                fail-command "Bearer history authentication is malformed"
            }
        }
        "SAML" => {
            let ref = (auth-reference $auth_spec ["token_ref" "ref"] "SAML token")
            if not ($ref | is-empty) {
                validate-saml-reference $ref | ignore
                resolve-saml-reference $ref --metadata-only | ignore
                {type: "saml", ref: $ref, replayable: true}
            } else if ("token" in ($auth_spec | columns)) or $replayable == false {
                if "token" in ($auth_spec | columns) {
                    validate-saml-token ($auth_spec | optional-get "token") | ignore
                }
                {type: "saml", replayable: false}
            } else {
                fail-command "SAML history authentication is malformed"
            }
        }
        "BASIC" => {
            let ref = (auth-reference $auth_spec ["creds_ref" "ref"] "Basic credentials")
            if not ($ref | is-empty) {
                resolve-basic-reference $ref --metadata-only | ignore
                {type: "basic", ref: $ref, replayable: true}
            } else if ("username" in ($auth_spec | columns)) or ("password" in ($auth_spec | columns)) {
                require-auth-string $auth_spec "username" "Inline basic authentication" --allow-empty | ignore
                require-auth-string $auth_spec "password" "Inline basic authentication" --allow-empty | ignore
                {type: "basic", replayable: false}
            } else if $replayable == false {
                {type: "basic", replayable: false}
            } else {
                fail-command "Basic history authentication is malformed"
            }
        }
        "API_KEY" | "APIKEY" | "APIKEY_HEADER" | "APIKEY_QUERY" => {
            let ref = (auth-reference $auth_spec ["key_ref" "ref"] "API key")
            if not ($ref | is-empty) {
                resolve-apikey-reference $ref --metadata-only | ignore
                {type: "api_key", ref: $ref, replayable: true}
            } else if ("key" in ($auth_spec | columns)) or $replayable == false {
                if "key" in ($auth_spec | columns) {
                    require-auth-string $auth_spec "key" "Inline API key authentication" | ignore
                }
                non-replayable-apikey-history $auth_spec $auth_type
            } else {
                fail-command "API key history authentication is malformed"
            }
        }
        "OAUTH2" => {
            let ref = (auth-reference $auth_spec ["ref"] "OAuth2")
            if ($ref | is-empty) {
                fail-command "OAuth2 history authentication requires a non-empty ref"
            }
            validate-oauth-reference $ref
            {type: "oauth2", ref: $ref, replayable: true}
        }
        _ => { fail-command $"Unsupported authentication type '($raw_type)'" }
    }
}

# Prepare separate safe display/history projections and a secret-bearing wire projection.
# Display-only preparation validates references but never acquires or refreshes OAuth tokens.
export def prepare-auth-context [
    auth_spec: record
    --display-only
] {
    if ($auth_spec | is-empty) {
        return {display: {}, history: null, wire: null}
    }

    let raw_type = ($auth_spec.type? | default null)
    if $raw_type == null or ($raw_type | describe) != "string" or ($raw_type | str trim | is-empty) {
        fail-command "Authentication type must be a non-empty string"
    }
    let auth_type = ($raw_type | ascii-upcase)

    match $auth_type {
        "NONE" => { {display: {}, history: null, wire: null} }
        "BEARER" => {
            let ref = (auth-reference $auth_spec ["token_ref" "ref"] "Bearer token")
            let named = not ($ref | is-empty)
            let token = if $named {
                resolve-bearer-reference $ref --metadata-only=$display_only
            } else {
                let inline_token = ($auth_spec.token? | default null)
                if $inline_token == null or ($inline_token | describe) != "string" or ($inline_token | str trim | is-empty) {
                    fail-command "Bearer token is missing"
                }
                $inline_token
            }
            {
                display: {type: "bearer", token: "******"}
                history: (if $named {
                    {type: "bearer", ref: $ref, replayable: true}
                } else {
                    {type: "bearer", replayable: false}
                })
                wire: (if $display_only { null } else { {type: "bearer", token: $token} })
            }
        }
        "SAML" => {
            let ref = (auth-reference $auth_spec ["token_ref" "ref"] "SAML token")
            let named = not ($ref | is-empty)
            let token = if $named {
                validate-saml-reference $ref | ignore
                resolve-saml-reference $ref --metadata-only=$display_only
            } else {
                validate-saml-token ($auth_spec.token? | default null)
            }
            {
                display: {type: "saml", token: "******"}
                history: (if $named {
                    {type: "saml", ref: $ref, replayable: true}
                } else {
                    {type: "saml", replayable: false}
                })
                wire: (if $display_only { null } else { {type: "saml", token: $token} })
            }
        }
        "BASIC" => {
            let ref = (auth-reference $auth_spec ["creds_ref" "ref"] "Basic credentials")
            let named = not ($ref | is-empty)
            let credentials = if $named {
                resolve-basic-reference $ref --metadata-only=$display_only
            } else {
                {
                    username: (require-auth-string $auth_spec "username" "Inline basic authentication" --allow-empty)
                    password: (require-auth-string $auth_spec "password" "Inline basic authentication" --allow-empty)
                }
            }
            {
                display: {type: "basic", username: "******", password: "******"}
                history: (if $named {
                    {type: "basic", ref: $ref, replayable: true}
                } else {
                    {type: "basic", replayable: false}
                })
                wire: (if $display_only {
                    null
                } else {
                    {type: "basic", username: $credentials.username, password: $credentials.password}
                })
            }
        }
        "API_KEY" | "APIKEY" => {
            let ref = (auth-reference $auth_spec ["key_ref" "ref"] "API key")
            let named = not ($ref | is-empty)
            let shape = if $named {
                resolve-apikey-reference $ref --metadata-only=$display_only
            } else {
                resolve-inline-apikey-shape $auth_spec
            }
            let key = if $named {
                $shape.key
            } else {
                require-auth-string $auth_spec "key" "Inline API key authentication"
            }
            let display = if $shape.type == "apikey_query" {
                {type: "apikey_query", key: "******", param_name: $shape.param_name}
            } else {
                {type: "apikey_header", key: "******", header_name: $shape.header_name}
            }
            let inline_history = if $shape.type == "apikey_query" {
                {type: "api_key", location: "query", param_name: $shape.param_name, replayable: false}
            } else {
                {type: "api_key", location: "header", header_name: $shape.header_name, replayable: false}
            }
            let wire = if $display_only {
                null
            } else if $shape.type == "apikey_query" {
                {type: "apikey_query", key: $key, param_name: $shape.param_name}
            } else {
                {type: "apikey_header", key: $key, header_name: $shape.header_name}
            }
            {
                display: $display
                history: (if $named {
                    {type: "api_key", ref: $ref, replayable: true}
                } else {
                    $inline_history
                })
                wire: $wire
            }
        }
        "OAUTH2" => {
            let ref = (auth-reference $auth_spec ["ref"] "OAuth2")
            if ($ref | is-empty) {
                fail-command "OAuth2 authentication requires a non-empty ref"
            }
            validate-oauth-reference $ref
            let wire = if $display_only {
                null
            } else {
                let result = (acquire-oauth2-token $ref)
                {type: "bearer", token: $result.token}
            }
            {
                display: {type: "bearer", token: "******"}
                history: {type: "oauth2", ref: $ref, replayable: true}
                wire: $wire
            }
        }
        _ => { fail-command $"Unsupported authentication type '($raw_type)'" }
    }
}

# Get secret-bearing auth configuration for real request execution.
export def "api auth get-config" [auth_spec: record] {
    let context = (prepare-auth-context $auth_spec)
    $context.wire? | default {}
}

# Show all authentication configurations
export def "api auth show" [
    --full (-f)  # Show full values without truncation
] {
    let secrets = (load-secrets)
    mut result = []

    # Bearer tokens
    if not ($secrets.tokens | is-empty) {
        $result = ($result | append ($secrets.tokens | transpose name config | each {|row|
            { name: $row.name, type: "bearer", status: "configured", value: $row.config.bearer }
        }))
    }

    # SAML tokens
    let saml_tokens = ($secrets.saml_tokens? | default {})
    if not ($saml_tokens | is-empty) {
        $result = ($result | append ($saml_tokens | transpose name config | each {|row|
            let value = if (($row.config | describe) | str starts-with "record") {
                $row.config.token? | default ""
            } else {
                ""
            }
            { name: $row.name, type: "saml", status: "configured", value: $value }
        }))
    }

    # Basic auth
    if not ($secrets.basic_auth | is-empty) {
        $result = ($result | append ($secrets.basic_auth | transpose name config | each {|row|
            { name: $row.name, type: "basic", status: "configured", value: $row.config.username }
        }))
    }

    # API keys
    if not ($secrets.api_keys | is-empty) {
        $result = ($result | append ($secrets.api_keys | transpose name config | each {|row|
            let location = if ($row.config.type? | default "header") == "query" {
                $"query:($row.config.param_name)"
            } else {
                $"header:($row.config.header_name)"
            }
            { name: $row.name, type: "apikey", status: $location, value: $row.config.key }
        }))
    }

    # OAuth2
    if not ($secrets.oauth | is-empty) {
        $result = ($result | append ($secrets.oauth | transpose name config | each {|row|
            let status = if ($row.config.access_token? | default null) != null {
                let expires = ($row.config.expires_at? | default "")
                if $expires != "" { "active (expires: " + $expires + ")" } else { "active" }
            } else {
                "not authenticated"
            }
            let token = ($row.config.access_token? | default "")
            { name: $row.name, type: "oauth2", status: $status, value: $token }
        }))
    }

    # Apply truncation for display unless --full flag is set
    if $full {
        $result
    } else {
        $result | each {|row|
            {
                name: (truncate-value $row.name 15)
                type: $row.type
                status: (truncate-value $row.status 20)
                value: (if $row.type == "saml" { "******" } else { truncate-value $row.value 15 })
            }
        }
    }
}

# List authentication names
export def "api auth list" [] {
    let secrets = (load-secrets)

    mut auth_list = []

    for item in ($secrets.tokens | transpose name value) {
        $auth_list = ($auth_list | append { name: $item.name, type: "bearer" })
    }

    for item in (($secrets.saml_tokens? | default {}) | transpose name value) {
        $auth_list = ($auth_list | append { name: $item.name, type: "saml" })
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

    $auth_list
}
