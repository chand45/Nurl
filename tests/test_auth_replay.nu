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

def assert-unsafe-url-error [
    result: record
    label: string
    sentinel: string
    expected: string
] {
    assert ($result.exit_code != 0) $"unsafe URL unexpectedly succeeded: ($label)"
    assert equal ($result.stdout | str trim) "" $"unsafe URL wrote stdout: ($label)"
    assert ($result.stderr | str contains $expected) $"unsafe URL error was not actionable: ($label): ($result.stderr)"
    assert equal $result.stderr ($result.stderr | ansi strip) $"unsafe URL error emitted ANSI: ($label)"
    assert (not ($result.stderr | str contains $sentinel)) $"unsafe URL error exposed its value: ($label)"
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

def test-secret-bearing-urls-fail-preflight [] {
    let root = (make-temp-dir "secret-url-preflight")
    let infra = (make-temp-dir "secret-url-preflight-server")
    let server = (auth-test-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let base = $"http://127.0.0.1:($server.port)"
        let sentinel = "URL-CREDENTIAL-SENTINEL"
        let response = {
            status: 200
            status_text: OK
            headers: {}
            body: null
            time_ms: 1
            size_bytes: 0
        }

        let unsafe_cases = [
            {
                label: userinfo
                url: $"http://url-user:($sentinel)@127.0.0.1:($server.port)/userinfo"
                expected: "Unsafe URL userinfo"
            }
            {
                label: access-token
                url: $"($base)/query?access_token=($sentinel)"
                expected: "Unsafe URL query parameter 'ACCESS_TOKEN'"
            }
            {
                label: masked-access-token
                url: $"($base)/query?access_token=******"
                expected: "Unsafe URL query parameter 'ACCESS_TOKEN'"
            }
            {
                label: encoded-mixed-case
                url: $"($base)/query?AcCeSs%5FtOkEn=($sentinel)"
                expected: "Unsafe URL query parameter 'ACCESS_TOKEN'"
            }
            {
                label: duplicate-token
                url: $"($base)/query?ok=1&token=($sentinel)&token=second"
                expected: "Unsafe URL query parameter 'TOKEN'"
            }
            {
                label: refresh-token
                url: $"($base)/query?refresh_token=($sentinel)"
                expected: "Unsafe URL query parameter 'REFRESH_TOKEN'"
            }
            {
                label: api-key-alias
                url: $"($base)/query?X%2DAPI%2DKEY=($sentinel)"
                expected: "Unsafe URL query parameter 'X_API_KEY'"
            }
            {
                label: key-alias
                url: $"($base)/query?key=($sentinel)"
                expected: "Unsafe URL query parameter 'KEY'"
            }
            {
                label: auth-token-alias
                url: $"($base)/query?authorizationToken=($sentinel)"
                expected: "Unsafe URL query parameter 'AUTHORIZATIONTOKEN'"
            }
            {
                label: fragment-secret
                url: $"($base)/fragment#client%5Fsecret=($sentinel)"
                expected: "Unsafe URL fragment parameter 'CLIENT_SECRET'"
            }
            {
                label: fragment-route-token
                url: $"($base)/fragment#/callback?BeArEr-ToKeN=($sentinel)"
                expected: "Unsafe URL fragment parameter 'BEARER_TOKEN'"
            }
            {
                label: malformed-query-name
                url: $"($base)/query?access%2token=($sentinel)"
                expected: "Malformed percent encoding in URL query parameter name"
            }
            {
                label: malformed-fragment-name
                url: $"($base)/fragment#client%GGsecret=($sentinel)"
                expected: "Malformed percent encoding in URL fragment parameter name"
            }
            {
                label: malformed-utf8-name
                url: $"($base)/query?%FF=($sentinel)"
                expected: "Malformed percent encoding in URL query parameter name"
            }
        ]

        for case in $unsafe_cases {
            let before = (command-error-snapshot $root)
            let request = {method: GET, url: $case.url, headers: {}, body: null}
            let result = (run-command-process $root $"api history save ($request | to nuon) ($response | to nuon)")
            assert-unsafe-url-error $result $"history save ($case.label)" $sentinel $case.expected
            assert equal (command-error-snapshot $root) $before $"unsafe direct history save mutated state: ($case.label)"
            assert equal (open $server.count_file --raw | str trim | into int) 0
            assert equal (command-error-wire-events $server | length) 0
        }

        api auth oauth2 configure url-preflight-oauth --client-id safe-client --client-secret "URL-OAUTH-CLIENT-SECRET" --token-url $"($base)/token" | ignore
        let unsafe_saved_url = $"($base)/saved?refresh_token=($sentinel)"
        api request create unsafe-url-saved GET $unsafe_saved_url --collection default --auth {type: oauth2, ref: url-preflight-oauth} | ignore
        let unsafe_template_url = $base + "/interpolated?{{unsafe_name}}={{unsafe_value}}"
        api request create unsafe-url-interpolated GET $unsafe_template_url --collection default --auth {type: oauth2, ref: url-preflight-oauth} | ignore
        let save_path = ($root | path join "url-preflight-output.txt")
        let binary_path = ($root | path join "url-preflight-output.bin")
        "SAVE-UNCHANGED" | save $save_path
        "BINARY-UNCHANGED" | save $binary_path

        let direct_userinfo_url = $"http://live-user:($sentinel)@127.0.0.1:($server.port)/direct"
        let generic_fragment_url = $"($base)/generic#access_token=($sentinel)"
        let chain_steps = [{
            method: GET
            url: $"($base)/chain#client_secret=($sentinel)"
            auth: {type: oauth2, ref: url-preflight-oauth}
        }]
        let live_cases = [
            {
                label: direct-verb-userinfo
                command: $"api get ($direct_userinfo_url | to nuon) --auth {type: oauth2, ref: url-preflight-oauth} --save ($save_path | to nuon) --output none"
                expected: "Unsafe URL userinfo"
            }
            {
                label: generic-fragment
                command: $"api request -m GET ($generic_fragment_url | to nuon) --auth {type: oauth2, ref: url-preflight-oauth} --output none"
                expected: "Unsafe URL fragment parameter 'ACCESS_TOKEN'"
            }
            {
                label: saved-query
                command: $"api send unsafe-url-saved --collection default --binary-save ($binary_path | to nuon) --output none"
                expected: "Unsafe URL query parameter 'REFRESH_TOKEN'"
            }
            {
                label: saved-export-query
                command: "api request export unsafe-url-saved --collection default"
                expected: "Unsafe URL query parameter 'REFRESH_TOKEN'"
            }
            {
                label: saved-interpolated-query
                command: $"api send unsafe-url-interpolated --collection default --vars {unsafe_name: access_token, unsafe_value: ($sentinel | to nuon)} --output none"
                expected: "Unsafe URL query parameter 'ACCESS_TOKEN'"
            }
            {
                label: chain-fragment
                command: $"api chain run ($chain_steps | to nuon) | ignore"
                expected: "Unsafe URL fragment parameter 'CLIENT_SECRET'"
            }
        ]
        for case in $live_cases {
            let before = (command-error-snapshot $root)
            let result = (run-command-process $root $case.command)
            assert-unsafe-url-error $result $case.label $sentinel $case.expected
            assert equal (command-error-snapshot $root) $before $"unsafe live URL mutated state: ($case.label)"
            assert equal (open $server.count_file --raw | str trim | into int) 0 $"unsafe live URL acquired an OAuth token: ($case.label)"
            assert equal (command-error-wire-events $server | length) 0 $"unsafe live URL reached the protected server: ($case.label)"
        }

        let safe_urls = [
            $"($base)/safe-boundary?access_token_count=1&monkey=2&keynote=3&tokenizer=4"
            $"($base)/safe-boundary?value=%61ccess_token&%E4%B8%96%E7%95%8C=ok&dup=1&dup=2"
            $"($base)/safe-boundary?label=%E4%B8%96%E7%95%8C#access-token-section"
            $"($base)/safe-boundary?#ordinary-fragment"
        ]
        mut safe_ids = []
        for url in $safe_urls {
            let before_ids = (auth-history-ids)
            let result = (api get $url --raw)
            assert equal $result.response.status 200 $"safe URL failed: ($url)"
            let entry = (auth-new-history $before_ids)
            assert equal $entry.request.url $url "safe URL was not preserved exactly"
            assert (not ($entry.request.url | str contains "******")) "safe URL persisted a mask as data"
            $safe_ids = ($safe_ids | append $entry.id)
        }

        api auth apikey set managed-url-query "MANAGED-URL-KEY-SENTINEL" --query access_token | ignore
        let managed_url = $"($base)/managed-query?ordinary=1#managed-fragment"
        let managed_before = (auth-history-ids)
        api get $managed_url --auth {type: api_key, ref: managed-url-query} --raw | ignore
        let managed_entry = (auth-new-history $managed_before)
        assert equal $managed_entry.request.url $managed_url "managed query auth changed the persisted caller URL"
        assert-history-auth $managed_entry "api_key" "managed-url-query" ["MANAGED-URL-KEY-SENTINEL"]
        let managed_wire = (command-error-wire-events $server | last)
        assert ($managed_wire.path | str contains "access_token=MANAGED-URL-KEY-SENTINEL") "managed query auth was not sent"
        assert (not ($managed_wire.path | str contains "#")) "managed query auth sent the URL fragment"

        let preview = (run-command-process $root $"api get ($managed_url | to nuon) --auth {type: api_key, ref: managed-url-query} --dry-run")
        assert-safe-preview $preview "managed sensitive-name query preview" ["MANAGED-URL-KEY-SENTINEL"] ["access_token=******"]
        let resend_before = (command-error-wire-events $server | length)
        api history resend $managed_entry.id --raw | ignore
        assert equal (command-error-wire-events $server | length) ($resend_before + 1) "managed query auth history did not replay"

        let safe_id = ($safe_ids | first)
        let safe_url = ($safe_urls | first)
        let json_export = ($root | path join "safe-history.json")
        let csv_export = ($root | path join "safe-history.csv")
        let readers = [
            "api history list | to nuon"
            "api history search safe-boundary | to nuon"
            $"api history show ($safe_id | to nuon) | to nuon"
            $"api history get ($safe_id | to nuon) | to nuon"
            $"api history export --format json --output ($json_export | to nuon)"
            $"api history export --format csv --output ($csv_export | to nuon)"
        ]
        for command in $readers {
            let result = (run-command-process $root $command)
            assert equal $result.exit_code 0 $"safe history reader/export failed: ($command): ($result.stderr)"
            assert equal ($result.stderr | str trim) ""
            assert (not ($result.stdout | str contains $sentinel)) $"safe history surface exposed a rejected URL value: ($command)"
        }
        let safe_public_bytes = $"(open $json_export --raw)\n(open $csv_export --raw)"
        assert ($safe_public_bytes | str contains $safe_url) "safe history exports did not preserve the URL"
        assert (not ($safe_public_bytes | str contains $sentinel)) "safe history export contained a rejected URL value"
        assert (not ($safe_public_bytes | str contains "******")) "safe history export persisted a mask as URL data"

        let legacy_id = "20200102-000000-unsafe-url"
        let legacy_date = "2020-01-02"
        let legacy_dir = ($root | path join "history" $legacy_date)
        mkdir $legacy_dir
        let legacy_path = ($legacy_dir | path join $"($legacy_id).nuon")
        let legacy_url = $"($base)/legacy?access_token=($sentinel)"
        {
            id: $legacy_id
            timestamp: "2020-01-02T00:00:00Z"
            environment: null
            request: {method: GET, url: $legacy_url, headers: {}, body: null}
            response: $response
        } | to nuon | save $legacy_path
        let index_path = ($root | path join "history" "index.nuon")
        let index = (open $index_path)
        ($index | append {
            id: $legacy_id
            timestamp: "2020-01-02T00:00:00Z"
            method: GET
            url: $legacy_url
            status: 200
            time_ms: 1
            date_dir: $legacy_date
        }) | to nuon | save -f $index_path
        for command in [
            $"api history resend ($legacy_id | to nuon) --raw"
            $"api history resend ($legacy_id | to nuon) --dry-run"
        ] {
            let legacy_before = (command-error-snapshot $root)
            let legacy_wire_before = (command-error-wire-events $server | length)
            let legacy_result = (run-command-process $root $command)
            assert-unsafe-url-error $legacy_result "legacy history resend" $sentinel "Unsafe URL query parameter 'ACCESS_TOKEN'"
            assert equal (command-error-snapshot $root) $legacy_before "legacy unsafe URL resend migrated or rewrote history"
            assert equal (command-error-wire-events $server | length) $legacy_wire_before "legacy unsafe URL resend reached the network"
        }
        assert equal (api history get $legacy_id | get request.url) $legacy_url "legacy unsafe URL read compatibility changed"
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def test-password-credential-name-policy [] {
    let root = (make-temp-dir "password-credential-policy")
    let infra = (make-temp-dir "password-credential-policy-server")
    let server = (auth-test-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let base = $"http://127.0.0.1:($server.port)"
        let url_sentinel = "URL-PASSWORD-SENTINEL"
        let response = {
            status: 200
            status_text: OK
            headers: {}
            body: null
            time_ms: 1
            size_bytes: 0
        }

        # Literal policy expectations intentionally do not reuse production helpers or lists.
        let unsafe_url_cases = [
            {label: password-raw, suffix: $"?password=($url_sentinel)#safe", expected: "PASSWORD"}
            {label: password-encoded, suffix: $"?pass%77ord=($url_sentinel)", expected: "PASSWORD"}
            {label: password-mixed, suffix: $"?PaSsWoRd=($url_sentinel)", expected: "PASSWORD"}
            {label: password-duplicate, suffix: $"?ok=1&password=($url_sentinel)&password=second", expected: "PASSWORD"}
            {label: password-fragment, suffix: $"#password=($url_sentinel)", expected: "PASSWORD"}
            {label: passwd-raw, suffix: $"?passwd=($url_sentinel)", expected: "PASSWD"}
            {label: passwd-encoded-fragment, suffix: $"#route?pass%77d=($url_sentinel)", expected: "PASSWD"}
            {label: pwd-mixed, suffix: $"?PwD=($url_sentinel)", expected: "PWD"}
            {label: pwd-encoded-fragment, suffix: $"#p%77d=($url_sentinel)", expected: "PWD"}
            {label: access-token, suffix: $"?access_token=($url_sentinel)", expected: "ACCESS_TOKEN"}
            {label: refresh-token, suffix: $"?refresh%5Ftoken=($url_sentinel)", expected: "REFRESH_TOKEN"}
            {label: client-secret, suffix: $"#ClIeNt-SeCrEt=($url_sentinel)", expected: "CLIENT_SECRET"}
            {label: auth-token, suffix: $"?authToken=($url_sentinel)", expected: "AUTHTOKEN"}
            {label: bearer-token, suffix: $"?bearer_token=($url_sentinel)", expected: "BEARER_TOKEN"}
            {label: token, suffix: $"?token=($url_sentinel)", expected: "TOKEN"}
            {label: api-key, suffix: $"?api%5Fkey=($url_sentinel)", expected: "API_KEY"}
            {label: x-api-key, suffix: $"?X-API-Key=($url_sentinel)", expected: "X_API_KEY"}
            {label: key, suffix: $"?key=($url_sentinel)", expected: "KEY"}
        ]
        for case in $unsafe_url_cases {
            let before = (command-error-snapshot $root)
            let request = {
                method: GET
                url: $"($base)/password-policy($case.suffix)"
                headers: {}
                body: null
            }
            let result = (run-command-process $root $"api history save ($request | to nuon) ($response | to nuon)")
            assert-unsafe-url-error $result $"password URL policy ($case.label)" $url_sentinel $"Unsafe URL"
            assert ($result.stderr | str contains $case.expected) $"password URL error omitted safe name: ($case.label)"
            assert equal (command-error-snapshot $root) $before $"password URL policy mutated state: ($case.label)"
        }
        for case in [
            {label: malformed-password, suffix: $"?pass%2word=($url_sentinel)", expected: "Malformed percent encoding"}
            {label: malformed-pwd-fragment, suffix: $"#p%GGwd=($url_sentinel)", expected: "Malformed percent encoding"}
        ] {
            let before = (command-error-snapshot $root)
            let request = {method: GET, url: $"($base)/password-malformed($case.suffix)", headers: {}, body: null}
            let result = (run-command-process $root $"api history save ($request | to nuon) ($response | to nuon)")
            assert-unsafe-url-error $result $case.label $url_sentinel $case.expected
            assert equal (command-error-snapshot $root) $before $"malformed password URL mutated state: ($case.label)"
        }
        api auth oauth2 configure password-url-oauth --client-id safe-client --client-secret "PASSWORD-URL-OAUTH-SECRET" --token-url $"($base)/token" | ignore
        let unsafe_live_url = $"($base)/password-live?password=($url_sentinel)"
        let unsafe_output = ($root | path join "password-url-output.txt")
        "UNCHANGED" | save $unsafe_output
        let unsafe_live_before = (command-error-snapshot $root)
        let unsafe_live = (run-command-process $root $"api get ($unsafe_live_url | to nuon) --auth {type: oauth2, ref: password-url-oauth} --save ($unsafe_output | to nuon) --output none")
        assert-unsafe-url-error $unsafe_live "live password URL" $url_sentinel "Unsafe URL query parameter 'PASSWORD'"
        assert equal (command-error-snapshot $root) $unsafe_live_before "live password URL mutated state"
        assert equal (open $server.count_file --raw | str trim | into int) 0 "live password URL acquired an OAuth token"
        assert equal (command-error-wire-events $server | length) 0 "live password URL reached the protected server"

        let safe_url_cases = [
            $"($base)/safe-password?password_hint=allowed"
            $"($base)/safe-password?compass=allowed"
            $"($base)/safe-password?pwd_reset_status=allowed"
            $"($base)/safe-password?passwd_count=1"
            $"($base)/safe-password?bypass-word=allowed#password-section"
        ]
        mut safe_url_ids = []
        for url in $safe_url_cases {
            let before_ids = (auth-history-ids)
            api get $url --raw | ignore
            let entry = (auth-new-history $before_ids)
            assert equal $entry.request.url $url "safe password lookalike URL changed"
            $safe_url_ids = ($safe_url_ids | append $entry.id)
        }

        let header_cases = [
            {name: Password, secret: "HEADER-PASSWORD-SENTINEL"}
            {name: password, secret: "HEADER-PASSWORD-CASE-SENTINEL"}
            {name: Passwd, secret: "HEADER-PASSWD-SENTINEL"}
            {name: Pwd, secret: "HEADER-PWD-SENTINEL"}
            {name: X-Password, secret: "HEADER-X-PASSWORD-SENTINEL"}
            {name: X_PASSWORD, secret: "HEADER-X-PASSWORD-UNDERSCORE-SENTINEL"}
            {name: X-Passwd, secret: "HEADER-X-PASSWD-SENTINEL"}
            {name: x_passwd, secret: "HEADER-X-PASSWD-CASE-SENTINEL"}
            {name: X-Pwd, secret: "HEADER-X-PWD-SENTINEL"}
            {name: x_pwd, secret: "HEADER-X-PWD-CASE-SENTINEL"}
        ]
        mut sensitive_header_ids = []
        for case in $header_cases {
            let headers = ({} | upsert $case.name $case.secret | upsert X-Keep exact)
            for surface in [
                {label: direct, command: $"api get (($base + '/header-preview') | to nuon) --headers ($headers | to nuon) --dry-run"}
                {label: generic, command: $"api request -m GET (($base + '/header-preview') | to nuon) --headers ($headers | to nuon) --dry-run"}
            ] {
                let preview = (run-command-process $root $surface.command)
                assert-safe-preview $preview $"($surface.label) password header ($case.name)" [$case.secret] [$"($case.name): ******" "X-Keep: exact"]
            }

            let request = {method: GET, url: $"($base)/direct-history-header", headers: $headers, body: null}
            let direct_id = (api history save $request $response)
            let direct_entry = (api history get $direct_id)
            assert equal ($direct_entry.request.headers | get $case.name) "******" $"direct save did not mask ($case.name)"
            assert equal $direct_entry.request.headers.X-Keep exact
            assert equal $direct_entry.request.headers_replayable false
            assert (not (($direct_entry | to nuon) | str contains $case.secret)) $"direct save persisted ($case.name)"
            $sensitive_header_ids = ($sensitive_header_ids | append $direct_id)
        }

        let saved_secret = "SAVED-X-PASSWORD-SENTINEL"
        let live_secret = "LIVE-X-PWD-SENTINEL"
        let live_before = (auth-history-ids)
        api get $"($base)/live-password-header" --headers {X-Pwd: $live_secret, X-Keep: exact} --raw | ignore
        let live_entry = (auth-new-history $live_before)
        assert equal $live_entry.request.headers.X-Pwd "******"
        assert equal $live_entry.request.headers.X-Keep exact
        assert equal $live_entry.request.headers_replayable false
        assert (not (($live_entry | to nuon) | str contains $live_secret))

        api request create password-header GET $"($base)/saved-password-header" --headers {X-Password: $saved_secret, X-Keep: exact} --collection default | ignore
        for surface in [
            {label: send, command: "api send password-header --collection default --dry-run"}
            {label: export, command: "api request export password-header --collection default"}
        ] {
            let preview = (run-command-process $root $surface.command)
            assert-safe-preview $preview $"($surface.label) password header" [$saved_secret] ["X-Password: ******" "X-Keep: exact"]
        }
        let saved_before = (auth-history-ids)
        api send password-header --collection default --raw | ignore
        let saved_entry = (auth-new-history $saved_before)
        assert equal $saved_entry.request.headers.X-Password "******"
        assert equal $saved_entry.request.headers_replayable false
        assert (not (($saved_entry | to nuon) | str contains $saved_secret))

        let response_secret = "RESPONSE-X-PWD-SENTINEL"
        let response_with_password = ($response | update headers {X-Pwd: $response_secret, X-Safe: exact})
        let response_id = (api history save {method: GET, url: $"($base)/response-password-header", headers: {}, body: null} $response_with_password)
        let response_entry = (api history get $response_id)
        assert equal $response_entry.response.headers.X-Pwd "******"
        assert equal $response_entry.response.headers.X-Safe exact
        assert (not (($response_entry | to nuon) | str contains $response_secret))

        for case in [
            {name: Password-Hint, value: exact-hint}
            {name: Bypass-Word, value: exact-bypass}
            {name: X-Pwd-Reset-Status, value: exact-reset}
            {name: Compass, value: exact-compass}
        ] {
            let headers = ({} | upsert $case.name $case.value)
            let preview = (run-command-process $root $"api get (($base + '/safe-header') | to nuon) --headers ($headers | to nuon) --dry-run")
            assert equal $preview.exit_code 0
            assert equal ($preview.stderr | str trim) ""
            assert ($preview.stdout | str contains $"($case.name): ($case.value)") $"safe header was masked: ($case.name)"
            let before_ids = (auth-history-ids)
            api get $"($base)/safe-header" --headers $headers --raw | ignore
            let entry = (auth-new-history $before_ids)
            assert equal ($entry.request.headers | get $case.name) $case.value $"safe header changed: ($case.name)"
            assert equal ($entry.request.headers_replayable? | default true) true $"safe header became non-replayable: ($case.name)"
        }

        let blocked_id = ($sensitive_header_ids | first)
        let wire_before = (command-error-wire-events $server | length)
        let blocked = (run-command-process $root $"api history resend ($blocked_id | to nuon) --raw")
        assert ($blocked.exit_code != 0)
        assert equal ($blocked.stdout | str trim) ""
        assert ($blocked.stderr | str contains "pass --headers")
        assert equal $blocked.stderr ($blocked.stderr | ansi strip)
        assert equal (command-error-wire-events $server | length) $wire_before "password mask was replayed"
        let replacement_before = (auth-history-ids)
        api history resend $blocked_id --headers {X-Keep: replacement} --raw | ignore
        assert equal (command-error-wire-events $server | length) ($wire_before + 1)
        let replacement_entry = (auth-new-history $replacement_before)
        assert equal $replacement_entry.request.headers.X-Keep replacement
        assert (not (($replacement_entry | to nuon) | str contains "******")) "replacement replay persisted a password mask"

        let managed_a = "MANAGED-PASSWORD-A-SENTINEL"
        let managed_b = "MANAGED-PASSWORD-B-SENTINEL"
        api auth apikey set managed-password $managed_a --query password | ignore
        api request create managed-password GET $"($base)/managed-password?existing=1#client-fragment" --auth {type: api_key, ref: managed-password} --collection default | ignore
        let managed_before = (auth-history-ids)
        api send managed-password --collection default --raw | ignore
        let managed_entry = (auth-new-history $managed_before)
        let managed_initial_wire = (command-error-wire-events $server | last)
        assert-query-auth-event $managed_initial_wire "/managed-password" "password" $managed_a
        assert-history-auth $managed_entry "api_key" "managed-password" [$managed_a $managed_b]
        api auth apikey set managed-password $managed_b --query password | ignore
        let rotation_before = (command-error-wire-events $server | length)
        let resend_before_ids = (auth-history-ids)
        api history resend $managed_entry.id --raw | ignore
        assert equal (command-error-wire-events $server | length) ($rotation_before + 1)
        assert-query-auth-event (command-error-wire-events $server | last) "/managed-password" "password" $managed_b
        assert-history-auth (auth-new-history $resend_before_ids) "api_key" "managed-password" [$managed_a $managed_b]
        for surface in [
            {label: direct, command: $"api get (($base + '/managed-password?existing=1#client-fragment') | to nuon) --auth {type: api_key, ref: managed-password} --dry-run"}
            {label: send, command: "api send managed-password --collection default --dry-run"}
            {label: export, command: "api request export managed-password --collection default"}
            {label: resend, command: $"api history resend ($managed_entry.id | to nuon) --dry-run"}
        ] {
            let preview = (run-command-process $root $surface.command)
            assert-safe-preview $preview $"managed password query ($surface.label)" [$managed_a $managed_b] ["existing=1&password=******#client-fragment"]
        }

        let json_export = ($root | path join "password-policy-history.json")
        let csv_export = ($root | path join "password-policy-history.csv")
        let public_readers = [
            "api history list | to nuon"
            "api history search password | to nuon"
            $"api history show ($saved_entry.id | to nuon) | to nuon"
            $"api history get ($saved_entry.id | to nuon) | to nuon"
            $"api history export --format json --output ($json_export | to nuon)"
            $"api history export --format csv --output ($csv_export | to nuon)"
        ]
        let forbidden = ($header_cases | get secret | append [$saved_secret $live_secret $response_secret $url_sentinel $managed_a $managed_b])
        for command in $public_readers {
            let result = (run-command-process $root $command)
            assert equal $result.exit_code 0 $"password history reader failed: ($command): ($result.stderr)"
            assert equal ($result.stderr | str trim) ""
            for secret in $forbidden {
                assert (not ($result.stdout | str contains $secret)) $"password history reader exposed a value: ($command)"
            }
        }
        let index_bytes = (open ($root | path join "history" "index.nuon") --raw)
        let export_bytes = $"(open $json_export --raw)\n(open $csv_export --raw)"
        let history_bytes = (
            command-error-snapshot ($root | path join "history")
            | where type == file
            | get content
            | compact
            | str join "\n"
        )
        for secret in $forbidden {
            assert (not ($index_bytes | str contains $secret)) "password policy index exposed a value"
            assert (not ($export_bytes | str contains $secret)) "password policy export exposed a value"
            assert (not ($history_bytes | str contains $secret)) "password policy raw history exposed a value"
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
            {label: "get basic", command: $"api get (($base + '/direct-basic') | to nuon) -a {type: basic, creds_ref: preview-basic} --dry-run", expected: ["-u '******:******'"]}
            {label: "post API-key header", command: $"api post (($base + '/direct-header') | to nuon) -b {ok: true} -a {type: api_key, key_ref: preview-header} --dry-run", expected: ["X.Nurl+Key: ******"]}
            {label: "put API-key query", command: $"api put (($base + '/direct-query?existing=1#frag') | to nuon) -b {ok: true} -a {type: api_key, ref: preview-query} --dry-run", expected: ["existing=1&api%26key%3D%23%25%2B%20space%E4%B8%96%E7%95%8C~._-=******#frag"]}
            {label: "patch OAuth", command: $"api patch (($base + '/direct-oauth') | to nuon) -b {ok: true} -a {type: oauth2, ref: preview-oauth} --dry-run", expected: ["Authorization: ******"]}
            {label: "delete inline bearer", command: $"api delete (($base + '/inline-bearer') | to nuon) -a {type: bearer, token: 'PREVIEW-BEARER-SENTINEL'} --dry-run", expected: ["Authorization: ******"]}
            {label: "head inline basic", command: $"api head (($base + '/inline-basic') | to nuon) -a {type: basic, username: user, password: 'PREVIEW-BASIC-SENTINEL'} --dry-run", expected: ["-u '******:******'"]}
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

def test-saml-auth-execution-replay-and-saved-put [] {
    let root = (make-temp-dir "saml-auth")
    let infra = (make-temp-dir "saml-auth-server")
    let server = (auth-test-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let base = $"http://127.0.0.1:($server.port)"
        let scheme = "http://schemas.microsoft.com/dsts/saml2-bearer"
        let token_a = "SAML-NAMED-A-SENTINEL"
        let token_b = "SAML-NAMED-B-SENTINEL"
        let override_token = "SAML-OVERRIDE-SENTINEL"
        let inline_token = "SAML-INLINE-SENTINEL"
        let variable_token = "SAML-VARIABLE-MUST-NOT-WIN"
        let environment_token = "SAML-ENVIRONMENT-MUST-NOT-WIN"
        let bearer_token = "BEARER-SAME-NAME-SENTINEL"
        let secrets = [$token_a $token_b $override_token $inline_token $bearer_token]
        let non_wire_values = [$variable_token $environment_token]

        api auth bearer set samltoken $bearer_token | ignore
        api auth saml set samltoken $token_a | ignore
        api auth saml set saml-override $override_token | ignore
        assert equal (api auth saml get samltoken) $token_a
        assert equal ((api auth list | where name == samltoken | get type | sort)) ["bearer" "saml"]
        let shown = (api auth show --full | where name == samltoken and type == saml | first)
        assert equal $shown {name: samltoken, type: saml, status: configured, value: $token_a}
        let masked = (api auth show | where name == samltoken and type == saml | first)
        assert equal $masked {name: samltoken, type: saml, status: configured, value: "******"}

        let before_generic = (auth-history-ids)
        let generic = (api request -m GET $"($base)/saml-generic" --auth {type: "SaMl", token_ref: samltoken} --raw)
        assert equal $generic.response.status 200
        assert (not (($generic | to nuon) | str contains $token_a))
        assert (not (($generic | to nuon) | str contains $scheme))
        assert equal (command-error-wire-events $server | where path == "/saml-generic" | first | get authorization) $"($scheme) ($token_a)"
        let named_history = (auth-new-history $before_generic)
        assert-history-auth $named_history "saml" "samltoken" $secrets

        api auth saml set samltoken $token_b | ignore
        let before_replay = (auth-history-ids)
        api history resend $named_history.id --raw | ignore
        assert equal (command-error-wire-events $server | where path == "/saml-generic" | last | get authorization) $"($scheme) ($token_b)"
        assert-history-auth (auth-new-history $before_replay) "saml" "samltoken" $secrets

        let before_override = (auth-history-ids)
        api history resend $named_history.id --auth {type: saml, ref: saml-override} --raw | ignore
        assert equal (command-error-wire-events $server | where path == "/saml-generic" | last | get authorization) $"($scheme) ($override_token)"
        assert-history-auth (auth-new-history $before_override) "saml" "saml-override" $secrets

        let binary_path = ($root | path join "saml-response.bin")
        api get $"($base)/saml-binary" --auth {type: saml, ref: samltoken} --binary-save $binary_path --output none --no-history
        assert ($binary_path | path exists)
        assert equal (command-error-wire-events $server | where path == "/saml-binary" | first | get authorization) $"($scheme) ($token_b)"

        let before_chain = (auth-history-ids)
        api chain run ([{
            method: GET
            url: $"($base)/saml-chain"
            auth: {type: saml, ref: samltoken}
        }]) --quiet | ignore
        assert equal (command-error-wire-events $server | where path == "/saml-chain" | first | get authorization) $"($scheme) ($token_b)"
        assert-history-auth (auth-new-history $before_chain) "saml" "samltoken" $secrets

        api collection create saml-saved | ignore
        api vars set base_url $"($base)/global-must-not-win" | ignore
        api vars set fault_id 1 | ignore
        api vars set fault_name global-default | ignore
        api collection env create saml-saved active --activate | ignore
        api collection env set saml-saved base_url $"($base)/environment" | ignore
        api collection env set saml-saved fault_id 2 | ignore
        api collection env set saml-saved fault_name environment-default | ignore
        api collection env set saml-saved samltoken $environment_token | ignore
        let template_url = "{{base_url}}/fault-plans/{{fault_id}}"
        let template_body = {fault: "{{fault_name}}", enabled: true}
        let saved_auth = {type: saml, token_ref: samltoken}
        api request create RegisterFaultPlan PUT $template_url --body $template_body --auth $saved_auth --collection saml-saved | ignore
        let saved = (api request show RegisterFaultPlan --collection saml-saved)
        assert equal $saved.method "PUT"
        assert equal $saved.url $template_url
        assert equal $saved.body.content $template_body
        assert equal $saved.auth $saved_auth

        let before_saved = (auth-history-ids)
        let saved_result = (api send RegisterFaultPlan --collection saml-saved --vars {
            fault_id: 42
            fault_name: planned
            samltoken: $variable_token
        } --raw)
        assert equal $saved_result.request.method "PUT"
        assert equal $saved_result.request.url $"($base)/environment/fault-plans/42"
        assert equal $saved_result.request.body {fault: planned, enabled: true}
        let saved_wire = (command-error-wire-events $server | where path == "/environment/fault-plans/42" | first)
        assert equal $saved_wire.authorization $"($scheme) ($token_b)"
        assert-history-auth (auth-new-history $before_saved) "saml" "samltoken" $secrets

        api send RegisterFaultPlan --collection saml-saved --vars {fault_id: 44, fault_name: override} --auth {type: saml, ref: saml-override} --output none --no-history
        assert equal (command-error-wire-events $server | where path == "/environment/fault-plans/44" | first | get authorization) $"($scheme) ($override_token)"

        let text_output = ($root | path join "saml-dry-run.txt")
        let binary_output = ($root | path join "saml-dry-run.bin")
        "TEXT-UNCHANGED" | save $text_output
        "BINARY-UNCHANGED" | save $binary_output
        let preview_before = (command-error-snapshot $root)
        let preview_wire_before = (command-error-wire-events $server | length)
        let preview_cases = [
            {
                label: "generic SAML dry-run"
                command: $"api request -m PUT (($base + '/saml-preview') | to nuon) --body {ok: true} --auth {type: saml, ref: samltoken} --save ($text_output | to nuon) --binary-save ($binary_output | to nuon) --dry-run"
                expected: ["-X PUT" "/saml-preview" '"ok":true']
            }
            {
                label: "saved SAML dry-run"
                command: "api send RegisterFaultPlan --collection saml-saved --vars {fault_id: 43, fault_name: preview} --dry-run"
                expected: ["-X PUT" "/environment/fault-plans/43" '"fault":"preview"' '"enabled":true']
            }
            {
                label: "saved SAML export"
                command: "api request export RegisterFaultPlan --collection saml-saved"
                expected: ["-X PUT" "/environment/fault-plans/2" '"fault":"environment-default"' '"enabled":true']
            }
            {
                label: "history SAML dry-run"
                command: $"api history resend ($named_history.id | to nuon) --dry-run"
                expected: ["/saml-generic"]
            }
        ]
        for case in $preview_cases {
            let preview = (run-command-process $root $case.command)
            assert-safe-preview $preview $case.label ($secrets | append $non_wire_values) (["Authorization: ******"] | append $case.expected)
            assert (not ($preview.stdout | str contains $scheme)) $"($case.label) exposed the SAML scheme"
        }
        assert equal (command-error-snapshot $root) $preview_before "SAML previews mutated workspace state"
        assert equal (command-error-wire-events $server | length) $preview_wire_before "SAML previews reached the server"
        assert equal (open $text_output --raw) "TEXT-UNCHANGED"
        assert equal (open $binary_output --raw) "BINARY-UNCHANGED"

        let before_inline = (auth-history-ids)
        api post $"($base)/saml-inline" --body {ok: true} --auth {type: saml, token: $inline_token} --raw | ignore
        assert equal (command-error-wire-events $server | where path == "/saml-inline" | first | get authorization) $"($scheme) ($inline_token)"
        let inline_history = (auth-new-history $before_inline)
        assert equal $inline_history.request.auth {type: saml, replayable: false}
        assert (not (($inline_history | to nuon) | str contains $inline_token))

        let rejected_before = (command-error-snapshot $root)
        let rejected_wire_before = (command-error-wire-events $server | length)
        let rejected = (run-command-process $root $"api history resend ($inline_history.id | to nuon) --raw")
        assert ($rejected.exit_code != 0)
        assert equal ($rejected.stdout | str trim) ""
        assert ($rejected.stderr | str contains "pass --auth")
        assert equal $rejected.stderr ($rejected.stderr | ansi strip)
        assert (not ($rejected.stderr | str contains $inline_token))
        assert equal (command-error-snapshot $root) $rejected_before
        assert equal (command-error-wire-events $server | length) $rejected_wire_before
        api history resend $inline_history.id --auth {type: saml, ref: saml-override} --raw | ignore
        assert equal (command-error-wire-events $server | where path == "/saml-inline" | last | get authorization) $"($scheme) ($override_token)"

        let output_auth = {type: saml, ref: samltoken}
        assert equal (api get $"($base)/saml-status" --auth $output_auth --output status --no-history) 200
        assert equal (api get $"($base)/saml-body" --auth $output_auth --output body --no-history) {ok: true}
        assert ((api get $"($base)/saml-headers" --auth $output_auth --output headers --no-history | describe) | str starts-with "record")
        assert equal (api get $"($base)/saml-select" --auth $output_auth --select status --no-history) 200
        let raw_output = (api get $"($base)/saml-raw" --auth $output_auth --output raw --no-history)
        assert (not ($raw_output | str contains $token_b))
        let json_output = (api get $"($base)/saml-json" --auth $output_auth --output json --no-history)
        assert (not ($json_output | str contains $token_b))
        assert (not ($json_output | str contains $scheme))
        api get $"($base)/saml-none" --auth $output_auth --output none --no-history
        for case in [
            {label: default, options: ""}
            {label: verbose, options: "--verbose"}
            {label: debug, options: "--debug"}
        ] {
            let rendered = (run-command-process $root $"api get (($base + '/saml-' + $case.label) | to nuon) --auth {type: saml, ref: samltoken} --no-history ($case.options)")
            assert equal $rendered.exit_code 0 $"SAML ($case.label) output failed: ($rendered.stderr)"
            assert equal ($rendered.stderr | str trim) ""
            assert (not ($"($rendered.stdout)\n($rendered.stderr)" | str contains $token_b))
        }

        let json_export = ($root | path join "saml-history.json")
        let csv_export = ($root | path join "saml-history.csv")
        api history export --format json --output $json_export | ignore
        api history export --format csv --output $csv_export | ignore
        let json_bytes = (open $json_export --raw)
        let csv_bytes = (open $csv_export --raw)
        assert ($json_bytes | str contains '"type": "saml"')
        assert ($json_bytes | str contains '"replayable": true')
        assert equal ($csv_bytes | lines | first) "id,timestamp,method,url,status,time_ms"
        for value in ($secrets | append $non_wire_values) {
            assert (not ($json_bytes | str contains $value))
            assert (not ($csv_bytes | str contains $value))
        }
        let history_readers = [
            $"api history get ($named_history.id | to nuon) | get request.auth | to json --raw"
            $"api history show ($named_history.id | to nuon) | to nuon"
            "api history list | to nuon"
            "api history search saml | to nuon"
        ]
        for command in $history_readers {
            let reader = (run-command-process $root $command)
            assert equal $reader.exit_code 0 $"SAML history reader failed: ($reader.stderr)"
            assert equal ($reader.stderr | str trim) ""
            for secret in $secrets {
                assert (not ($reader.stdout | str contains $secret)) "SAML history reader exposed a credential"
            }
            assert (not ($reader.stdout | str contains $scheme)) "SAML history reader exposed the wire scheme"
        }
        let canonical_auth = (run-command-process $root $"api history get ($named_history.id | to nuon) | get request.auth | to json --raw")
        assert equal ($canonical_auth.stdout | str trim | from json) {type: saml, ref: samltoken, replayable: true}
        let rebuild = (run-command-process $root "api history rebuild-index | ignore")
        assert equal $rebuild.exit_code 0 $"SAML history index rebuild failed: ($rebuild.stderr)"
        assert equal ($rebuild.stderr | str trim) ""
        let index_bytes = (open ($root | path join "history" "index.nuon") --raw)
        for secret in $secrets {
            assert (not ($index_bytes | str contains $secret)) "SAML history index exposed a credential"
        }
        assert (not ($index_bytes | str contains $scheme)) "SAML history index exposed the wire scheme"
        let public_state = (
            command-error-snapshot $root
            | where {|entry| not ($entry.path | str ends-with "secrets.nuon") }
            | get content
            | compact
            | str join "\n"
        )
        for secret in $secrets {
            assert (not ($public_state | str contains $secret)) "SAML credential escaped the secret store"
        }
        let saml_wire_events = (command-error-wire-events $server | where {|event| $event.authorization | str starts-with $scheme })
        assert (($saml_wire_events | length) >= 10) "SAML wire-cardinality check did not observe the exercised request paths"
        for event in $saml_wire_events {
            assert equal ($event.authorization_count | into int) 1 $"SAML request emitted duplicate Authorization headers: ($event.path)"
        }
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def test-saml-store-migration-vars-and-invalid-inputs [] {
    let root = (make-temp-dir "saml-store")
    let infra = (make-temp-dir "saml-store-server")
    let server = (auth-test-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        mkdir $root
        let base = $"http://127.0.0.1:($server.port)"
        let secrets_path = ($root | path join "secrets.nuon")
        {
            tokens: {legacy-bearer: {bearer: legacy}}
            oauth: {}
            api_keys: {}
            basic_auth: {}
            unknown_bucket: {preserve: exact}
        } | to nuon --indent 4 | save $secrets_path
        api init | ignore
        let legacy_bytes = (open $secrets_path --raw)

        api auth list | ignore
        api auth show | ignore
        api vars list --include-secrets | ignore
        assert equal (open $secrets_path --raw) $legacy_bytes "legacy secret reads rewrote the store"

        api auth bearer set second-bearer second | ignore
        let after_bearer = (open $secrets_path)
        assert ("saml_tokens" not-in ($after_bearer | columns)) "non-SAML mutation eagerly added the SAML bucket"
        assert equal $after_bearer.unknown_bucket {preserve: exact}
        assert equal $after_bearer.tokens.legacy-bearer.bearer legacy

        let valid_token = "SAML-STORE-VALID-SENTINEL"
        api auth saml set legacy-saml $valid_token | ignore
        let migrated = (open $secrets_path)
        assert equal $migrated.saml_tokens.legacy-saml.token $valid_token
        assert equal $migrated.unknown_bucket {preserve: exact}
        assert equal $migrated.tokens.legacy-bearer.bearer legacy
        assert equal (api auth saml get legacy-saml) $valid_token
        assert equal (api auth list | where name == legacy-saml | first) {name: legacy-saml, type: saml}
        assert equal (api auth show --full | where name == legacy-saml | first) {name: legacy-saml, type: saml, status: configured, value: $valid_token}

        let secret_vars = (api vars list --include-secrets --full | where name == "{{saml_token_legacy-saml}}")
        assert equal ($secret_vars | length) 1
        assert equal ($secret_vars | first | get value) "***"
        assert equal ($secret_vars | first | get type) "secret"
        assert equal (api vars interpolate "{{saml_token_legacy-saml}}") "{{saml_token_legacy-saml}}"
        assert ("saml_token_legacy-saml" not-in (api vars get-merged | columns))

        api auth saml delete legacy-saml | ignore
        assert equal (api auth saml get legacy-saml) null
        let missing_delete = (run-command-process $root "api auth saml delete legacy-saml")
        assert equal $missing_delete.exit_code 0
        assert ($missing_delete.stdout | str contains "not found")

        api auth saml set deleted-saml deleted | ignore
        api auth saml delete deleted-saml | ignore
        api auth saml set valid-saml $valid_token | ignore
        let malformed = (
            open $secrets_path
            | update saml_tokens (
                $in.saml_tokens
                | upsert malformed-saml {token: 42}
                | upsert malformed-record-saml 42
                | upsert missing-token-saml {}
                | upsert empty-saml {token: ""}
                | upsert crlf-saml {token: "MALFORMED\r\nTOKEN"}
                | upsert scheme-only-saml {token: "http://schemas.microsoft.com/dsts/saml2-bearer"}
                | upsert prefixed-saml {token: "http://schemas.microsoft.com/dsts/saml2-bearer PREFIXED"}
            )
        )
        $malformed | to nuon --indent 4 | save -f $secrets_path

        api collection create invalid-saml | ignore
        api request create deleted-saved GET $"($base)/deleted-saved" --collection invalid-saml --auth {type: saml, token_ref: deleted-saml} | ignore
        assert equal (api request show deleted-saved --collection invalid-saml | get auth) {type: saml, token_ref: deleted-saml}

        let output_path = ($root | path join "saml-invalid.bin")
        "OUTPUT-UNCHANGED" | save $output_path
        let crlf_ref = "bad\r\nref"
        let crlf_token = "INLINE\r\nSENTINEL"
        let scheme_only_token = "http://schemas.microsoft.com/dsts/saml2-bearer"
        let prefixed_token = "http://schemas.microsoft.com/dsts/saml2-bearer INLINE-PREFIXED-SENTINEL"
        let leading_prefixed_token = "  http://schemas.microsoft.com/dsts/saml2-bearer INLINE-LEADING-PREFIXED-SENTINEL"
        let cases = [
            {
                label: "missing SAML ref"
                command: $"api request -m GET (($base + '/missing') | to nuon) --auth {type: saml, ref: missing-saml} --output none"
                expected: "SAML token 'missing-saml' not found"
            }
            {
                label: "deleted saved SAML ref"
                command: "api send deleted-saved --collection invalid-saml --output none"
                expected: "SAML token 'deleted-saml' not found"
            }
            {
                label: "malformed SAML ref"
                command: $"api get (($base + '/malformed') | to nuon) --auth {type: saml, ref: malformed-saml} --binary-save ($output_path | to nuon) --output none"
                expected: "SAML token 'malformed-saml' is malformed"
            }
            {
                label: "malformed SAML get"
                command: "api auth saml get malformed-saml"
                expected: "SAML token 'malformed-saml' is malformed"
            }
            {
                label: "non-record SAML get"
                command: "api auth saml get malformed-record-saml"
                expected: "SAML token 'malformed-record-saml' is malformed"
            }
            {
                label: "missing-token SAML record"
                command: $"api get (($base + '/missing-token-record') | to nuon) --auth {type: saml, ref: missing-token-saml} --output none"
                expected: "SAML token 'missing-token-saml' is malformed"
            }
            {
                label: "empty stored SAML token"
                command: $"api get (($base + '/empty-stored') | to nuon) --auth {type: saml, ref: empty-saml} --output none"
                expected: "SAML token 'empty-saml' is malformed"
            }
            {
                label: "CRLF stored SAML token"
                command: $"api get (($base + '/crlf') | to nuon) --auth {type: saml, ref: crlf-saml} --output none"
                expected: "SAML token 'crlf-saml' is malformed"
            }
            {
                label: "scheme-only stored SAML token"
                command: $"api get (($base + '/scheme-only-stored') | to nuon) --auth {type: saml, ref: scheme-only-saml} --output none"
                expected: "SAML token 'scheme-only-saml' is malformed"
            }
            {
                label: "prefixed stored SAML token"
                command: $"api get (($base + '/prefixed') | to nuon) --auth {type: saml, ref: prefixed-saml} --output none"
                expected: "SAML token 'prefixed-saml' is malformed"
            }
            {
                label: "empty SAML ref"
                command: $"api get (($base + '/empty-ref') | to nuon) --auth {type: saml, ref: ''} --output none"
                expected: "SAML token reference must be a non-empty string"
            }
            {
                label: "non-string SAML ref"
                command: $"api chain run ([{method: GET, url: (($base + '/nonstring-ref') | to nuon), auth: {type: saml, ref: 42}}]) --quiet | ignore"
                expected: "SAML token reference must be a non-empty string"
            }
            {
                label: "CRLF SAML ref"
                command: $"api get (($base + '/crlf-ref') | to nuon) --auth ({type: saml, ref: $crlf_ref} | to nuon) --dry-run"
                expected: "SAML token reference must be a non-empty string"
            }
            {
                label: "empty inline SAML token"
                command: $"api get (($base + '/empty-token') | to nuon) --auth {type: saml, token: ''} --output none"
                expected: "SAML token must be a non-empty string"
            }
            {
                label: "non-string inline SAML token"
                command: $"api get (($base + '/nonstring-token') | to nuon) --auth {type: saml, token: 42} --output none"
                expected: "SAML token must be a non-empty string"
            }
            {
                label: "CRLF inline SAML token"
                command: $"api get (($base + '/crlf-token') | to nuon) --auth ({type: saml, token: $crlf_token} | to nuon) --output none"
                expected: "SAML token must not contain CR or LF"
            }
            {
                label: "scheme-only inline SAML token"
                command: $"api get (($base + '/scheme-only-token') | to nuon) --auth ({type: saml, token: $scheme_only_token} | to nuon) --output none"
                expected: "SAML token must be a bare token"
            }
            {
                label: "prefixed inline SAML token"
                command: $"api get (($base + '/prefixed-token') | to nuon) --auth ({type: saml, token: $prefixed_token} | to nuon) --output none"
                expected: "SAML token must be a bare token"
            }
            {
                label: "leading-space prefixed inline SAML token"
                command: $"api get (($base + '/leading-prefixed-token') | to nuon) --auth ({type: saml, token: $leading_prefixed_token} | to nuon) --output none"
                expected: "SAML token must be a bare token"
            }
            {
                label: "non-string SAML set reference"
                command: $"api auth saml set 42 ($valid_token | to nuon)"
                expected: "SAML token reference must be a non-empty string"
            }
            {
                label: "empty SAML set reference"
                command: $"api auth saml set '' ($valid_token | to nuon)"
                expected: "SAML token reference must be a non-empty string"
            }
            {
                label: "CRLF SAML get reference"
                command: $"api auth saml get ($crlf_ref | to nuon)"
                expected: "SAML token reference must be a non-empty string"
            }
            {
                label: "non-string SAML delete reference"
                command: "api auth saml delete 42"
                expected: "SAML token reference must be a non-empty string"
            }
            {
                label: "non-string SAML set"
                command: "api auth saml set invalid-set 42"
                expected: "SAML token must be a non-empty string"
            }
            {
                label: "empty SAML set"
                command: "api auth saml set invalid-set ''"
                expected: "SAML token must be a non-empty string"
            }
            {
                label: "CRLF SAML set"
                command: $"api auth saml set invalid-set ($crlf_token | to nuon)"
                expected: "SAML token must not contain CR or LF"
            }
            {
                label: "scheme-only SAML set"
                command: $"api auth saml set invalid-set ($scheme_only_token | to nuon)"
                expected: "SAML token must be a bare token"
            }
            {
                label: "prefixed SAML set"
                command: $"api auth saml set invalid-set ($leading_prefixed_token | to nuon)"
                expected: "SAML token must be a bare token"
            }
        ]

        let invalid_wire_before = (command-error-wire-events $server | length)
        let invalid_history_before = (auth-history-count)
        for case in $cases {
            let before = (command-error-snapshot $root)
            let result = (run-command-process $root $case.command)
            assert equal $result.exit_code 1 $"($case.label) returned the wrong failure exit code"
            assert equal ($result.stdout | str trim) "" $"($case.label) wrote stdout"
            assert ($result.stderr | str contains $case.expected) $"($case.label) omitted its safe error: ($result.stderr)"
            assert equal $result.stderr ($result.stderr | ansi strip) $"($case.label) emitted ANSI"
            for secret in [$valid_token $crlf_token $scheme_only_token $prefixed_token $leading_prefixed_token] {
                assert (not ($"($result.stdout)\n($result.stderr)" | str contains $secret)) $"($case.label) exposed a token"
            }
            assert equal (command-error-snapshot $root) $before $"($case.label) mutated workspace state"
        }
        assert equal (command-error-wire-events $server | length) $invalid_wire_before
        assert equal (auth-history-count) $invalid_history_before
        assert equal (open $output_path --raw) "OUTPUT-UNCHANGED"

        let transport_save_path = ($root | path join "saml-transport-save.txt")
        "TRANSPORT-SAVE-UNCHANGED" | save $transport_save_path
        let transport_before = (command-error-snapshot $root)
        let transport = (run-command-process $root $"api get 'http://127.0.0.1:1/transport-failure' --auth {type: saml, ref: valid-saml} --save ($transport_save_path | to nuon) --binary-save ($output_path | to nuon) --output none --no-history --debug")
        assert equal $transport.exit_code 1
        assert equal ($transport.stdout | str trim) ""
        assert equal $transport.stderr ($transport.stderr | ansi strip)
        assert (not ($"($transport.stdout)\n($transport.stderr)" | str contains $valid_token))
        assert equal (command-error-snapshot $root) $transport_before
        assert equal (open $transport_save_path --raw) "TRANSPORT-SAVE-UNCHANGED"
        assert equal (open $output_path --raw) "OUTPUT-UNCHANGED"
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
        (run-test "credential-bearing URLs fail before auth, network, output, or history side effects" { test-secret-bearing-urls-fail-preflight })
        (run-test "password URL, header, and managed query aliases share one exact safety policy" { test-password-credential-name-policy })
        (run-test "legacy history replays while missing, deleted, malformed, and unknown auth fail safely" { test-legacy-and-invalid-auth-history })
        (run-test "dry-run, send, export, and history previews mask all supported auth" { test-auth-preview-and-export-secrecy })
        (run-test "OAuth provider errors expose only stable safe codes across request surfaces" { test-oauth-provider-errors-are-secret-safe })
        (run-test "authenticated output modes preserve types and never expose auth" { test-authenticated-output-contracts })
        (run-test "SAML exact wire auth, saved PUT, rotation, replay, binary, chain, and previews stay consistent" { test-saml-auth-execution-replay-and-saved-put })
        (run-test "SAML legacy stores, masked vars, invalid inputs, and failures remain atomic" { test-saml-store-migration-vars-and-invalid-inputs })
    ]
}
