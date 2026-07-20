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

def assert-query-auth-event [
    event: record
    expected_path: string
    expected_name: string
    expected_value: string
] {
    assert (not ($event.path | str contains "#")) "URL fragment was transmitted to the server"
    let path_parts = ($event.path | split row "?")
    assert equal ($path_parts | first) $expected_path
    assert equal ($path_parts | length) 2 "request path did not contain exactly one query"
    let parameters = ($path_parts | last | split row "&")
    assert equal ($parameters | length) 2 "API-key query data was split into extra parameters"
    assert equal ($parameters | first) "existing=1"
    let auth_parts = ($parameters | last | split row "=")
    assert equal ($auth_parts | length) 2 "API-key query value was split at an unencoded equals sign"
    assert equal (($auth_parts | first) | url decode) $expected_name
    assert equal (($auth_parts | last) | url decode) $expected_value
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
        let query_name = "api&key=#%+ space世界~._-"
        let query_a = "NAMED-QUERY-A-SENTINEL&injected=1#cut%=+ 世界~._-"
        let query_b = "NAMED-QUERY-B-SENTINEL&rotated=2#cut%=+ 世界~._-"
        let query_override = "NAMED-QUERY-OVERRIDE-SENTINEL&override=3#cut%=+ 世界~._-"
        let oauth_a = "ACCESS-TOKEN-SENTINEL"
        let oauth_b = "NAMED-OAUTH-B-SENTINEL"
        let all_secrets = [
            $bearer_a $bearer_b $bearer_override $basic_a $basic_b
            $header_a $header_b $query_a $query_b $query_override $oauth_a $oauth_b
            "CLIENT-SECRET-REPLAY-SENTINEL" "EXPLICIT-HISTORY-HEADER-SENTINEL"
        ]

        api auth bearer set replay-bearer $"Bearer ($bearer_a)" | ignore
        api auth bearer set replay-override $bearer_override | ignore
        api auth basic set replay-basic replay-user $basic_a | ignore
        api auth apikey set replay-header $header_a --header "X.Nurl+Key" | ignore
        api auth apikey set replay-query $query_a --query $query_name | ignore
        api auth apikey set replay-query-override $query_override --query $query_name | ignore
        api auth oauth2 configure replay-oauth --client-id replay-client --client-secret "CLIENT-SECRET-REPLAY-SENTINEL" --token-url $"($base)/token" | ignore
        api collection create replay | ignore
        api request create send-override GET $"($base)/send-override" --collection replay --auth {type: bearer, ref: replay-bearer} | ignore
        api request create query-saved GET $"($base)/replay-query-saved?existing=1#client-fragment" --collection replay --auth {type: api_key, ref: replay-query} | ignore

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
        let query_first = (command-error-wire-events $server | where path =~ "^/replay-query\\?" | first)
        assert-query-auth-event $query_first "/replay-query" $query_name $query_a
        assert ($query_first.path | str contains "api%26key%3D%23%25%2B%20space%E4%B8%96%E7%95%8C~._-=") "query parameter name was not RFC 3986 encoded"
        assert ($query_first.path | str contains "NAMED-QUERY-A-SENTINEL%26injected%3D1%23cut%25%3D%2B%20%E4%B8%96%E7%95%8C~._-") "query value was not RFC 3986 encoded"

        let before_saved_query = (auth-history-ids)
        api send query-saved --collection replay --raw | ignore
        let saved_query_history = (auth-new-history $before_saved_query)
        assert-history-auth $saved_query_history "api_key" "replay-query" $all_secrets
        assert-query-auth-event (command-error-wire-events $server | where path =~ "^/replay-query-saved\\?" | first) "/replay-query-saved" $query_name $query_a

        let before_chain_query = (auth-history-ids)
        api chain run ([{
            method: GET
            url: $"($base)/replay-query-chain?existing=1#client-fragment"
            auth: {type: api_key, ref: replay-query}
        }]) --quiet | ignore
        assert-history-auth (auth-new-history $before_chain_query) "api_key" "replay-query" $all_secrets
        assert-query-auth-event (command-error-wire-events $server | where path =~ "^/replay-query-chain\\?" | first) "/replay-query-chain" $query_name $query_a

        api auth apikey set replay-query $query_b --query $query_name | ignore
        let before_query_replay = (auth-history-ids)
        api history resend $query_history.id --raw | ignore
        let query_last = (command-error-wire-events $server | where path =~ "^/replay-query\\?" | last)
        assert-query-auth-event $query_last "/replay-query" $query_name $query_b
        assert-history-auth (auth-new-history $before_query_replay) "api_key" "replay-query" $all_secrets

        let before_query_override = (auth-history-ids)
        api history resend $query_history.id --auth {type: api_key, ref: replay-query-override} --raw | ignore
        assert-query-auth-event (command-error-wire-events $server | where path =~ "^/replay-query\\?" | last) "/replay-query" $query_name $query_override
        assert-history-auth (auth-new-history $before_query_override) "api_key" "replay-query-override" $all_secrets

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

def test-public-history-save-sanitizes-at-boundary [] {
    let root = (make-temp-dir "history-save-boundary")
    let infra = (make-temp-dir "history-save-boundary-server")
    let server = (auth-test-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let base = $"http://127.0.0.1:($server.port)"
        let secrets = [
            "HISTORY-SAVE-BEARER-SENTINEL"
            "HISTORY-SAVE-BASIC-SENTINEL"
            "HISTORY-SAVE-APIKEY-SENTINEL"
            "HISTORY-SAVE-HEADER-SENTINEL"
            "HISTORY-SAVE-RESPONSE-SENTINEL"
            "HISTORY-SAVE-OVERRIDE-SENTINEL"
            "HISTORY-SAVE-TOPLEVEL-SENTINEL"
            "HISTORY-SAVE-NESTED-SENTINEL"
            "HISTORY-SAVE-RESPONSE-METADATA-SENTINEL"
            "HISTORY-SAVE-NAMED-BEARER-SENTINEL"
            "HISTORY-SAVE-NAMED-BASIC-SENTINEL"
            "HISTORY-SAVE-NAMED-API-SENTINEL"
            "HISTORY-SAVE-NAMED-OAUTH-SENTINEL"
        ]
        api auth bearer set history-save-override "HISTORY-SAVE-OVERRIDE-SENTINEL" | ignore
        api auth bearer set history-save-named-bearer "HISTORY-SAVE-NAMED-BEARER-SENTINEL" | ignore
        api auth basic set history-save-named-basic history-user "HISTORY-SAVE-NAMED-BASIC-SENTINEL" | ignore
        api auth apikey set history-save-named-api "HISTORY-SAVE-NAMED-API-SENTINEL" --query "history.named" | ignore
        api auth oauth2 configure history-save-named-oauth --client-id history-client --client-secret "HISTORY-SAVE-NAMED-OAUTH-SENTINEL" --token-url $"($base)/token" | ignore
        let response = {
            status: 200
            status_text: OK
            headers: {Set-Cookie: "session=HISTORY-SAVE-RESPONSE-SENTINEL"}
            body: {access_token: "BODY-CONTENT-PRESERVED"}
            time_ms: 1
            size_bytes: 0
            access_token: "HISTORY-SAVE-RESPONSE-METADATA-SENTINEL"
            metadata: {
                credentials: {
                    client_secret: "HISTORY-SAVE-RESPONSE-METADATA-SENTINEL"
                }
            }
        }
        let cases = [
            {
                name: "bearer"
                request: {
                    method: GET
                    url: $"($base)/history-save-boundary"
                    headers: {
                        Authorization: "Bearer HISTORY-SAVE-HEADER-SENTINEL"
                        X-Keep: exact
                    }
                    body: null
                    auth: {type: bearer, token: "HISTORY-SAVE-BEARER-SENTINEL"}
                    access_token: "HISTORY-SAVE-TOPLEVEL-SENTINEL"
                    client_secret: "HISTORY-SAVE-TOPLEVEL-SENTINEL"
                    metadata: {
                        credentials: {
                            refresh_token: "HISTORY-SAVE-NESTED-SENTINEL"
                        }
                    }
                }
                expected_auth: {type: bearer, replayable: false}
            }
            {
                name: "basic"
                request: {
                    method: GET
                    url: $"($base)/history-save-basic"
                    headers: {}
                    body: null
                    auth: {type: basic, username: history-user, password: "HISTORY-SAVE-BASIC-SENTINEL"}
                }
                expected_auth: {type: basic, replayable: false}
            }
            {
                name: "api-key"
                request: {
                    method: GET
                    url: $"($base)/history-save-api-key"
                    headers: {}
                    body: null
                    auth: {type: api_key, key: "HISTORY-SAVE-APIKEY-SENTINEL", query: "history&key"}
                }
                expected_auth: {type: api_key, replayable: false, location: query, param_name: "history&key"}
            }
        ]

        mut saved_ids = []
        for case in $cases {
            let result = (run-command-process $root $"api history save ($case.request | to nuon) ($response | to nuon)")
            assert equal $result.exit_code 0 $"direct history save failed: ($case.name): ($result.stderr)"
            assert equal ($result.stderr | str trim) "" $"direct history save wrote stderr: ($case.name)"
            assert equal $result.stdout ($result.stdout | ansi strip) $"direct history save emitted ANSI: ($case.name)"
            for secret in $secrets {
                assert (not ($result.stdout | str contains $secret)) $"direct history save exposed a secret: ($case.name)"
            }
            let id = ($result.stdout | str trim)
            assert (not ($id | is-empty)) $"direct history save did not return an id: ($case.name)"
            $saved_ids = ($saved_ids | append $id)
            let entry = (api history get $id)
            assert equal $entry.request.auth $case.expected_auth $"direct history auth was not canonical: ($case.name)"
            assert equal $entry.response.headers."Set-Cookie" "******" "direct history response header was not redacted"
            assert equal ($entry.response | columns) ["status" "status_text" "headers" "body" "time_ms" "size_bytes"] "history response retained unknown metadata"
            assert equal $entry.response.body.access_token "BODY-CONTENT-PRESERVED" "history response body semantics changed"
            if $case.name == "bearer" {
                assert equal ($entry.request | columns) ["method" "url" "headers" "body" "auth" "headers_replayable"] "history request retained unknown metadata"
                assert equal $entry.request.headers.Authorization "******"
                assert equal $entry.request.headers.X-Keep "exact"
                assert equal $entry.request.headers_replayable false
            }
            for secret in $secrets {
                assert (not (($entry | to nuon) | str contains $secret)) $"direct history get exposed a secret: ($case.name)"
            }
        }

        let named_cases = [
            {
                name: bearer
                auth: {type: bearer, token_ref: history-save-named-bearer}
                expected: {type: bearer, ref: history-save-named-bearer, replayable: true}
            }
            {
                name: basic
                auth: {type: basic, creds_ref: history-save-named-basic}
                expected: {type: basic, ref: history-save-named-basic, replayable: true}
            }
            {
                name: api-key
                auth: {type: api_key, key_ref: history-save-named-api}
                expected: {type: api_key, ref: history-save-named-api, replayable: true}
            }
            {
                name: oauth2
                auth: {type: oauth2, ref: history-save-named-oauth}
                expected: {type: oauth2, ref: history-save-named-oauth, replayable: true}
            }
        ]
        for case in $named_cases {
            let request = {
                method: GET
                url: $"($base)/history-save-named-($case.name)"
                headers: {}
                body: null
                auth: $case.auth
            }
            let id = (api history save $request $response)
            let entry = (api history get $id)
            assert equal $entry.request.auth $case.expected $"valid direct-save ref was not canonical: ($case.name)"
            for secret in $secrets {
                assert (not (($entry | to nuon) | str contains $secret)) $"valid direct-save ref exposed a credential: ($case.name)"
            }
        }

        let bearer_id = ($saved_ids | first)
        let wire_before = (command-error-wire-events $server | length)
        let history_before = (auth-history-count)
        let default_replay = (run-command-process $root $"api history resend ($bearer_id | to nuon) --raw")
        assert ($default_replay.exit_code != 0) "direct inline history replayed without auth"
        assert equal ($default_replay.stdout | str trim) ""
        assert ($default_replay.stderr | str contains "pass --auth")
        assert equal $default_replay.stderr ($default_replay.stderr | ansi strip)
        assert equal (command-error-wire-events $server | length) $wire_before
        assert equal (auth-history-count) $history_before

        let auth_only = (run-command-process $root $"api history resend ($bearer_id | to nuon) --auth {type: bearer, ref: history-save-override} --raw")
        assert ($auth_only.exit_code != 0) "redacted direct history headers replayed as mask text"
        assert equal ($auth_only.stdout | str trim) ""
        assert ($auth_only.stderr | str contains "pass --headers")
        assert equal $auth_only.stderr ($auth_only.stderr | ansi strip)
        assert equal (command-error-wire-events $server | length) $wire_before
        assert equal (auth-history-count) $history_before

        let before_override = (auth-history-ids)
        api history resend $bearer_id --auth {type: bearer, ref: history-save-override} --headers {X-Keep: exact} --raw | ignore
        assert equal (command-error-wire-events $server | length) ($wire_before + 1)
        assert-history-auth (auth-new-history $before_override) "bearer" "history-save-override" $secrets

        let exported_file = ($root | path join "history-safe.json")
        let readers = [
            $"api history show ($bearer_id | to nuon) | to nuon"
            $"api history get ($bearer_id | to nuon) | to nuon"
            "api history list | to nuon"
            "api history export --format json"
            $"api history export --format json --output ($exported_file | to nuon)"
        ]
        for command in $readers {
            let result = (run-command-process $root $command)
            assert equal $result.exit_code 0 $"history reader/export failed: ($command): ($result.stderr)"
            assert equal ($result.stderr | str trim) "" $"history reader/export wrote stderr: ($command)"
            for secret in $secrets {
                assert (not ($result.stdout | str contains $secret)) $"history reader/export exposed a secret: ($command)"
            }
        }
        let public_bytes = (
            command-error-snapshot $root
            | where {|entry| not ($entry.path | str ends-with "secrets.nuon") }
            | get content
            | compact
            | str join "\n"
        )
        for secret in $secrets {
            assert (not ($public_bytes | str contains $secret)) "history bytes/index/export persisted a credential"
        }

        api auth bearer set history-deleted-bearer deleted | ignore
        api auth basic set history-deleted-basic user deleted | ignore
        api auth apikey set history-deleted-api deleted | ignore
        api auth oauth2 configure history-deleted-oauth --client-id id --client-secret deleted --token-url $"($base)/token" | ignore
        api auth bearer delete history-deleted-bearer | ignore
        api auth basic delete history-deleted-basic | ignore
        api auth apikey delete history-deleted-api | ignore
        api auth oauth2 delete history-deleted-oauth | ignore
        let secrets_path = ($root | path join "secrets.nuon")
        let malformed = (
            open $secrets_path
            | update tokens ($in.tokens | upsert history-malformed-bearer {bearer: 42})
            | update basic_auth ($in.basic_auth | upsert history-malformed-basic {username: user})
            | update api_keys ($in.api_keys | upsert history-malformed-api {key: value, type: query})
            | update oauth ($in.oauth | upsert history-malformed-oauth {
                client_id: id
                client_secret: secret
                token_url: $"($base)/token"
                access_token: 42
            })
        )
        $malformed | to nuon --indent 4 | save -f $secrets_path

        let invalid_ref_cases = [
            {auth: {type: bearer, ref: history-missing-bearer}, expected: "history-missing-bearer"}
            {auth: {type: basic, ref: history-missing-basic}, expected: "Basic credentials 'history-missing-basic' not found"}
            {auth: {type: api_key, ref: history-missing-api}, expected: "API key 'history-missing-api' not found"}
            {auth: {type: oauth2, ref: history-missing-oauth}, expected: "OAuth2 'history-missing-oauth' not found"}
            {auth: {type: bearer, token_ref: history-deleted-bearer}, expected: "history-deleted-bearer"}
            {auth: {type: basic, creds_ref: history-deleted-basic}, expected: "Basic credentials 'history-deleted-basic' not found"}
            {auth: {type: api_key, key_ref: history-deleted-api}, expected: "API key 'history-deleted-api' not found"}
            {auth: {type: oauth2, ref: history-deleted-oauth}, expected: "OAuth2 'history-deleted-oauth' not found"}
            {auth: {type: bearer, ref: ""}, expected: "reference must be a non-empty string"}
            {auth: {type: basic, ref: ""}, expected: "reference must be a non-empty string"}
            {auth: {type: api_key, ref: ""}, expected: "reference must be a non-empty string"}
            {auth: {type: oauth2, ref: ""}, expected: "reference must be a non-empty string"}
            {auth: {type: bearer, ref: 42}, expected: "reference must be a non-empty string"}
            {auth: {type: basic, ref: 42}, expected: "reference must be a non-empty string"}
            {auth: {type: api_key, ref: 42}, expected: "reference must be a non-empty string"}
            {auth: {type: oauth2, ref: 42}, expected: "reference must be a non-empty string"}
            {auth: {type: bearer, ref: history-malformed-bearer}, expected: "history-malformed-bearer"}
            {auth: {type: basic, ref: history-malformed-basic}, expected: "Basic credentials 'history-malformed-basic' is malformed"}
            {auth: {type: api_key, ref: history-malformed-api}, expected: "API key 'history-malformed-api' is malformed"}
            {auth: {type: oauth2, ref: history-malformed-oauth}, expected: "OAuth2 'history-malformed-oauth' is malformed"}
        ]
        for case in $invalid_ref_cases {
            let before = (command-error-snapshot $root)
            let request = {method: GET, url: $"($base)/invalid-ref", headers: {}, body: null, auth: $case.auth}
            let result = (run-command-process $root $"api history save ($request | to nuon) ($response | to nuon)")
            assert ($result.exit_code != 0) "invalid direct history ref unexpectedly succeeded"
            assert equal ($result.stdout | str trim) ""
            assert ($result.stderr | str contains $case.expected) $"invalid direct history ref error was not actionable: ($result.stderr)"
            assert equal $result.stderr ($result.stderr | ansi strip)
            assert equal (command-error-snapshot $root) $before "invalid direct history ref mutated state"
        }

        let invalid_cases = [
            {
                request: {method: GET, url: $"($base)/unknown", headers: {}, body: null, auth: {type: unknown, token: unsafe}}
                expected: "Unsupported authentication type 'unknown'"
            }
            {
                request: {method: GET, url: $"($base)/malformed", headers: {}, body: null, auth: {type: bearer, replayable: true}}
                expected: "Bearer history authentication is malformed"
            }
            {
                request: {method: GET, url: $"($base)/bad-headers", headers: "HISTORY-SAVE-HEADER-SENTINEL", body: null}
                expected: "History request headers must be a record"
            }
            {
                request: {method: 42, url: $"($base)/bad-method", headers: {}, body: null}
                expected: "History request method must be a non-empty string"
            }
        ]
        for case in $invalid_cases {
            let before = (command-error-snapshot $root)
            let result = (run-command-process $root $"api history save ($case.request | to nuon) ($response | to nuon)")
            assert ($result.exit_code != 0) "unsafe direct history save unexpectedly succeeded"
            assert equal ($result.stdout | str trim) ""
            assert ($result.stderr | str contains $case.expected) $"unsafe direct history save error was not actionable: ($result.stderr)"
            assert equal $result.stderr ($result.stderr | ansi strip)
            for secret in $secrets {
                assert (not ($result.stderr | str contains $secret)) "unsafe direct history save error exposed a credential"
            }
            assert equal (command-error-snapshot $root) $before "unsafe direct history save mutated state"
        }
        let canonical_request = {method: GET, url: $"($base)/invalid-response", headers: {}, body: null}
        let invalid_responses = [
            {
                response: ($response | update status "200")
                expected: "History response status must be an integer between 100 and 599"
            }
            {
                response: ($response | update headers "HISTORY-SAVE-RESPONSE-METADATA-SENTINEL")
                expected: "History response headers must be a record"
            }
            {
                response: ($response | update time_ms (-1))
                expected: "History response time_ms must be a non-negative number"
            }
            {
                response: ($response | update size_bytes 1.5)
                expected: "History response size_bytes must be a non-negative integer"
            }
        ]
        for case in $invalid_responses {
            let before = (command-error-snapshot $root)
            let result = (run-command-process $root $"api history save ($canonical_request | to nuon) ($case.response | to nuon)")
            assert ($result.exit_code != 0) "invalid history response unexpectedly succeeded"
            assert equal ($result.stdout | str trim) ""
            assert ($result.stderr | str contains $case.expected) $"invalid history response error was not actionable: ($result.stderr)"
            assert equal $result.stderr ($result.stderr | ansi strip)
            assert equal (command-error-snapshot $root) $before "invalid history response mutated state"
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

        let legacy_id = "20200101-000000-legacy"
        let legacy_date = "2020-01-01"
        let legacy_dir = ($root | path join "history" $legacy_date)
        mkdir $legacy_dir
        let legacy_path = ($legacy_dir | path join $"($legacy_id).nuon")
        {
            id: $legacy_id
            timestamp: "2020-01-01T00:00:00Z"
            environment: null
            request: {
                method: GET
                url: $"($base)/legacy-no-auth"
                headers: {}
                body: null
            }
            response: {
                status: 200
                status_text: OK
                headers: {}
                body: null
                time_ms: 1
                size_bytes: 0
            }
        } | to nuon | save $legacy_path
        [{
            id: $legacy_id
            timestamp: "2020-01-01T00:00:00Z"
            method: GET
            url: $"($base)/legacy-no-auth"
            status: 200
            time_ms: 1
            date_dir: $legacy_date
        }] | to nuon | save -f ($root | path join "history" "index.nuon")
        let legacy_bytes = (open $legacy_path --raw)
        api history resend $legacy_id --raw | ignore
        assert equal (command-error-wire-events $server | where path == "/legacy-no-auth" | length) 1 "legacy no-auth history no longer resends"
        assert (((api history get $legacy_id).request.auth? | default null) == null) "legacy entry was migrated unexpectedly"
        assert equal (open $legacy_path --raw) $legacy_bytes "legacy history file was migrated during resend"

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
        let preview_query_name = "api&key=#%+ space世界~._-"
        let preview_query_secret = "PREVIEW-QUERY-SENTINEL&injected=1#cut%=+ 世界~._-"
        let secrets = [
            "PREVIEW-BEARER-SENTINEL"
            "PREVIEW-BASIC-SENTINEL"
            "PREVIEW-HEADER-SENTINEL"
            $preview_query_secret
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
        api auth apikey set preview-query $preview_query_secret --query $preview_query_name | ignore
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
            {label: "put API-key query", command: $"api put (($base + '/direct-query?existing=1#frag') | to nuon) -b {ok: true} -a {type: api_key, ref: preview-query} --dry-run", expected: ["existing=1&api%26key%3D%23%25%2B%20space%E4%B8%96%E7%95%8C~._-=******#frag"]}
            {label: "patch OAuth", command: $"api patch (($base + '/direct-oauth') | to nuon) -b {ok: true} -a {type: oauth2, ref: preview-oauth} --dry-run", expected: ["Authorization: ******"]}
            {label: "delete inline bearer", command: $"api delete (($base + '/inline-bearer') | to nuon) -a {type: bearer, token: 'PREVIEW-BEARER-SENTINEL'} --dry-run", expected: ["Authorization: ******"]}
            {label: "head inline basic", command: $"api head (($base + '/inline-basic') | to nuon) -a {type: basic, username: user, password: 'PREVIEW-BASIC-SENTINEL'} --dry-run", expected: ["-u ******:******"]}
            {label: "options inline query", command: $"api options (($base + '/empty?#frag') | to nuon) -a {type: api_key, key: 'PREVIEW-QUERY-SENTINEL', query: 'api.key+odd'} --dry-run", expected: ["empty?api.key%2Bodd=******#frag"]}
            {
                label: "sensitive explicit headers"
                command: $"api get (($base + '/sensitive-headers') | to nuon) -H {Authorization: 'EXPLICIT-AUTH-SENTINEL', Proxy-Authorization: 'EXPLICIT-PROXY-SENTINEL', Cookie: 'EXPLICIT-COOKIE-SENTINEL', Set-Cookie: 'EXPLICIT-SET-COOKIE-SENTINEL', X-Auth-Token: 'EXPLICIT-TOKEN-SENTINEL', X-Keep: exact} --dry-run"
                expected: ["Authorization: ******" "Proxy-Authorization: ******" "Cookie: ******" "Set-Cookie: ******" "X-Auth-Token: ******" "X-Keep: exact"]
            }
        ]
        let saved_commands = ["bearer" "basic" "header" "query" "oauth"] | each {|name|
            let expected = if $name == "query" {
                ["api%26key%3D%23%25%2B%20space%E4%B8%96%E7%95%8C~._-=******#frag"]
            } else {
                ["******"]
            }
            [
                {label: $"send ($name)", command: $"api send ($name) --collection preview --dry-run", expected: $expected}
                {label: $"export ($name)", command: $"api request export ($name) --collection preview", expected: $expected}
            ]
        } | flatten
        let history_commands = $replay_ids | each {|item|
            let expected = if $item.name == "query" {
                ["api%26key%3D%23%25%2B%20space%E4%B8%96%E7%95%8C~._-=******#frag"]
            } else {
                ["******"]
            }
            {label: $"history resend ($item.name)", command: $"api history resend ($item.id | to nuon) --dry-run", expected: $expected}
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

def test-oauth-provider-errors-are-secret-safe [] {
    let root = (make-temp-dir "oauth-provider-errors")
    let infra = (make-temp-dir "oauth-provider-errors-server")
    let server = (auth-test-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let base = $"http://127.0.0.1:($server.port)"
        let output_path = ($root | path join "oauth-error-output.bin")
        let save_path = ($root | path join "oauth-error-save.txt")
        let secrets = [
            "CLIENT-SECRET-ERROR-SENTINEL"
            "CLIENT-SECRET-REFRESH-ERROR-SENTINEL"
            "ACCESS-TOKEN-ERROR-SENTINEL"
            "REFRESH-TOKEN-ERROR-SENTINEL"
            "FAILED-ACCESS-SENTINEL"
            "FAILED-REFRESH-SENTINEL"
            "DESCRIPTION-ONLY-SENTINEL"
            "UNSAFE-ERROR-CODE-SENTINEL"
            "MALFORMED-OAUTH-SENTINEL"
            "NONRECORD-OAUTH-SENTINEL"
            "MISSING-ACCESS-REFRESH-SENTINEL"
            "EMPTY-ACCESS-REFRESH-SENTINEL"
            "NONSTRING-ACCESS-SENTINEL"
            "INVALID-REFRESH-ACCESS-SENTINEL"
            "INVALID-TYPE-ACCESS-SENTINEL"
            "UNSUPPORTED-TYPE-ACCESS-SENTINEL"
            "INVALID-EXPIRY-ACCESS-SENTINEL"
            "INVALID-EXPIRY-TYPE-ACCESS-SENTINEL"
            "INVALID-EXPIRY-HIGH-ACCESS-SENTINEL"
        ]

        api auth oauth2 configure provider-error --client-id error-client --client-secret "CLIENT-SECRET-ERROR-SENTINEL" --token-url $"($base)/token-error-initial" | ignore
        api collection create oauth-errors | ignore
        api request create provider-error GET $"($base)/saved-provider-error" --collection oauth-errors --auth {type: oauth2, ref: provider-error} | ignore
        let history_id = (api history save {
            method: GET
            url: $"($base)/history-provider-error"
            headers: {}
            body: null
            auth: {type: oauth2, ref: provider-error}
        } {
            status: 200
            status_text: OK
            headers: {}
            body: null
            time_ms: 1
            size_bytes: 0
        })

        let commands = [
            $"api get (($base + '/direct-provider-error') | to nuon) -a {type: oauth2, ref: provider-error} --save ($save_path | to nuon) --binary-save ($output_path | to nuon) --output none"
            "api send provider-error --collection oauth-errors --output none"
            $"api history resend ($history_id | to nuon) --raw"
            $"api chain run ([{method: GET, url: (($base + '/chain-provider-error') | to nuon), auth: {type: oauth2, ref: provider-error}}]) --quiet | ignore"
        ]
        mut expected_count = 0
        for command in $commands {
            let before = (command-error-snapshot $root)
            let history_before = (auth-history-count)
            let result = (run-command-process $root $command)
            $expected_count = $expected_count + 1
            assert ($result.exit_code != 0) $"OAuth provider error unexpectedly succeeded: ($command)"
            assert equal ($result.stdout | str trim) "" $"OAuth provider error wrote stdout: ($command)"
            assert ($result.stderr | str contains "OAuth2 provider error: invalid_client") $"OAuth provider error omitted its safe code: ($command): ($result.stderr)"
            assert ($result.stderr | str contains "HTTP 400") $"OAuth provider error omitted its safe status: ($command): ($result.stderr)"
            assert equal $result.stderr ($result.stderr | ansi strip) $"OAuth provider error emitted ANSI: ($command)"
            for secret in $secrets {
                assert (not ($result.stderr | str contains $secret)) $"OAuth provider error exposed a credential: ($command)"
            }
            assert equal (open $server.count_file --raw | str trim | into int) $expected_count "OAuth provider error retried or skipped its one token request"
            assert equal (command-error-wire-events $server | length) 0 "OAuth provider error reached the protected endpoint"
            assert equal (auth-history-count) $history_before "OAuth provider error created history"
            assert equal (command-error-snapshot $root) $before "OAuth provider error mutated config, secrets, history, or output state"
            assert (not ($output_path | path exists)) "OAuth provider error mutated binary output"
            assert (not ($save_path | path exists)) "OAuth provider error mutated text output"
        }

        api auth oauth2 configure refresh-error --client-id refresh-client --client-secret "CLIENT-SECRET-REFRESH-ERROR-SENTINEL" --token-url $"($base)/token-error-refresh" | ignore
        let secrets_path = ($root | path join "secrets.nuon")
        let seeded = (
            open $secrets_path
            | update oauth.refresh-error.access_token "ACCESS-TOKEN-ERROR-SENTINEL"
            | update oauth.refresh-error.refresh_token "REFRESH-TOKEN-ERROR-SENTINEL"
            | update oauth.refresh-error.expires_at "2000-01-01T00:00:00Z"
        )
        $seeded | to nuon --indent 4 | save -f $secrets_path
        let refresh_before = (command-error-snapshot $root)
        let refresh_count_before = (open $server.count_file --raw | str trim | into int)
        let refresh = (run-command-process $root "api auth oauth2 refresh refresh-error")
        assert ($refresh.exit_code != 0) "OAuth refresh provider error unexpectedly succeeded"
        assert equal ($refresh.stdout | str trim) ""
        assert ($refresh.stderr | str contains "OAuth2 provider error: invalid_grant") $"OAuth refresh error omitted its safe code: ($refresh.stderr)"
        assert ($refresh.stderr | str contains "HTTP 400") $"OAuth refresh error omitted its safe status: ($refresh.stderr)"
        assert equal $refresh.stderr ($refresh.stderr | ansi strip)
        for secret in $secrets {
            assert (not ($refresh.stderr | str contains $secret)) "OAuth refresh provider error exposed a credential"
        }
        assert equal (open $server.count_file --raw | str trim | into int) ($refresh_count_before + 1) "OAuth refresh provider error triggered a fallback token retry"
        assert equal (command-error-snapshot $root) $refresh_before "OAuth refresh provider error mutated secret/config/history state"

        let invalid_shapes = [
            {name: status-302, status: 302, code: unknown_error}
            {name: status-400, status: 400, code: unknown_error}
            {name: status-500, status: 500, code: unknown_error}
            {name: description-only, status: 400, code: unknown_error}
            {name: unsafe-code, status: 400, code: unknown_error}
            {name: malformed-json, status: 200, code: invalid_response}
            {name: non-record, status: 200, code: invalid_response}
            {name: missing-access, status: 200, code: invalid_response}
            {name: empty-access, status: 200, code: invalid_response}
            {name: nonstring-access, status: 200, code: invalid_response}
            {name: invalid-refresh, status: 200, code: invalid_response}
            {name: invalid-type, status: 200, code: invalid_response}
            {name: unsupported-type, status: 200, code: invalid_response}
            {name: invalid-expiry, status: 200, code: invalid_response}
            {name: invalid-expiry-type, status: 200, code: invalid_response}
            {name: invalid-expiry-high, status: 200, code: invalid_response}
        ]
        for case in $invalid_shapes {
            let initial_name = $"shape-initial-($case.name)"
            let initial_client_secret = $"INITIAL-CLIENT-($case.name)"
            api auth oauth2 configure $initial_name --client-id shape-client --client-secret $initial_client_secret --token-url $"($base)/token-($case.name)" | ignore
            let initial_before = (command-error-snapshot $root)
            let initial_count = (open $server.count_file --raw | str trim | into int)
            let initial_command = if $case.name == "status-500" {
                $"api get (($base + '/must-not-use-failed-token') | to nuon) -a {type: oauth2, ref: ($initial_name)} --save ($save_path | to nuon) --binary-save ($output_path | to nuon) --output none"
            } else {
                $"api auth oauth2 token ($initial_name | to nuon)"
            }
            let initial = (run-command-process $root $initial_command)
            assert ($initial.exit_code != 0) $"invalid initial OAuth response unexpectedly succeeded: ($case.name)"
            assert equal ($initial.stdout | str trim) "" $"invalid initial OAuth response wrote stdout: ($case.name)"
            assert ($initial.stderr | str contains $"OAuth2 provider error: ($case.code)") $"invalid initial OAuth response omitted its safe code: ($case.name): ($initial.stderr)"
            assert ($initial.stderr | str contains $"HTTP ($case.status)") $"invalid initial OAuth response omitted its status: ($case.name): ($initial.stderr)"
            assert equal $initial.stderr ($initial.stderr | ansi strip) $"invalid initial OAuth response emitted ANSI: ($case.name)"
            for secret in ($secrets | append $initial_client_secret) {
                assert (not ($initial.stderr | str contains $secret)) $"invalid initial OAuth response exposed provider data: ($case.name)"
            }
            assert equal (open $server.count_file --raw | str trim | into int) ($initial_count + 1) $"invalid initial OAuth response did not make exactly one token request: ($case.name)"
            assert equal (command-error-wire-events $server | length) 0 $"invalid initial OAuth response reached a protected endpoint: ($case.name)"
            assert equal (command-error-snapshot $root) $initial_before $"invalid initial OAuth response mutated state: ($case.name)"
            assert (not ($output_path | path exists))
            assert (not ($save_path | path exists))

            let refresh_name = $"shape-refresh-($case.name)"
            let refresh_client_secret = $"REFRESH-CLIENT-($case.name)"
            let old_access = $"OLD-ACCESS-($case.name)"
            let old_refresh = $"OLD-REFRESH-($case.name)"
            api auth oauth2 configure $refresh_name --client-id refresh-client --client-secret $refresh_client_secret --token-url $"($base)/token-($case.name)" | ignore
            let current = (open $secrets_path)
            let refresh_config = (
                $current.oauth
                | get $refresh_name
                | upsert access_token $old_access
                | upsert refresh_token $old_refresh
                | upsert expires_at "2000-01-01T00:00:00Z"
            )
            ($current | update oauth ($current.oauth | upsert $refresh_name $refresh_config))
            | to nuon --indent 4
            | save -f $secrets_path
            let refresh_shape_before = (command-error-snapshot $root)
            let shape_count = (open $server.count_file --raw | str trim | into int)
            let refresh_shape = (run-command-process $root $"api auth oauth2 refresh ($refresh_name | to nuon)")
            assert ($refresh_shape.exit_code != 0) $"invalid OAuth refresh response unexpectedly succeeded: ($case.name)"
            assert equal ($refresh_shape.stdout | str trim) "" $"invalid OAuth refresh response wrote stdout: ($case.name)"
            assert ($refresh_shape.stderr | str contains $"OAuth2 provider error: ($case.code)") $"invalid OAuth refresh response omitted its safe code: ($case.name): ($refresh_shape.stderr)"
            assert ($refresh_shape.stderr | str contains $"HTTP ($case.status)") $"invalid OAuth refresh response omitted its status: ($case.name): ($refresh_shape.stderr)"
            assert equal $refresh_shape.stderr ($refresh_shape.stderr | ansi strip) $"invalid OAuth refresh response emitted ANSI: ($case.name)"
            for secret in ($secrets | append [$refresh_client_secret $old_access $old_refresh]) {
                assert (not ($refresh_shape.stderr | str contains $secret)) $"invalid OAuth refresh response exposed provider data: ($case.name)"
            }
            assert equal (open $server.count_file --raw | str trim | into int) ($shape_count + 1) $"invalid OAuth refresh response retried or skipped the token endpoint: ($case.name)"
            assert equal (command-error-snapshot $root) $refresh_shape_before $"invalid OAuth refresh response overwrote stored credentials: ($case.name)"
        }

        api auth oauth2 configure valid-shaped --client-id valid-client --client-secret valid-secret --token-url $"($base)/token-valid-shaped" | ignore
        let valid_count = (open $server.count_file --raw | str trim | into int)
        let valid_initial = (run-command-process $root "api auth oauth2 token valid-shaped")
        assert equal $valid_initial.exit_code 0 $"valid shaped token failed: ($valid_initial.stderr)"
        assert equal ($valid_initial.stderr | str trim) ""
        assert equal (open $server.count_file --raw | str trim | into int) ($valid_count + 1)
        let valid_secrets = (open $secrets_path)
        assert equal $valid_secrets.oauth.valid-shaped.access_token "VALID-SHAPED-ACCESS"
        assert equal $valid_secrets.oauth.valid-shaped.refresh_token "VALID-SHAPED-REFRESH"

        let valid_seeded = (
            $valid_secrets
            | update oauth.valid-shaped.access_token "OLD-VALID-ACCESS"
            | update oauth.valid-shaped.refresh_token "OLD-VALID-REFRESH"
            | update oauth.valid-shaped.expires_at "2000-01-01T00:00:00Z"
        )
        $valid_seeded | to nuon --indent 4 | save -f $secrets_path
        let valid_refresh_count = (open $server.count_file --raw | str trim | into int)
        let valid_refresh = (run-command-process $root "api auth oauth2 refresh valid-shaped")
        assert equal $valid_refresh.exit_code 0 $"valid shaped refresh failed: ($valid_refresh.stderr)"
        assert equal ($valid_refresh.stderr | str trim) ""
        assert equal (open $server.count_file --raw | str trim | into int) ($valid_refresh_count + 1)
        let refreshed_valid = (open $secrets_path)
        assert equal $refreshed_valid.oauth.valid-shaped.access_token "VALID-SHAPED-ACCESS"
        assert equal $refreshed_valid.oauth.valid-shaped.refresh_token "VALID-SHAPED-REFRESH"
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
        (run-test "public history save sanitizes auth and headers at the persistence boundary" { test-public-history-save-sanitizes-at-boundary })
        (run-test "legacy history replays while missing, deleted, malformed, and unknown auth fail safely" { test-legacy-and-invalid-auth-history })
        (run-test "dry-run, send, export, and history previews mask all supported auth" { test-auth-preview-and-export-secrecy })
        (run-test "OAuth provider errors expose only stable safe codes across request surfaces" { test-oauth-provider-errors-are-secret-safe })
        (run-test "authenticated output modes preserve types and never expose auth" { test-authenticated-output-contracts })
    ]
}
