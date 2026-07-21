# Live response and interpolation boundary regressions for credential safety.

def boundary-response-secrets [] {
    [
        "RESPONSE-PASSWORD-SENTINEL"
        "RESPONSE-PASSWD-SENTINEL"
        "RESPONSE-PWD-SENTINEL"
        "RESPONSE-X-PASSWORD-SENTINEL"
        "RESPONSE-X-PASSWD-SENTINEL"
        "RESPONSE-X-PWD-SENTINEL"
    ]
}

def assert-boundary-no-values [text: string, values: list<string>, label: string] {
    for value in $values {
        assert (not ($text | str contains $value)) $"($label) exposed a credential value"
    }
}

def assert-boundary-process [
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
    assert-boundary-no-values $"($result.stdout)\n($result.stderr)" $secrets $label
}

def assert-boundary-failure [
    result: record
    label: string
    expected: string
    secret: string
] {
    assert ($result.exit_code != 0) $"($label) unexpectedly succeeded"
    assert equal ($result.stdout | str trim) "" $"($label) wrote stdout"
    assert ($result.stderr | str contains $expected) $"($label) omitted '($expected)': ($result.stderr)"
    assert equal $result.stderr ($result.stderr | ansi strip) $"($label) stderr contained ANSI"
    assert (not ($result.stderr | str contains $secret)) $"($label) exposed its URL value"
}

def boundary-history-bytes [root: string] {
    let history = ($root | path join "history")
    if not ($history | path exists) {
        return ""
    }
    command-error-snapshot $history | get content | compact | str join "\n"
}

def boundary-record-list-nuon [records: list] {
    $"[($records | each {|record| $record | to nuon } | str join ', ')]"
}

def boundary-nonhistory-snapshot [root: string] {
    command-error-snapshot $root
    | where {|entry| not ($entry.path | str starts-with "history/") }
}

def boundary-history-entries [root: string] {
    $env.API_ROOT = $root
    let index_path = ($root | path join "history" "index.nuon")
    if not ($index_path | path exists) {
        return []
    }
    open $index_path | each {|indexed| api history get $indexed.id }
}

def assert-boundary-masked-headers [headers: record, secrets: list<string>] {
    for name in ["Password" "Passwd" "Pwd" "X-Password" "X-Passwd" "X-Pwd"] {
        assert equal ($headers | get $name) "******" $"response header ($name) was not masked"
    }
    assert equal ($headers | get "Password-Hint") "safe-password-hint"
    assert equal ($headers | get "X-Pwd-Reset-Status") "safe-pwd-reset"
    assert equal ($headers | get "Bypass-Word") "safe-bypass-word"
    assert equal ($headers | get "X-Control-Header") "exact-control-value"
    assert-boundary-no-values ($headers | to nuon) $secrets "response headers"
}

def with-boundary-server [prefix: string, test: closure] {
    let root = (make-temp-dir $"boundary-($prefix)")
    let infra = (make-temp-dir $"boundary-($prefix)-server")
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
        do $test $root $infra $started.server
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

def test-live-response-header-output-contracts [] {
    with-boundary-server "response-output" {|root, infra, server|
        $env.API_ROOT = $root
        api init | ignore
        let url = $"http://127.0.0.1:($server.port)/password-response-headers"
        let secrets = (boundary-response-secrets)
        let before = (boundary-nonhistory-snapshot $root)

        let raw = (api get $url --raw)
        assert equal ($raw | columns) ["request" "response" "timestamp"]
        assert equal $raw.response.status 200
        assert equal $raw.response.body {ok: true}
        assert-boundary-masked-headers $raw.response.headers $secrets
        assert-boundary-no-values ($raw | to nuon) $secrets "raw response"

        let headers = (api get $url --output headers --no-history)
        assert ($headers | describe | str starts-with "record") "--output headers changed type"
        assert-boundary-masked-headers $headers $secrets
        let json = (api get $url --output json --no-history)
        assert equal ($json | describe) "string"
        assert-boundary-masked-headers (($json | from json).response.headers) $secrets
        assert equal (api get $url --output body --no-history) {ok: true}
        assert equal (api get $url --output status --no-history) 200
        assert equal (api get $url --select "headers.Password" --no-history) "******"
        assert equal (api get $url --select "headers.X-Control-Header" --no-history) "exact-control-value"
        assert ((api get $url --output none --no-history) == null)

        let commands = [
            {label: default, command: $"api get ($url | to nuon) --no-history", expected: ["200" "ok"]}
            {label: verbose, command: $"api get ($url | to nuon) --no-history --verbose", expected: ["< Password: ******" "< X-Control-Header: exact-control-value"]}
            {label: include, command: $"api get ($url | to nuon) --no-history --include", expected: ["< X-Pwd: ******" "< Password-Hint: safe-password-hint"]}
            {label: raw, command: $"api get ($url | to nuon) --no-history --raw | to nuon", expected: ["Password: ******" "X-Control-Header: exact-control-value"]}
            {label: headers, command: $"api get ($url | to nuon) --no-history --output headers | to nuon", expected: ["X-Passwd: ******" "Bypass-Word: safe-bypass-word"]}
            {label: json, command: $"api get ($url | to nuon) --no-history --output json", expected: ["\"Password\": \"******\"" "\"X-Control-Header\": \"exact-control-value\""]}
            {label: body, command: $"api get ($url | to nuon) --no-history --output body | to nuon", expected: ["ok: true"]}
            {label: status, command: $"api get ($url | to nuon) --no-history --output status", expected: ["200"]}
            {label: select, command: $"api get ($url | to nuon) --no-history --select 'headers.X-Pwd'", expected: ["******"]}
        ]
        for case in $commands {
            let result = (run-command-process $root $case.command)
            let human = ($case.label in ["default" "verbose" "include"])
            assert-boundary-process $result $"response ($case.label)" $secrets --allow-ansi=$human
            let stdout = ($result.stdout | ansi strip)
            for expected in $case.expected {
                assert ($stdout | str contains $expected) $"response ($case.label) omitted ($expected)"
            }
        }
        let none = (run-command-process $root $"api get ($url | to nuon) --no-history --output none")
        assert-boundary-process $none "response none" $secrets
        assert equal ($none.stdout | str trim) ""
        assert equal (boundary-nonhistory-snapshot $root) $before "response rendering mutated unrelated state"
    }
}

def test-live-response-header-history-surfaces [] {
    with-boundary-server "response-history" {|root, infra, server|
        $env.API_ROOT = $root
        api init | ignore
        let url = $"http://127.0.0.1:($server.port)/password-response-headers"
        let secrets = (boundary-response-secrets)
        let before = (boundary-nonhistory-snapshot $root)
        api get $url --raw | ignore
        let entries = (boundary-history-entries $root)
        assert equal ($entries | length) 1
        let entry = ($entries | first)
        assert-boundary-masked-headers $entry.response.headers $secrets
        assert equal $entry.request.headers.Content-Type "application/json"
        assert equal $entry.request.headers.Accept "application/json"
        assert (not (($entry.request.headers | values) | any {|value| $value == "******" }))
        assert ("headers_replayable" not-in ($entry.request | columns)) "response masks affected request replay"

        let index_path = ($root | path join "history" "index.nuon")
        let history_bytes = (boundary-history-bytes $root)
        assert-boundary-no-values $history_bytes $secrets "history bytes"
        assert-boundary-no-values (open $index_path --raw) $secrets "history index"
        assert-boundary-no-values ((api history get $entry.id) | to nuon) $secrets "history get"
        assert-boundary-no-values ((api history show $entry.id) | to nuon) $secrets "history show"
        assert-boundary-no-values ((api history list --limit 20) | to nuon) $secrets "history list"
        assert-boundary-no-values ((api history search "password-response-headers") | to nuon) $secrets "history search"

        let json_path = ($infra | path join "history.json")
        let csv_path = ($infra | path join "history.csv")
        api history export --format json --output $json_path | ignore
        api history export --format csv --output $csv_path | ignore
        assert-boundary-no-values (open $json_path --raw) $secrets "history JSON export"
        assert-boundary-no-values (open $csv_path --raw) $secrets "history CSV export"
        assert ((open $json_path --raw) | str contains "\"Password\": \"******\"")
        assert (not ($history_bytes | str contains "headers_replayable: false")) "response masks became request replay metadata"
        assert equal (boundary-nonhistory-snapshot $root) $before "history read/export mutated unrelated state"
    }
}

def configure-interpolation-workspace [root: string, base: string] {
    $env.API_ROOT = $root
    api init | ignore
    api collection create interp | ignore
    api collection env create interp active --activate | ignore
    for variable in [
        {name: base_url, value: $"($base)/global"}
        {name: route, value: global-route}
        {name: source, value: global-source}
        {name: trace, value: global-trace}
        {name: password_value, value: GLOBAL-HEADER-PASSWORD-SENTINEL}
    ] {
        api vars set $variable.name $variable.value | ignore
    }
    for variable in [
        {name: base_url, value: $"($base)/env"}
        {name: route, value: env-route}
        {name: source, value: env-source}
        {name: trace, value: env-trace}
        {name: password_value, value: ENV-HEADER-PASSWORD-SENTINEL}
    ] {
        api collection env set interp $variable.name $variable.value | ignore
    }
    api request create interpolated GET "{{base_url}}/{{route}}?source={{source}}" --collection interp --headers {
        X-Safe-Trace: "{{trace}}"
        X-Password: "{{password_value}}"
    } | ignore
}

def test-interpolated-header-precedence-and-history [] {
    with-boundary-server "interpolation-safe" {|root, infra, server|
        let base = $"http://127.0.0.1:($server.port)"
        configure-interpolation-workspace $root $base
        let global_secret = "GLOBAL-HEADER-PASSWORD-SENTINEL"
        let env_secret = "ENV-HEADER-PASSWORD-SENTINEL"
        let extra_secret = "EXTRA-HEADER-PASSWORD-SENTINEL"
        let chain_secret = "CHAIN-HEADER-PASSWORD-SENTINEL"
        let secrets = [$global_secret $env_secret $extra_secret $chain_secret]
        let before_preview = (command-error-snapshot $root)

        let exported = (run-command-process $root "api request export interpolated --collection interp")
        assert-boundary-process $exported "interpolated export" $secrets
        assert ($exported.stdout | str contains "/env/env-route?source=env-source")
        assert ($exported.stdout | str contains "X-Safe-Trace: env-trace")
        assert ($exported.stdout | str contains "X-Password: ******")
        let extra = {
            base_url: $base
            route: extra-route
            source: extra-source
            trace: extra-trace
            password_value: $extra_secret
        }
        let preview = (run-command-process $root $"api send interpolated --collection interp --vars ($extra | to nuon) --dry-run")
        assert-boundary-process $preview "interpolated extra preview" $secrets
        assert ($preview.stdout | str contains "/extra-route?source=extra-source")
        assert ($preview.stdout | str contains "X-Safe-Trace: extra-trace")
        assert ($preview.stdout | str contains "X-Password: ******")
        assert equal (command-error-snapshot $root) $before_preview "interpolated previews mutated state"
        assert equal (command-error-wire-events $server | length) 0

        let env_send = (run-command-process $root "api send interpolated --collection interp --raw | ignore")
        assert-boundary-process $env_send "environment send" $secrets
        let extra_send = (run-command-process $root $"api send interpolated --collection interp --vars ($extra | to nuon) --output status")
        assert-boundary-process $extra_send "extra-var send" $secrets
        assert equal ($extra_send.stdout | str trim) "200"
        let direct_url = "{{base_url}}/direct?source={{source}}"
        let direct_headers = {X-Safe-Trace: "{{trace}}", X-Pwd: "{{password_value}}"}
        let direct = (run-command-process $root $"api get ($direct_url | to nuon) --headers ($direct_headers | to nuon) --output none")
        assert-boundary-process $direct "global direct interpolation" $secrets
        assert equal ($direct.stdout | str trim) ""
        let generic_url = "{{base_url}}/generic?source={{source}}"
        let generic_headers = {X-Safe-Trace: "{{trace}}", Password: "{{password_value}}"}
        let generic = (run-command-process $root $"api request --method GET ($generic_url | to nuon) --headers ($generic_headers | to nuon) --select status")
        assert-boundary-process $generic "global generic interpolation" $secrets
        assert equal ($generic.stdout | str trim) "200"
        let steps = [{
            method: GET
            url: "{{base_url}}/chain?source={{source}}"
            headers: {X-Safe-Trace: "{{trace}}", X-Pwd: "{{password_value}}"}
            use: {
                base_url: $base
                source: chain-source
                trace: chain-trace
                password_value: $chain_secret
            }
        }]
        let chain = (run-command-process $root $"api chain run (boundary-record-list-nuon $steps) --collection interp --quiet | ignore")
        assert-boundary-process $chain "chain interpolation" $secrets
        let verbose = (run-command-process $root "api send interpolated --collection interp --no-history --verbose")
        assert-boundary-process $verbose "interpolated verbose" $secrets --allow-ansi
        let verbose_stdout = ($verbose.stdout | ansi strip)
        assert ($verbose_stdout | str contains "> X-Safe-Trace: env-trace")
        assert ($verbose_stdout | str contains "> X-Password: ******")
        let json = (run-command-process $root "api send interpolated --collection interp --no-history --output json")
        assert-boundary-process $json "interpolated JSON" $secrets
        assert ($json.stdout | str contains "\"X-Password\": \"******\"")

        let events = (command-error-wire-events $server)
        let expected = [
            {path: "/env/env-route?source=env-source", trace: env-trace, password: $env_secret}
            {path: "/extra-route?source=extra-source", trace: extra-trace, password: $extra_secret}
            {path: "/global/direct?source=global-source", trace: global-trace, password: $global_secret}
            {path: "/global/generic?source=global-source", trace: global-trace, password: $global_secret}
            {path: "/chain?source=chain-source", trace: chain-trace, password: $chain_secret}
            {path: "/env/env-route?source=env-source", trace: env-trace, password: $env_secret}
            {path: "/env/env-route?source=env-source", trace: env-trace, password: $env_secret}
        ]
        assert equal ($events | length) ($expected | length)
        for index in 0..<($expected | length) {
            assert equal ($events | get $index | select path trace password) ($expected | get $index)
            assert (($events | get $index | get password) != "******") "wire request sent mask text"
        }

        let entries = (boundary-history-entries $root)
        assert equal ($entries | length) 5
        for entry in $entries {
            assert equal $entry.request.headers_replayable false
            let password_headers = (
                $entry.request.headers
                | transpose key value
                | where {|header| $header.key in ["X-Password" "X-Pwd" "Password"] }
            )
            assert equal ($password_headers | length) 1
            assert equal ($password_headers | first | get value) "******"
        }
        assert-boundary-no-values (boundary-history-bytes $root) $secrets "interpolated history"
    }
}

def test-unsafe-interpolated-urls-are-atomic [] {
    with-boundary-server "interpolation-unsafe" {|root, infra, server|
        let base = $"http://127.0.0.1:($server.port)"
        $env.API_ROOT = $root
        api init | ignore
        api vars set base_url $base | ignore
        api vars set unsafe_name password | ignore
        api vars set unsafe_value GLOBAL-URL-VALUE-SENTINEL | ignore
        api collection create unsafe | ignore
        api collection env create unsafe active --activate | ignore
        api collection env set unsafe base_url $base | ignore
        api collection env set unsafe unsafe_name access_token | ignore
        api collection env set unsafe unsafe_value ENV-URL-VALUE-SENTINEL | ignore
        api auth oauth2 configure preflight --client-id safe-client --client-secret PREFLIGHT-CLIENT-SECRET-SENTINEL --token-url $"($base)/token" | ignore
        api request create unsafe-saved GET "{{base_url}}/saved?{{unsafe_name}}={{unsafe_value}}" --collection unsafe --auth {type: oauth2, ref: preflight} | ignore

        let global_url = "{{base_url}}/global?{{unsafe_name}}={{unsafe_value}}"
        let auth = {type: oauth2, ref: preflight}
        let extra = {unsafe_name: client_secret, unsafe_value: EXTRA-URL-VALUE-SENTINEL}
        let steps = [{
            method: GET
            url: "{{base_url}}/chain?{{unsafe_name}}={{unsafe_value}}"
            auth: $auth
            use: {unsafe_name: pwd, unsafe_value: CHAIN-URL-VALUE-SENTINEL}
        }]
        let cases = [
            {
                label: "global direct"
                command: $"api get ($global_url | to nuon) --auth ($auth | to nuon) --save (($root | path join 'direct.out') | to nuon)"
                expected: "Unsafe URL query parameter 'PASSWORD'"
                secret: "GLOBAL-URL-VALUE-SENTINEL"
                output: ($root | path join "direct.out")
            }
            {
                label: "global generic"
                command: $"api request --method GET ($global_url | to nuon) --auth ($auth | to nuon) --save (($root | path join 'generic.out') | to nuon)"
                expected: "Unsafe URL query parameter 'PASSWORD'"
                secret: "GLOBAL-URL-VALUE-SENTINEL"
                output: ($root | path join "generic.out")
            }
            {
                label: "collection environment send"
                command: $"api send unsafe-saved --collection unsafe --save (($root | path join 'saved.out') | to nuon)"
                expected: "Unsafe URL query parameter 'ACCESS_TOKEN'"
                secret: "ENV-URL-VALUE-SENTINEL"
                output: ($root | path join "saved.out")
            }
            {
                label: "collection environment export"
                command: "api request export unsafe-saved --collection unsafe"
                expected: "Unsafe URL query parameter 'ACCESS_TOKEN'"
                secret: "ENV-URL-VALUE-SENTINEL"
                output: null
            }
            {
                label: "extra variable override"
                command: $"api send unsafe-saved --collection unsafe --vars ($extra | to nuon) --save (($root | path join 'extra.out') | to nuon)"
                expected: "Unsafe URL query parameter 'CLIENT_SECRET'"
                secret: "EXTRA-URL-VALUE-SENTINEL"
                output: ($root | path join "extra.out")
            }
            {
                label: chain
                command: $"api chain run (boundary-record-list-nuon $steps) --collection unsafe --quiet"
                expected: "Unsafe URL query parameter 'PWD'"
                secret: "CHAIN-URL-VALUE-SENTINEL"
                output: null
            }
        ]
        let before = (command-error-snapshot $root)
        let token_before = (open $server.count_file --raw | str trim)
        let wire_before = (command-error-wire-events $server | length)
        for case in $cases {
            let result = (run-command-process $root $case.command)
            assert-boundary-failure $result $case.label $case.expected $case.secret
            assert equal (command-error-snapshot $root) $before $"($case.label) mutated workspace state"
            assert equal (open $server.count_file --raw | str trim) $token_before $"($case.label) acquired OAuth tokens"
            assert equal (command-error-wire-events $server | length) $wire_before $"($case.label) reached the network"
            if $case.output != null {
                assert (not ($case.output | path exists)) $"($case.label) created its output file"
            }
        }
        assert equal (boundary-history-bytes $root) ""
    }
}

export def run-suite-credential-boundaries []: nothing -> list<record> {
    print "\n=== Live Credential Boundary Tests ==="
    [
        (run-test "live response headers stay typed and masked across human and machine outputs" { test-live-response-header-output-contracts })
        (run-test "live response headers stay masked across history readers, index, and exports" { test-live-response-header-history-surfaces })
        (run-test "global, collection, and extra vars preserve header precedence without persistence leaks" { test-interpolated-header-precedence-and-history })
        (run-test "unsafe interpolated URLs fail before OAuth, network, history, or output mutation" { test-unsafe-interpolated-urls-are-atomic })
    ]
}
