# Independent subprocess checks for credential safety at public command boundaries.

def blackbox-secret [label: string] {
    $"BB-($label)-((random uuid))"
}

def assert-blackbox-no-values [text: string, values: list<string>, label: string] {
    for value in $values {
        assert (not ($text | str contains $value)) $"($label) exposed a credential value"
    }
}

def assert-blackbox-success [
    result: record
    label: string
    secrets: list<string> = []
    --allow-ansi
] {
    assert equal $result.exit_code 0 $"($label) failed: ($result.stderr)"
    assert equal ($result.stderr | str trim) "" $"($label) wrote stderr"
    if not $allow_ansi {
        assert equal $result.stdout ($result.stdout | ansi strip) $"($label) stdout contained ANSI"
    }
    assert equal $result.stderr ($result.stderr | ansi strip) $"($label) stderr contained ANSI"
    assert-blackbox-no-values $"($result.stdout)\n($result.stderr)" $secrets $label
}

def assert-blackbox-failure [
    result: record
    label: string
    expected: string
    secrets: list<string> = []
] {
    assert ($result.exit_code != 0) $"($label) unexpectedly exited zero"
    assert equal ($result.stdout | str trim) "" $"($label) wrote stdout"
    assert ($result.stderr | str contains $expected) $"($label) omitted '($expected)': ($result.stderr)"
    assert equal $result.stdout ($result.stdout | ansi strip) $"($label) stdout contained ANSI"
    assert equal $result.stderr ($result.stderr | ansi strip) $"($label) stderr contained ANSI"
    assert-blackbox-no-values $"($result.stdout)\n($result.stderr)" $secrets $label
}

def assert-blackbox-preview [
    result: record
    label: string
    secrets: list<string>
    expected: list<string>
] {
    assert-blackbox-success $result $label $secrets
    let lines = ($result.stdout | lines | where {|line| not ($line | is-empty) })
    assert equal ($lines | length) 1 $"($label) did not emit one curl command"
    assert (($lines | first) | str starts-with "curl ") $"($label) did not emit curl"
    assert ($result.stdout | str contains "******") $"($label) omitted masking"
    for fragment in $expected {
        assert ($result.stdout | str contains $fragment) $"($label) omitted ($fragment)"
    }
}

def blackbox-history-bytes [root: string] {
    let history = ($root | path join "history")
    if not ($history | path exists) {
        return ""
    }
    command-error-snapshot $history | get content | compact | str join "\n"
}

def blackbox-init [root: string] {
    let result = (run-command-process $root "api init | ignore")
    assert-blackbox-success $result "api init" --allow-ansi
}

def with-blackbox-server [prefix: string, test: closure] {
    let root = (make-temp-dir $"blackbox-($prefix)")
    let infra = (make-temp-dir $"blackbox-($prefix)-server")
    let started = try {
        {server: (start-command-error-server $infra), error: null}
    } catch {|error|
        {server: null, error: $error}
    }
    if $started.error != null {
        cleanup $root
        cleanup $infra
        error make {msg: $started.error.msg}
    }

    let failure = try {
        do $test $root $started.server
        null
    } catch {|error| $error }
    let stop_failure = try {
        stop-command-error-server $started.server
        null
    } catch {|error| $error }
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def test-blackbox-masking-and-rotation [] {
    with-blackbox-server "mask-rotate" {|root, server|
        blackbox-init $root
        let base = $"http://127.0.0.1:($server.port)"
        let basic_a = (blackbox-secret "BASIC-A")
        let basic_b = (blackbox-secret "BASIC-B")
        let key_a = (blackbox-secret "KEY-A")
        let key_b = (blackbox-secret "KEY-B")
        let secrets = [$basic_a $basic_b $key_a $key_b]
        let setup_command = ([
            $"api auth basic set bb-basic bb-user ($basic_a | to nuon) | ignore"
            $"api auth apikey set bb-key ($key_a | to nuon) --header X-API-Key | ignore"
            "api collection create bb | ignore"
            $"api request create basic GET (($base + '/basic') | to nuon) --collection bb --auth ({type: basic, ref: bb-basic} | to nuon) | ignore"
            $"api request create key GET (($base + '/key') | to nuon) --collection bb --auth ({type: api_key, ref: bb-key} | to nuon) | ignore"
        ] | str join "\n")
        let setup = (run-command-process $root $setup_command)
        assert-blackbox-success $setup "named auth setup" $secrets --allow-ansi

        let preview_before = (command-error-snapshot $root)
        let previews = [
            {
                label: "basic dry-run"
                command: $"api get (($base + '/basic-preview') | to nuon) --auth ({type: basic, ref: bb-basic} | to nuon) --dry-run"
                expected: ["-u ******:******"]
            }
            {label: "basic export", command: "api request export basic --collection bb", expected: ["-u ******:******"]}
            {
                label: "API-key dry-run"
                command: $"api get (($base + '/key-preview') | to nuon) --auth ({type: api_key, ref: bb-key} | to nuon) --dry-run"
                expected: ["X-API-Key: ******"]
            }
            {label: "API-key export", command: "api request export key --collection bb", expected: ["X-API-Key: ******"]}
        ]
        for case in $previews {
            assert-blackbox-preview (run-command-process $root $case.command) $case.label $secrets $case.expected
        }
        assert equal (command-error-snapshot $root) $preview_before "previews mutated the workspace"
        assert equal (command-error-wire-events $server | length) 0 "previews reached the network"

        let basic_send = (run-command-process $root ([
            "let index_path = ($env.API_ROOT | path join 'history' 'index.nuon')"
            "let before = (if ($index_path | path exists) { open $index_path | get id } else { [] })"
            "api send basic --collection bb --raw | ignore"
            "open $index_path | get id | where {|id| $id not-in $before} | first"
        ] | str join "\n"))
        assert-blackbox-success $basic_send "basic execution" $secrets
        let basic_id = ($basic_send.stdout | str trim)
        let key_send = (run-command-process $root ([
            "let index_path = ($env.API_ROOT | path join 'history' 'index.nuon')"
            "let before = (if ($index_path | path exists) { open $index_path | get id } else { [] })"
            "api send key --collection bb --raw | ignore"
            "open $index_path | get id | where {|id| $id not-in $before} | first"
        ] | str join "\n"))
        assert-blackbox-success $key_send "API-key execution" $secrets
        let key_id = ($key_send.stdout | str trim)

        let rotate_command = ([
            $"api auth basic set bb-basic bb-user ($basic_b | to nuon) | ignore"
            $"api auth apikey set bb-key ($key_b | to nuon) --header X-API-Key | ignore"
        ] | str join "\n")
        let rotate = (run-command-process $root $rotate_command)
        assert-blackbox-success $rotate "credential rotation" $secrets --allow-ansi
        for replay in [
            {label: "basic replay", id: $basic_id}
            {label: "API-key replay", id: $key_id}
        ] {
            let result = (run-command-process $root $"api history resend ($replay.id | to nuon) --raw | ignore")
            assert-blackbox-success $result $replay.label $secrets
        }

        let basic_wire = (command-error-wire-events $server | where path == "/basic")
        assert equal ($basic_wire | length) 2
        assert equal ($basic_wire | first | get authorization) $"Basic ($"bb-user:($basic_a)" | encode base64)"
        assert equal ($basic_wire | last | get authorization) $"Basic ($"bb-user:($basic_b)" | encode base64)"
        let key_wire = (command-error-wire-events $server | where path == "/key")
        assert equal ($key_wire | length) 2
        assert equal ($key_wire | first | get api_key) $key_a
        assert equal ($key_wire | last | get api_key) $key_b

        for id in [$basic_id $key_id] {
            let shown = (run-command-process $root $"api history get ($id | to nuon) | to nuon")
            assert-blackbox-success $shown "named history read" $secrets
            assert ($shown.stdout | str contains "replayable: true")
        }
        assert-blackbox-no-values (blackbox-history-bytes $root) $secrets "named history bytes"
    }
}

def test-blackbox-direct-save-sanitizes [] {
    with-blackbox-server "direct-save" {|root, server|
        blackbox-init $root
        let base = $"http://127.0.0.1:($server.port)"
        let bearer = (blackbox-secret "INLINE")
        let authorization = (blackbox-secret "AUTH-HEADER")
        let api_key = (blackbox-secret "API-HEADER")
        let secrets = [$bearer $authorization $api_key]
        let request = {
            method: GET
            url: $"($base)/direct-save"
            headers: {Authorization: $authorization, X-API-Key: $api_key, X-Keep: exact}
            body: null
            auth: {type: bearer, token: $bearer}
        }
        let response = {status: 200, status_text: OK, headers: {}, body: null, time_ms: 1, size_bytes: 0}
        let saved = (run-command-process $root $"api history save ($request | to nuon) ($response | to nuon)")
        assert-blackbox-success $saved "direct history save" $secrets
        let id = ($saved.stdout | str trim)
        assert (not ($id | is-empty))

        let export_path = ($root | path join "blackbox-history.json")
        let readers = [
            $"api history get ($id | to nuon) | to nuon"
            $"api history show ($id | to nuon) | to nuon"
            $"api history export --format json --output ($export_path | to nuon) | ignore"
        ]
        for command in $readers {
            assert-blackbox-success (run-command-process $root $command) "direct history reader" $secrets --allow-ansi
        }
        let get_result = (run-command-process $root $"api history get ($id | to nuon) | to nuon")
        assert-blackbox-success $get_result "direct history shape" $secrets
        let entry = ($get_result.stdout | from nuon)
        assert equal $entry.request.auth {type: bearer, replayable: false}
        assert equal $entry.request.headers.Authorization "******"
        assert equal $entry.request.headers.X-API-Key "******"
        assert equal $entry.request.headers.X-Keep exact
        assert equal $entry.request.headers_replayable false
        assert-blackbox-no-values (blackbox-history-bytes $root) $secrets "direct history bytes"
        assert-blackbox-no-values (open $export_path --raw) $secrets "direct history export"

        let before = (command-error-snapshot $root)
        let wire_before = (command-error-wire-events $server | length)
        let resent = (run-command-process $root $"api history resend ($id | to nuon) --raw")
        assert-blackbox-failure $resent "default inline resend" "pass --auth" $secrets
        assert equal (command-error-snapshot $root) $before "failed resend mutated state"
        assert equal (command-error-wire-events $server | length) $wire_before "failed resend reached the network"
        assert (not ((open $server.wire_file --raw) | str contains "******")) "failed resend sent mask text"
    }
}

def test-blackbox-query-encoding [] {
    with-blackbox-server "query-encoding" {|root, server|
        blackbox-init $root
        let base = $"http://127.0.0.1:($server.port)"
        let name = "bb&name=#%+ space世界"
        let key = $"(blackbox-secret 'QUERY')&x=1#%=+ 世界"
        let encoded_name = "bb%26name%3D%23%25%2B%20space%E4%B8%96%E7%95%8C"
        let key_prefix = ($key | split row "&" | first)
        let encoded_key = $"($key_prefix)%26x%3D1%23%25%3D%2B%20%E4%B8%96%E7%95%8C"
        let setup = (run-command-process $root $"api auth apikey set bb-query ($key | to nuon) --query ($name | to nuon) | ignore")
        assert-blackbox-success $setup "query auth setup" [$key] --allow-ansi

        let before = (command-error-snapshot $root)
        let preview = (run-command-process $root $"api get (($base + '/encoded?existing=1#frag') | to nuon) --auth ({type: api_key, ref: bb-query} | to nuon) --dry-run")
        assert-blackbox-preview $preview "query dry-run" [$key $encoded_key] [$"existing=1&($encoded_name)=******#frag"]
        assert (not ($preview.stdout | str contains "%2526")) "query name was encoded twice in preview"
        assert equal (command-error-snapshot $root) $before "query preview mutated state"
        assert equal (command-error-wire-events $server | length) 0

        let sent = (run-command-process $root $"api get (($base + '/encoded?existing=1#frag') | to nuon) --auth ({type: api_key, ref: bb-query} | to nuon) --raw | ignore")
        assert-blackbox-success $sent "query execution" [$key]
        let events = (command-error-wire-events $server)
        assert equal ($events | length) 1
        assert equal ($events | first | get path) $"/encoded?existing=1&($encoded_name)=($encoded_key)"
        assert (not (($events | first | get path) | str contains "%2526")) "query components were encoded twice"
        assert-blackbox-no-values (blackbox-history-bytes $root) [$key $encoded_key] "query history"
    }
}

def test-blackbox-oauth-error-description [] {
    with-blackbox-server "oauth-description" {|root, server|
        blackbox-init $root
        let base = $"http://127.0.0.1:($server.port)"
        let client_secret = (["CLIENT" "SECRET" "ERROR" "SENTINEL"] | str join "-")
        let setup = (run-command-process $root $"api auth oauth2 configure bb-error --client-id bb-client --client-secret ($client_secret | to nuon) --token-url (($base + '/token-error-initial') | to nuon) | ignore")
        assert-blackbox-success $setup "OAuth error setup" [$client_secret] --allow-ansi

        let before = (command-error-snapshot $root)
        let count_before = (open $server.count_file --raw | str trim | into int)
        let result = (run-command-process $root $"api get (($base + '/protected-error') | to nuon) --auth ({type: oauth2, ref: bb-error} | to nuon) --output none")
        assert-blackbox-failure $result "OAuth provider error" "OAuth2 provider error: invalid_client" [$client_secret]
        assert ($result.stderr | str contains "HTTP 400") "OAuth error omitted its status"
        assert equal (open $server.count_file --raw | str trim | into int) ($count_before + 1)
        assert equal (command-error-wire-events $server | length) 0 "OAuth error reached the protected endpoint"
        assert equal (command-error-snapshot $root) $before "OAuth error mutated credentials or history"
        assert-blackbox-no-values (blackbox-history-bytes $root) [$client_secret] "OAuth error history"
    }
}

def test-blackbox-history-metadata-boundary [] {
    with-blackbox-server "metadata" {|root, server|
        blackbox-init $root
        let base = $"http://127.0.0.1:($server.port)"
        let request_secret = (blackbox-secret "REQUEST-METADATA")
        let response_secret = (blackbox-secret "RESPONSE-METADATA")
        let secrets = [$request_secret $response_secret]
        let request = {
            method: POST
            url: $"($base)/metadata"
            headers: {X-Keep: exact}
            body: {safe: request-body}
            access_token: $request_secret
            metadata: {credentials: {password: $request_secret}, nested: {api_key: $request_secret}}
        }
        let response = {
            status: 201
            status_text: Created
            headers: {X-Response: exact}
            body: {safe: response-body}
            time_ms: 2
            size_bytes: 12
            client_secret: $response_secret
            metadata: {credentials: {refresh_token: $response_secret}, nested: {key: $response_secret}}
        }
        let saved = (run-command-process $root $"api history save ($request | to nuon) ($response | to nuon)")
        assert-blackbox-success $saved "metadata history save" $secrets
        let id = ($saved.stdout | str trim)
        let read = (run-command-process $root $"api history get ($id | to nuon) | to nuon")
        assert-blackbox-success $read "metadata history read" $secrets
        let entry = ($read.stdout | from nuon)
        assert equal ($entry.request | columns) ["method" "url" "headers" "body"]
        assert equal ($entry.response | columns) ["status" "status_text" "headers" "body" "time_ms" "size_bytes"]
        assert equal $entry.request.method POST
        assert equal $entry.request.headers.X-Keep exact
        assert equal $entry.request.body.safe request-body
        assert equal $entry.response.status 201
        assert equal $entry.response.headers.X-Response exact
        assert equal $entry.response.body.safe response-body
        assert equal (command-error-wire-events $server | length) 0
        assert-blackbox-no-values (blackbox-history-bytes $root) $secrets "metadata history bytes"
    }
}

def test-blackbox-invalid-history-refs [] {
    with-blackbox-server "invalid-refs" {|root, server|
        blackbox-init $root
        let shape_secret = (blackbox-secret "MALFORMED-REF")
        let secrets_path = ($root | path join "secrets.nuon")
        let current = (open $secrets_path)
        ($current | update basic_auth ($current.basic_auth | upsert bb-wrong {username: $shape_secret}))
        | to nuon --indent 4
        | save -f $secrets_path
        let response = {status: 200, status_text: OK, headers: {}, body: null, time_ms: 1, size_bytes: 0}
        let cases = [
            {label: "missing named ref", auth: {type: bearer, ref: bb-missing}, expected: "bb-missing"}
            {label: "wrong-shaped named ref", auth: {type: basic, ref: bb-wrong}, expected: "Basic credentials 'bb-wrong' is malformed"}
        ]
        for case in $cases {
            let request = {method: GET, url: $"http://127.0.0.1:($server.port)/invalid-ref", headers: {}, body: null, auth: $case.auth}
            let before = (command-error-snapshot $root)
            let result = (run-command-process $root $"api history save ($request | to nuon) ($response | to nuon)")
            assert-blackbox-failure $result $case.label $case.expected [$shape_secret]
            assert equal (command-error-snapshot $root) $before $"($case.label) mutated state"
            assert equal (command-error-wire-events $server | length) 0
        }
        assert-blackbox-no-values (blackbox-history-bytes $root) [$shape_secret] "invalid ref history"
    }
}

def test-blackbox-invalid-oauth-responses [] {
    with-blackbox-server "oauth-shapes" {|root, server|
        blackbox-init $root
        let base = $"http://127.0.0.1:($server.port)"
        let non2xx_secret = (blackbox-secret "NON2XX-CLIENT")
        let malformed_secret = (blackbox-secret "MALFORMED-CLIENT")
        let refresh_secret = (blackbox-secret "REFRESH-CLIENT")
        let old_access = (blackbox-secret "OLD-ACCESS")
        let old_refresh = (blackbox-secret "OLD-REFRESH")
        let provider_values = [
            (["FAILED" "ACCESS" "SENTINEL"] | str join "-")
            (["FAILED" "REFRESH" "SENTINEL"] | str join "-")
            (["MALFORMED" "OAUTH" "SENTINEL"] | str join "-")
        ]
        let secrets = [$non2xx_secret $malformed_secret $refresh_secret $old_access $old_refresh] | append $provider_values
        let setup_command = ([
            $"api auth oauth2 configure bb-non2xx --client-id bb --client-secret ($non2xx_secret | to nuon) --token-url (($base + '/token-status-400') | to nuon) | ignore"
            $"api auth oauth2 configure bb-malformed --client-id bb --client-secret ($malformed_secret | to nuon) --token-url (($base + '/token-malformed-json') | to nuon) | ignore"
            $"api auth oauth2 configure bb-refresh --client-id bb --client-secret ($refresh_secret | to nuon) --token-url (($base + '/token-malformed-json') | to nuon) | ignore"
        ] | str join "\n")
        let setup = (run-command-process $root $setup_command)
        assert-blackbox-success $setup "invalid OAuth setup" $secrets --allow-ansi
        let secrets_path = ($root | path join "secrets.nuon")
        let current = (open $secrets_path)
        let refresh_config = (
            $current.oauth
            | get bb-refresh
            | upsert access_token $old_access
            | upsert refresh_token $old_refresh
            | upsert expires_at "2000-01-01T00:00:00Z"
        )
        ($current | update oauth ($current.oauth | upsert bb-refresh $refresh_config))
        | to nuon --indent 4
        | save -f $secrets_path

        let cases = [
            {label: "non-2xx success shape", ref: bb-non2xx, path: non2xx, code: unknown_error, status: 400}
            {label: "malformed 2xx obtain", ref: bb-malformed, path: malformed-obtain, code: invalid_response, status: 200}
            {label: "malformed 2xx refresh", ref: bb-refresh, path: malformed-refresh, code: invalid_response, status: 200}
        ]
        for case in $cases {
            let before = (command-error-snapshot $root)
            let count = (open $server.count_file --raw | str trim | into int)
            let result = (run-command-process $root $"api get (($base + '/' + $case.path) | to nuon) --auth ({type: oauth2, ref: $case.ref} | to nuon) --output none")
            assert-blackbox-failure $result $case.label $"OAuth2 provider error: ($case.code)" $secrets
            assert ($result.stderr | str contains $"HTTP ($case.status)") $"($case.label) omitted status"
            assert equal (open $server.count_file --raw | str trim | into int) ($count + 1)
            assert equal (command-error-wire-events $server | length) 0 $"($case.label) reached protected endpoint"
            assert equal (command-error-snapshot $root) $before $"($case.label) mutated credentials or history"
        }
        assert-blackbox-no-values (blackbox-history-bytes $root) $secrets "invalid OAuth history"
    }
}

def test-blackbox-literal-name-policy [] {
    with-blackbox-server "name-policy" {|root, server|
        blackbox-init $root
        let base = $"http://127.0.0.1:($server.port)"
        let url_secret = (blackbox-secret "URL-NAME")
        # Deliberately literal and independent of production classifier data.
        let unsafe_urls = [
            {name: password, normalized: PASSWORD}
            {name: access_token, normalized: ACCESS_TOKEN}
            {name: api_key, normalized: API_KEY}
        ]
        let safe_urls = [
            {name: password_hint, value: allowed-password}
            {name: tokenizer, value: allowed-token}
            {name: monkey, value: allowed-key}
        ]
        for case in $unsafe_urls {
            let before = (command-error-snapshot $root)
            let url = $"($base)/unsafe?($case.name)=($url_secret)"
            let result = (run-command-process $root $"api get ($url | to nuon) --output none")
            assert-blackbox-failure $result $"unsafe URL ($case.name)" $"Unsafe URL query parameter '($case.normalized)'" [$url_secret]
            assert equal (command-error-snapshot $root) $before $"unsafe URL ($case.name) mutated state"
            assert equal (command-error-wire-events $server | length) 0
        }
        for case in $safe_urls {
            let before = (command-error-snapshot $root)
            let url = $"($base)/safe?($case.name)=($case.value)"
            let result = (run-command-process $root $"api get ($url | to nuon) --dry-run")
            assert-blackbox-success $result $"safe URL ($case.name)" [$url_secret]
            assert ($result.stdout | str contains $"($case.name)=($case.value)") $"safe URL ($case.name) was overmatched"
            assert equal (command-error-snapshot $root) $before
        }

        let unsafe_headers = [
            {name: Password, value: (blackbox-secret "HEADER-PASSWORD")}
            {name: X-Access-Token, value: (blackbox-secret "HEADER-TOKEN")}
            {name: X-Api-Key, value: (blackbox-secret "HEADER-KEY")}
        ]
        let safe_headers = [
            {name: Password-Hint, value: allowed-password}
            {name: X-Tokenizer-Count, value: allowed-token}
            {name: Monkey, value: allowed-key}
        ]
        mut headers = {}
        for case in ($unsafe_headers | append $safe_headers) {
            $headers = ($headers | upsert $case.name $case.value)
        }
        let header_secrets = ($unsafe_headers | get value)
        let before_headers = (command-error-snapshot $root)
        let preview = (run-command-process $root $"api get (($base + '/headers') | to nuon) --headers ($headers | to nuon) --dry-run")
        assert-blackbox-preview $preview "literal header policy" ($header_secrets | append $url_secret) []
        for case in $unsafe_headers {
            assert ($preview.stdout | str contains $"($case.name): ******") $"header ($case.name) was not masked"
        }
        for case in $safe_headers {
            assert ($preview.stdout | str contains $"($case.name): ($case.value)") $"safe header ($case.name) was overmatched"
        }
        assert equal (command-error-snapshot $root) $before_headers "header preview mutated state"
        assert equal (command-error-wire-events $server | length) 0
        assert-blackbox-no-values (blackbox-history-bytes $root) ($header_secrets | append $url_secret) "name-policy history"
    }
}

export def run-suite-credential-blackbox []: nothing -> list<record> {
    print "\n=== Credential Black-box Safety Tests ==="
    [
        (run-test "black-box previews, execution, and replay mask named basic and API-key rotation" { test-blackbox-masking-and-rotation })
        (run-test "black-box direct history save sanitizes inline auth and sensitive headers" { test-blackbox-direct-save-sanitizes })
        (run-test "black-box query API-key components are encoded exactly once" { test-blackbox-query-encoding })
        (run-test "black-box OAuth provider descriptions never escape the error stream" { test-blackbox-oauth-error-description })
        (run-test "black-box direct history boundary drops credential-shaped metadata" { test-blackbox-history-metadata-boundary })
        (run-test "black-box direct history save rejects missing and malformed refs atomically" { test-blackbox-invalid-history-refs })
        (run-test "black-box invalid OAuth obtain and refresh responses fail atomically" { test-blackbox-invalid-oauth-responses })
        (run-test "black-box literal URL and header name policy has exact boundaries" { test-blackbox-literal-name-policy })
    ]
}
