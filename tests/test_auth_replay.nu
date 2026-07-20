# Authentication preview, history replay, and credential-safety regressions.

def auth-history-ids [] {
    let index_path = (($env.API_ROOT? | default (pwd)) | path join "history" "index.nuon")
    if ($index_path | path exists) {
        try { open $index_path | get id } catch { [] }
    } else {
        []
    }
}

def auth-new-history [before_ids: list] {
    let new_ids = (auth-history-ids | where {|id| $id not-in $before_ids })
    assert equal ($new_ids | length) 1 "request did not create exactly one history entry"
    api history get ($new_ids | first)
}

def auth-history-count [] {
    auth-history-ids | length
}

def assert-history-auth [
    entry: record
    expected_type: string
    expected_ref: string
    secrets: list<string>
] {
    assert equal $entry.request.auth.type $expected_type "history auth type was not canonical"
    assert equal $entry.request.auth.ref $expected_ref "history auth ref was not canonical"
    assert equal $entry.request.auth.replayable true "named auth must remain replayable"
    let serialized = ($entry | to nuon)
    for secret in $secrets {
        assert (not ($serialized | str contains $secret)) "history persisted a resolved credential"
    }
}

def assert-safe-preview [
    result: record
    label: string
    secrets: list<string>
    expected: list<string> = []
] {
    assert equal $result.exit_code 0 $"($label) failed: ($result.stderr)"
    assert equal ($result.stderr | str trim) "" $"($label) wrote stderr"
    assert equal $result.stdout ($result.stdout | ansi strip) $"($label) emitted ANSI"
    let lines = ($result.stdout | lines | where {|line| not ($line | is-empty) })
    assert equal ($lines | length) 1 $"($label) must emit exactly one curl line"
    assert (($lines | first) | str starts-with "curl ") $"($label) did not emit a copyable curl command"
    assert ($result.stdout | str contains "******") $"($label) omitted masking"
    for secret in $secrets {
        assert (not ($result.stdout | str contains $secret)) $"($label) exposed a credential"
    }
    for text in $expected {
        assert ($result.stdout | str contains $text) $"($label) omitted expected safe structure: ($text)"
    }
}

def auth-test-server [infra: string] {
    let server_result = try {
        {server: (start-command-error-server $infra), error: null}
    } catch {|error|
        {server: null, error: $error}
    }
    if $server_result.error != null {
        error make {msg: $server_result.error.msg}
    }
    $server_result.server
}

def test-named-auth-history-replay-and-rotation [] {
    let root = (make-temp-dir "auth-replay-named")
    let infra = (make-temp-dir "auth-replay-named-server")
    let server = (auth-test-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let base = $"http://127.0.0.1:($server.port)"
        let bearer_a = "NAMED-BEARER-A-SENTINEL"
        let bearer_b = "NAMED-BEARER-B-SENTINEL"
        let bearer_override = "NAMED-BEARER-OVERRIDE-SENTINEL"
        let basic_a = "NAMED-BASIC-A-SENTINEL"
        let basic_b = "NAMED-BASIC-B-SENTINEL"
        let header_a = "NAMED-HEADER-A-SENTINEL"
        let header_b = "NAMED-HEADER-B-SENTINEL"
        let query_a = "NAMED-QUERY-A-SENTINEL"
        let query_b = "NAMED-QUERY-B-SENTINEL"
        let oauth_a = "ACCESS-TOKEN-SENTINEL"
        let oauth_b = "NAMED-OAUTH-B-SENTINEL"
        let all_secrets = [
            $bearer_a $bearer_b $bearer_override $basic_a $basic_b
            $header_a $header_b $query_a $query_b $oauth_a $oauth_b
            "CLIENT-SECRET-REPLAY-SENTINEL" "EXPLICIT-HISTORY-HEADER-SENTINEL"
        ]

        api auth bearer set replay-bearer $"Bearer ($bearer_a)" | ignore
        api auth bearer set replay-override $bearer_override | ignore
        api auth basic set replay-basic replay-user $basic_a | ignore
        api auth apikey set replay-header $header_a --header "X.Nurl+Key" | ignore
        api auth apikey set replay-query $query_a --query "api.key+odd" | ignore
        api auth oauth2 configure replay-oauth --client-id replay-client --client-secret "CLIENT-SECRET-REPLAY-SENTINEL" --token-url $"($base)/token" | ignore
        api collection create replay | ignore
        api request create send-override GET $"($base)/send-override" --collection replay --auth {type: bearer, ref: replay-bearer} | ignore

        let before_bearer = (auth-history-ids)
        let bearer_result = (api get $"($base)/replay-bearer" -a {type: bearer, token_ref: replay-bearer} --raw)
        assert equal $bearer_result.response.status 200
        assert equal ($bearer_result | columns) ["request" "response" "timestamp"] "authenticated raw result shape changed"
        assert ("auth" not-in ($bearer_result.request | columns)) "safe history auth leaked into the public request record"
        for secret in $all_secrets {
            assert (not (($bearer_result | to nuon) | str contains $secret)) "public result exposed a managed credential"
        }
        let bearer_history = (auth-new-history $before_bearer)
        assert-history-auth $bearer_history "bearer" "replay-bearer" $all_secrets
        assert equal (command-error-wire-events $server | where path == "/replay-bearer" | first | get authorization) $"Bearer ($bearer_a)" "prefixed bearer was changed or double-prefixed"

        let before_send_override = (auth-history-ids)
        api send send-override --collection replay --auth {type: bearer, ref: replay-override} --raw | ignore
        assert equal (command-error-wire-events $server | where path == "/send-override" | first | get authorization) $"Bearer ($bearer_override)" "saved-request auth override did not win"
        assert-history-auth (auth-new-history $before_send_override) "bearer" "replay-override" $all_secrets

        api auth bearer set replay-bearer $bearer_b | ignore
        let before_bearer_replay = (auth-history-ids)
        api history resend $bearer_history.id --raw | ignore
        let bearer_events = (command-error-wire-events $server | where path == "/replay-bearer")
        assert equal ($bearer_events | length) 2
        assert equal ($bearer_events | last | get authorization) $"Bearer ($bearer_b)" "bearer rotation was not resolved during resend"
        assert-history-auth (auth-new-history $before_bearer_replay) "bearer" "replay-bearer" $all_secrets

        let before_override = (auth-history-ids)
        api history resend $bearer_history.id --auth {type: bearer, ref: replay-override} --raw | ignore
        let override_event = (command-error-wire-events $server | where path == "/replay-bearer" | last)
        assert equal $override_event.authorization $"Bearer ($bearer_override)" "explicit resend auth did not override stored auth"
        assert-history-auth (auth-new-history $before_override) "bearer" "replay-override" $all_secrets

        let before_basic = (auth-history-ids)
        api get $"($base)/replay-basic" -a {type: basic, creds_ref: replay-basic} --raw | ignore
        let basic_history = (auth-new-history $before_basic)
        assert-history-auth $basic_history "basic" "replay-basic" $all_secrets
        let basic_first = (command-error-wire-events $server | where path == "/replay-basic" | first | get authorization)
        assert ($basic_first | str starts-with "Basic ") "basic auth was not sent"
        api auth basic set replay-basic replay-user $basic_b | ignore
        let before_basic_replay = (auth-history-ids)
        api history resend $basic_history.id --raw | ignore
        let basic_last = (command-error-wire-events $server | where path == "/replay-basic" | last | get authorization)
        assert ($basic_last | str starts-with "Basic ")
        assert ($basic_last != $basic_first) "basic credential rotation was not resolved during resend"
        assert-history-auth (auth-new-history $before_basic_replay) "basic" "replay-basic" $all_secrets

        let before_header = (auth-history-ids)
        api get $"($base)/replay-header" -a {type: api_key, key_ref: replay-header} --raw | ignore
        let header_history = (auth-new-history $before_header)
        assert-history-auth $header_history "api_key" "replay-header" $all_secrets
        assert equal (command-error-wire-events $server | where path == "/replay-header" | first | get api_key) $header_a
        api auth apikey set replay-header $header_b --header "X.Nurl+Key" | ignore
        let before_header_replay = (auth-history-ids)
        api history resend $header_history.id --raw | ignore
        assert equal (command-error-wire-events $server | where path == "/replay-header" | last | get api_key) $header_b "header API-key rotation was not resolved during resend"
        assert-history-auth (auth-new-history $before_header_replay) "api_key" "replay-header" $all_secrets

        let before_query = (auth-history-ids)
        api get $"($base)/replay-query?existing=1#client-fragment" -a {type: api_key, ref: replay-query} --raw | ignore
        let query_history = (auth-new-history $before_query)
        assert-history-auth $query_history "api_key" "replay-query" $all_secrets
        let query_first = (command-error-wire-events $server | where path =~ "^/replay-query" | first | get path)
        assert equal $query_first $"/replay-query?existing=1&api.key+odd=($query_a)" "query API key was not placed before the fragment"
        api auth apikey set replay-query $query_b --query "api.key+odd" | ignore
        let before_query_replay = (auth-history-ids)
        api history resend $query_history.id --raw | ignore
        let query_last = (command-error-wire-events $server | where path =~ "^/replay-query" | last | get path)
        assert equal $query_last $"/replay-query?existing=1&api.key+odd=($query_b)" "query API-key rotation was not resolved during resend"
        assert-history-auth (auth-new-history $before_query_replay) "api_key" "replay-query" $all_secrets

        let before_oauth = (auth-history-ids)
        api get $"($base)/replay-oauth" -a {type: oauth2, ref: replay-oauth} --raw | ignore
        let oauth_history = (auth-new-history $before_oauth)
        assert-history-auth $oauth_history "oauth2" "replay-oauth" $all_secrets
        assert equal (open $server.count_file --raw | str trim) "1" "OAuth execution did not use the local token endpoint"
        assert equal (command-error-wire-events $server | where path == "/replay-oauth" | first | get authorization) $"Bearer ($oauth_a)"
        let secrets_path = ($root | path join "secrets.nuon")
        let rotated = (
            open $secrets_path
            | update oauth.replay-oauth.access_token $oauth_b
            | update oauth.replay-oauth.expires_at ((date now) + 1day | format date "%Y-%m-%dT%H:%M:%SZ")
        )
        $rotated | to nuon --indent 4 | save -f $secrets_path
        let before_oauth_replay = (auth-history-ids)
        api history resend $oauth_history.id --raw | ignore
        assert equal (command-error-wire-events $server | where path == "/replay-oauth" | last | get authorization) $"Bearer ($oauth_b)" "OAuth credential rotation was not resolved during resend"
        assert equal (open $server.count_file --raw | str trim) "1" "valid rotated OAuth token should not be reacquired"
        assert-history-auth (auth-new-history $before_oauth_replay) "oauth2" "replay-oauth" $all_secrets

        let before_sensitive_header = (auth-history-ids)
        api get $"($base)/explicit-sensitive-history" -H {
            Authorization: "Bearer EXPLICIT-HISTORY-HEADER-SENTINEL"
            X-Keep: exact
        } --raw | ignore
        let sensitive_entry = (auth-new-history $before_sensitive_header)
        assert equal $sensitive_entry.request.headers.Authorization "******" "sensitive request header was persisted"
        assert equal $sensitive_entry.request.headers.X-Keep "exact" "non-sensitive request header changed"
        assert equal $sensitive_entry.request.headers_replayable false "redacted request headers were marked replayable"
        let wire_before_sensitive_replay = (command-error-wire-events $server | length)
        let history_before_sensitive_replay = (auth-history-count)
        let rejected_sensitive = (run-command-process $root $"api history resend ($sensitive_entry.id | to nuon) --raw")
        assert ($rejected_sensitive.exit_code != 0) "redacted sensitive headers were replayed as masks"
        assert equal ($rejected_sensitive.stdout | str trim) ""
        assert ($rejected_sensitive.stderr | str contains "pass --headers")
        assert equal $rejected_sensitive.stderr ($rejected_sensitive.stderr | ansi strip)
        assert equal (command-error-wire-events $server | length) $wire_before_sensitive_replay
        assert equal (auth-history-count) $history_before_sensitive_replay
        api history resend $sensitive_entry.id --headers {} --raw | ignore
        assert equal (command-error-wire-events $server | length) ($wire_before_sensitive_replay + 1)

        let public_state = (
            command-error-snapshot $root
            | where {|entry| not ($entry.path | str ends-with "secrets.nuon") }
            | to nuon
        )
        for secret in $all_secrets {
            assert (not ($public_state | str contains $secret)) "history/index persisted a named credential"
        }
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def test-inline-auth-is-nonreplayable [] {
    let root = (make-temp-dir "auth-replay-inline")
    let infra = (make-temp-dir "auth-replay-inline-server")
    let server = (auth-test-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let base = $"http://127.0.0.1:($server.port)"
        let override_secret = "INLINE-OVERRIDE-SENTINEL"
        api auth bearer set inline-override $override_secret | ignore
        let cases = [
            {
                name: "bearer"
                path: "/inline-bearer"
                secret: "INLINE-BEARER-SENTINEL"
                auth: {type: bearer, token: "INLINE-BEARER-SENTINEL"}
            }
            {
                name: "basic"
                path: "/inline-basic"
                secret: "INLINE-BASIC-SENTINEL"
                auth: {type: basic, username: inline-user, password: "INLINE-BASIC-SENTINEL"}
            }
            {
                name: "api-header"
                path: "/inline-api-header"
                secret: "INLINE-API-HEADER-SENTINEL"
                auth: {type: api_key, key: "INLINE-API-HEADER-SENTINEL", header: "X.Nurl+Key"}
            }
            {
                name: "api-query"
                path: "/inline-api-query?existing=1"
                secret: "INLINE-API-QUERY-SENTINEL"
                auth: {type: api_key, key: "INLINE-API-QUERY-SENTINEL", query: "inline.key"}
            }
        ]

        for case in $cases {
            let before_inline = (auth-history-ids)
            api get $"($base)($case.path)" --auth $case.auth --raw | ignore
            let entry = (auth-new-history $before_inline)
            assert equal $entry.request.auth.replayable false $"inline ($case.name) history was marked replayable"
            assert equal $entry.request.auth.type (if ($case.name | str starts-with "api-") { "api_key" } else { $case.name })
            assert (not (($entry | to nuon) | str contains $case.secret)) $"inline ($case.name) leaked into history"

            let wire_before = (command-error-wire-events $server | length)
            let history_before = (auth-history-count)
            let rejected = (run-command-process $root $"api history resend ($entry.id | to nuon) --raw")
            assert ($rejected.exit_code != 0) $"inline ($case.name) history resent without an override"
            assert equal ($rejected.stdout | str trim) "" $"inline ($case.name) replay failure wrote stdout"
            assert ($rejected.stderr | str contains "pass --auth") $"inline ($case.name) replay failure was not actionable"
            assert equal $rejected.stderr ($rejected.stderr | ansi strip) $"inline ($case.name) replay failure emitted ANSI"
            assert (not ($rejected.stderr | str contains $case.secret)) $"inline ($case.name) replay failure leaked a credential"
            assert equal (command-error-wire-events $server | length) $wire_before $"inline ($case.name) replay failure reached the network"
            assert equal (auth-history-count) $history_before $"inline ($case.name) replay failure created history"

            let before_override = (auth-history-ids)
            api history resend $entry.id --auth {type: bearer, token_ref: inline-override} --raw | ignore
            assert equal (command-error-wire-events $server | length) ($wire_before + 1) $"inline ($case.name) explicit override did not execute"
            assert-history-auth (auth-new-history $before_override) "bearer" "inline-override" [$override_secret $case.secret]
        }

        let public_state = (
            command-error-snapshot $root
            | where {|entry| not ($entry.path | str ends-with "secrets.nuon") }
            | to nuon
        )
        for secret in ($cases | get secret | append $override_secret) {
            assert (not ($public_state | str contains $secret)) "inline authentication leaked to history or index"
        }
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def test-legacy-and-invalid-auth-history [] {
    let root = (make-temp-dir "auth-replay-invalid")
    let infra = (make-temp-dir "auth-replay-invalid-server")
    let server = (auth-test-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let base = $"http://127.0.0.1:($server.port)"

        let legacy_id = (api history save {
            method: GET
            url: $"($base)/legacy-no-auth"
            headers: {}
            body: null
        } {
            status: 200
            status_text: OK
            headers: {}
            body: null
            time_ms: 1
            size_bytes: 0
        })
        api history resend $legacy_id --raw | ignore
        assert equal (command-error-wire-events $server | where path == "/legacy-no-auth" | length) 1 "legacy no-auth history no longer resends"
        assert (((api history get $legacy_id).request.auth? | default null) == null) "legacy entry was migrated unexpectedly"

        api auth bearer set deleted-bearer deleted | ignore
        api auth basic set deleted-basic user deleted | ignore
        api auth apikey set deleted-api deleted | ignore
        api auth oauth2 configure deleted-oauth --client-id id --client-secret deleted --token-url $"($base)/token" | ignore
        api auth bearer delete deleted-bearer | ignore
        api auth basic delete deleted-basic | ignore
        api auth apikey delete deleted-api | ignore
        api auth oauth2 delete deleted-oauth | ignore

        let secrets_path = ($root | path join "secrets.nuon")
        let malformed = (
            open $secrets_path
            | update tokens ($in.tokens | upsert malformed-bearer {})
            | update basic_auth ($in.basic_auth | upsert malformed-basic {username: user})
            | update api_keys ($in.api_keys | upsert malformed-api {key: value, type: query})
            | update oauth ($in.oauth | upsert malformed-oauth {client_id: id, token_url: $"($base)/token"})
        )
        $malformed | to nuon --indent 4 | save -f $secrets_path

        let output_path = ($root | path join "must-not-write.bin")
        let cases = [
            {command: $"api get (($base + '/missing-bearer') | to nuon) -a {type: bearer, ref: missing-bearer} --binary-save ($output_path | to nuon) --output none", expected: "Bearer token 'missing-bearer' not found"}
            {command: $"api get (($base + '/missing-basic') | to nuon) -a {type: basic, ref: missing-basic} --output none", expected: "Basic credentials 'missing-basic' not found"}
            {command: $"api get (($base + '/missing-api') | to nuon) -a {type: api_key, ref: missing-api} --output none", expected: "API key 'missing-api' not found"}
            {command: $"api get (($base + '/missing-oauth') | to nuon) -a {type: oauth2, ref: missing-oauth} --output none", expected: "OAuth2 'missing-oauth' not found"}
            {command: $"api get (($base + '/deleted-bearer') | to nuon) -a {type: bearer, token_ref: deleted-bearer} --output none", expected: "Bearer token 'deleted-bearer' not found"}
            {command: $"api get (($base + '/deleted-basic') | to nuon) -a {type: basic, creds_ref: deleted-basic} --output none", expected: "Basic credentials 'deleted-basic' not found"}
            {command: $"api get (($base + '/deleted-api') | to nuon) -a {type: api_key, key_ref: deleted-api} --output none", expected: "API key 'deleted-api' not found"}
            {command: $"api get (($base + '/deleted-oauth') | to nuon) -a {type: oauth2, ref: deleted-oauth} --output none", expected: "OAuth2 'deleted-oauth' not found"}
            {command: $"api get (($base + '/malformed-bearer') | to nuon) -a {type: bearer, ref: malformed-bearer} --output none", expected: "Bearer token 'malformed-bearer' is malformed"}
            {command: $"api get (($base + '/malformed-basic') | to nuon) -a {type: basic, ref: malformed-basic} --output none", expected: "Basic credentials 'malformed-basic' is malformed"}
            {command: $"api get (($base + '/malformed-api') | to nuon) -a {type: api_key, ref: malformed-api} --output none", expected: "API key 'malformed-api' is malformed"}
            {command: $"api get (($base + '/malformed-oauth') | to nuon) -a {type: oauth2, ref: malformed-oauth} --output none", expected: "OAuth2 'malformed-oauth' is malformed"}
            {command: $"api get (($base + '/empty-ref') | to nuon) -a {type: bearer, token_ref: ''} --output none", expected: "Bearer token reference must be a non-empty string"}
            {command: $"api get (($base + '/unknown') | to nuon) -a {type: custom_auth, value: sentinel} --output none", expected: "Unsupported authentication type 'custom_auth'"}
        ]
        let wire_before = (command-error-wire-events $server | length)
        let token_before = (open $server.count_file --raw | str trim)
        for case in $cases {
            let before = (command-error-snapshot $root)
            let result = (run-command-process $root $case.command)
            assert ($result.exit_code != 0) $"invalid auth unexpectedly executed: ($case.command)"
            assert equal ($result.stdout | str trim) "" $"invalid auth wrote stdout: ($case.command)"
            assert ($result.stderr | str contains $case.expected) $"invalid auth error was not specific: ($case.command): ($result.stderr)"
            assert equal $result.stderr ($result.stderr | ansi strip) $"invalid auth error emitted ANSI: ($case.command)"
            assert equal (command-error-snapshot $root) $before $"invalid auth mutated state: ($case.command)"
        }
        assert equal (command-error-wire-events $server | length) $wire_before "invalid auth reached the protected endpoint"
        assert equal (open $server.count_file --raw | str trim) $token_before "invalid auth reached the OAuth token endpoint"
        assert (not ($output_path | path exists)) "invalid auth mutated an output file"
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def test-auth-preview-and-export-secrecy [] {
    let root = (make-temp-dir "auth-preview")
    let infra = (make-temp-dir "auth-preview-server")
    let server = (auth-test-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let base = $"http://127.0.0.1:($server.port)"
        let secrets = [
            "PREVIEW-BEARER-SENTINEL"
            "PREVIEW-BASIC-SENTINEL"
            "PREVIEW-HEADER-SENTINEL"
            "PREVIEW-QUERY-SENTINEL"
            "PREVIEW-OAUTH-CLIENT-SENTINEL"
            "EXPLICIT-AUTH-SENTINEL"
            "EXPLICIT-PROXY-SENTINEL"
            "EXPLICIT-COOKIE-SENTINEL"
            "EXPLICIT-SET-COOKIE-SENTINEL"
            "EXPLICIT-TOKEN-SENTINEL"
        ]

        api auth bearer set "preview ref.+odd" "Bearer PREVIEW-BEARER-SENTINEL" | ignore
        api auth basic set preview-basic preview-user "PREVIEW-BASIC-SENTINEL" | ignore
        api auth apikey set preview-header "PREVIEW-HEADER-SENTINEL" --header "X.Nurl+Key" | ignore
        api auth apikey set preview-query "PREVIEW-QUERY-SENTINEL" --query "api.key+odd" | ignore
        api auth oauth2 configure preview-oauth --client-id preview-client --client-secret "PREVIEW-OAUTH-CLIENT-SENTINEL" --token-url $"($base)/token" | ignore
        api collection create preview | ignore
        api request create bearer GET $"($base)/saved-bearer" --collection preview --auth {type: bearer, ref: "preview ref.+odd"} | ignore
        api request create basic GET $"($base)/saved-basic" --collection preview --auth {type: basic, ref: preview-basic} | ignore
        api request create header GET $"($base)/saved-header" --collection preview --auth {type: api_key, ref: preview-header} | ignore
        api request create query GET $"($base)/saved-query?existing=1#frag" --collection preview --auth {type: api_key, ref: preview-query} | ignore
        api request create oauth GET $"($base)/saved-oauth" --collection preview --auth {type: oauth2, ref: preview-oauth} | ignore

        let replay_ids = [
            {name: bearer, id: (api history save {method: GET, url: $"($base)/history-bearer", headers: {}, body: null, auth: {type: bearer, ref: "preview ref.+odd", replayable: true}} {status: 200, status_text: OK, headers: {}, body: null, time_ms: 1, size_bytes: 0})}
            {name: basic, id: (api history save {method: GET, url: $"($base)/history-basic", headers: {}, body: null, auth: {type: basic, ref: preview-basic, replayable: true}} {status: 200, status_text: OK, headers: {}, body: null, time_ms: 1, size_bytes: 0})}
            {name: header, id: (api history save {method: GET, url: $"($base)/history-header", headers: {}, body: null, auth: {type: api_key, ref: preview-header, replayable: true}} {status: 200, status_text: OK, headers: {}, body: null, time_ms: 1, size_bytes: 0})}
            {name: query, id: (api history save {method: GET, url: $"($base)/history-query?existing=1#frag", headers: {}, body: null, auth: {type: api_key, ref: preview-query, replayable: true}} {status: 200, status_text: OK, headers: {}, body: null, time_ms: 1, size_bytes: 0})}
            {name: oauth, id: (api history save {method: GET, url: $"($base)/history-oauth", headers: {}, body: null, auth: {type: oauth2, ref: preview-oauth, replayable: true}} {status: 200, status_text: OK, headers: {}, body: null, time_ms: 1, size_bytes: 0})}
        ]
        let text_output = ($root | path join "dry-run-must-not-save.txt")
        let binary_output = ($root | path join "dry-run-must-not-save.bin")

        let commands = [
            {label: "generic bearer", command: $"api request -m GET (($base + '/direct-bearer') | to nuon) -a {type: bearer, token_ref: 'preview ref.+odd'} --save ($text_output | to nuon) --binary-save ($binary_output | to nuon) --dry-run", expected: ["Authorization: ******"]}
            {label: "get basic", command: $"api get (($base + '/direct-basic') | to nuon) -a {type: basic, creds_ref: preview-basic} --dry-run", expected: ["-u ******:******"]}
            {label: "post API-key header", command: $"api post (($base + '/direct-header') | to nuon) -b {ok: true} -a {type: api_key, key_ref: preview-header} --dry-run", expected: ["X.Nurl+Key: ******"]}
            {label: "put API-key query", command: $"api put (($base + '/direct-query?existing=1#frag') | to nuon) -b {ok: true} -a {type: api_key, ref: preview-query} --dry-run", expected: ["existing=1&api.key+odd=******#frag"]}
            {label: "patch OAuth", command: $"api patch (($base + '/direct-oauth') | to nuon) -b {ok: true} -a {type: oauth2, ref: preview-oauth} --dry-run", expected: ["Authorization: ******"]}
            {label: "delete inline bearer", command: $"api delete (($base + '/inline-bearer') | to nuon) -a {type: bearer, token: 'PREVIEW-BEARER-SENTINEL'} --dry-run", expected: ["Authorization: ******"]}
            {label: "head inline basic", command: $"api head (($base + '/inline-basic') | to nuon) -a {type: basic, username: user, password: 'PREVIEW-BASIC-SENTINEL'} --dry-run", expected: ["-u ******:******"]}
            {label: "options inline query", command: $"api options (($base + '/empty?#frag') | to nuon) -a {type: api_key, key: 'PREVIEW-QUERY-SENTINEL', query: 'api.key+odd'} --dry-run", expected: ["empty?api.key+odd=******#frag"]}
            {
                label: "sensitive explicit headers"
                command: $"api get (($base + '/sensitive-headers') | to nuon) -H {Authorization: 'EXPLICIT-AUTH-SENTINEL', Proxy-Authorization: 'EXPLICIT-PROXY-SENTINEL', Cookie: 'EXPLICIT-COOKIE-SENTINEL', Set-Cookie: 'EXPLICIT-SET-COOKIE-SENTINEL', X-Auth-Token: 'EXPLICIT-TOKEN-SENTINEL', X-Keep: exact} --dry-run"
                expected: ["Authorization: ******" "Proxy-Authorization: ******" "Cookie: ******" "Set-Cookie: ******" "X-Auth-Token: ******" "X-Keep: exact"]
            }
        ]
        let saved_commands = ["bearer" "basic" "header" "query" "oauth"] | each {|name|
            [
                {label: $"send ($name)", command: $"api send ($name) --collection preview --dry-run", expected: ["******"]}
                {label: $"export ($name)", command: $"api request export ($name) --collection preview", expected: ["******"]}
            ]
        } | flatten
        let history_commands = $replay_ids | each {|item|
            {label: $"history resend ($item.name)", command: $"api history resend ($item.id | to nuon) --dry-run", expected: ["******"]}
        }
        let all_commands = $commands | append $saved_commands | append $history_commands
        let before = (command-error-snapshot $root)
        for case in $all_commands {
            assert-safe-preview (run-command-process $root $case.command) $case.label $secrets $case.expected
        }
        assert equal (command-error-snapshot $root) $before "dry-run/export mutated config, secrets, saved requests, history, or output state"
        assert (not ($text_output | path exists)) "dry-run created a text output file"
        assert (not ($binary_output | path exists)) "dry-run created a binary output file"
        assert equal (open $server.count_file --raw | str trim) "0" "dry-run/export acquired or refreshed an OAuth token"
        assert equal (command-error-wire-events $server | length) 0 "dry-run/export reached the protected endpoint"
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def test-authenticated-output-contracts [] {
    let root = (make-temp-dir "auth-output-contracts")
    let infra = (make-temp-dir "auth-output-contracts-server")
    let server = (auth-test-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let base = $"http://127.0.0.1:($server.port)"
        let secret = "OUTPUT-AUTH-SENTINEL"
        api auth bearer set output-auth $secret | ignore
        let auth = {type: bearer, ref: output-auth}

        let raw_result = (api get $"($base)/output-raw-result" --auth $auth --raw --no-history)
        assert equal ($raw_result | columns) ["request" "response" "timestamp"]
        assert equal $raw_result.response.status 200
        assert equal $raw_result.response.body.ok true
        assert (not (($raw_result | to nuon) | str contains $secret)) "--raw exposed authentication"

        let body = (api get $"($base)/output-body" --auth $auth --output body --no-history)
        assert equal ($body | describe) "record<ok: bool>"
        assert equal $body.ok true

        let raw_body = (api get $"($base)/output-raw" --auth $auth --output raw --no-history)
        assert equal ($raw_body | describe) "string"
        assert equal ($raw_body | from json | get ok) true

        let json = (api get $"($base)/output-json" --auth $auth --output json --no-history)
        assert equal ($json | describe) "string"
        let parsed_json = ($json | from json)
        assert equal $parsed_json.response.status 200
        assert (not ($json | str contains $secret)) "--output json exposed authentication"

        let headers = (api get $"($base)/output-headers" --auth $auth --output headers --no-history)
        assert (($headers | describe) | str starts-with "record")
        assert equal ($headers | get "Content-Type") "application/json"

        let status = (api get $"($base)/output-status" --auth $auth --output status --no-history)
        assert equal ($status | describe) "int"
        assert equal $status 200

        let selected = (api get $"($base)/output-select" --auth $auth --select response.status --no-history)
        assert equal ($selected | describe) "int"
        assert equal $selected 200

        let none = (api get $"($base)/output-none" --auth $auth --output none --no-history)
        assert equal $none null "--output none returned data"

        for case in [
            {label: "default", options: ""}
            {label: "verbose", options: "--verbose"}
        ] {
            let result = (run-command-process $root $"api get (($base + '/output-' + $case.label) | to nuon) -a {type: bearer, ref: output-auth} --no-history ($case.options)")
            assert equal $result.exit_code 0 $"authenticated ($case.label) output failed"
            assert equal ($result.stderr | str trim) "" $"authenticated ($case.label) output wrote stderr"
            assert (not ($result.stdout | str contains $secret)) $"authenticated ($case.label) output exposed authentication"
            assert ($result.stdout | str contains "200") $"authenticated ($case.label) output omitted status"
        }

        assert equal (auth-history-count) 0 "authenticated output-mode checks unexpectedly created history"
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

export def run-suite-auth-replay [] {
    print "\n=== Authentication Replay and Preview Safety Tests ==="
    [
        (run-test "named auth refs replay with rotation and override precedence" { test-named-auth-history-replay-and-rotation })
        (run-test "inline auth history requires an explicit replay override" { test-inline-auth-is-nonreplayable })
        (run-test "legacy history replays while missing, deleted, malformed, and unknown auth fail safely" { test-legacy-and-invalid-auth-history })
        (run-test "dry-run, send, export, and history previews mask all supported auth" { test-auth-preview-and-export-secrecy })
        (run-test "authenticated output modes preserve types and never expose auth" { test-authenticated-output-contracts })
    ]
}
