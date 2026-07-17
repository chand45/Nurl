# Transport failure, retry, binary transaction, and chain continuation regressions.

def transport-fake-mode [fake: record, mode: string, log_name: string] {
    $fake
    | update mode $mode
    | update log ($fake.path | path join $log_name)
}

def fake-request-count [fake: record] {
    if not ($fake.log | path exists) {
        return 0
    }
    open $fake.log --raw | lines | where $it == "request" | length
}

def assert-safe-transport-error [result: record, exit_code: int, attempts: int, label: string] {
    surface-error $result $"Curl transport failed with exit code ($exit_code)" $label
    assert ($result.stderr | str contains $"after ($attempts) of ($attempts) attempts") $"($label) omitted the attempt count"
    for forbidden in [
        "TRANSPORT-TOKEN-SENTINEL"
        "NURL_RESPONSE_META_"
        "deterministic transport failure Authorization: Bearer"
        "curl -"
    ] {
        assert (not ($result.stderr | str contains $forbidden)) $"($label) leaked '($forbidden)'"
    }
}

def binary-attempt-files [destination: string] {
    let expanded = ($destination | path expand --no-symlink)
    let parent = ($expanded | path dirname)
    let prefix = $".(($expanded | path basename)).nurl-"
    if not ($parent | path exists) {
        return []
    }
    ls -a $parent | where {|entry| ($entry.name | path basename) | str starts-with $prefix }
}

def history-entry-count [root: string] {
    let history = ($root | path join "history")
    if not ($history | path exists) {
        return 0
    }
    command-error-entries $history | where {|path|
        let path_type = ($path | path type)
        let extension = ($path | path parse | get extension)
        let name = ($path | path basename)
        $path_type == "file" and $extension == "nuon" and $name != "index.nuon"
    } | length
}

def setup-transport-workspace [root: string] {
    $env.API_ROOT = $root
    api init | ignore
    api collection create transport | ignore
    api request create saved GET "http://transport.invalid/saved" --collection transport --headers {
        Authorization: "Bearer TRANSPORT-TOKEN-SENTINEL"
    } | ignore
    let history_id = (api history save {
        method: GET
        url: "http://transport.invalid/history"
        headers: {Authorization: "Bearer TRANSPORT-TOKEN-SENTINEL"}
        body: null
    } {
        status: 200
        status_text: OK
        headers: {}
        body: null
        time_ms: 1
        size_bytes: 0
    })
    $history_id
}

def test-transport-failure-surfaces [] {
    let root = (make-temp-dir "transport-surfaces")
    let fake_dir = (make-temp-dir "transport-fake")
    let fake_base = (make-fake-curl $fake_dir "8.13.0" "supported")
    let fake = (transport-fake-mode $fake_base "transport-failure" "surface.log")
    let history_id = (setup-transport-workspace $root)
    let save_path = ($root | path join "must-not-save.txt")
    let url = "http://transport.invalid/direct"
    let headers = "{Authorization: 'Bearer TRANSPORT-TOKEN-SENTINEL'}"
    let cases = [
        {label: "get pretty", command: $"api get ($url | to nuon) -H ($headers) --save ($save_path | to nuon)"}
        {label: "post raw flag", command: $"api post ($url | to nuon) -H ($headers) --raw --save ($save_path | to nuon)"}
        {label: "put body output", command: $"api put ($url | to nuon) -H ($headers) --output body --save ($save_path | to nuon)"}
        {label: "patch json output", command: $"api patch ($url | to nuon) -H ($headers) --output json --save ($save_path | to nuon)"}
        {label: "delete headers output", command: $"api delete ($url | to nuon) -H ($headers) --output headers"}
        {label: "generic status output", command: $"api request -m GET ($url | to nuon) -H ($headers) --output status --save ($save_path | to nuon)"}
        {label: "head none output", command: $"api head ($url | to nuon) -H ($headers) --output none --save ($save_path | to nuon)"}
        {label: "options selection", command: $"api options ($url | to nuon) -H ($headers) --select status --save ($save_path | to nuon)"}
        {label: "saved raw output", command: ("api send saved --collection transport --output raw --save " + ($save_path | to nuon))}
        {label: "history resend", command: ("api history resend " + ($history_id | to nuon) + " --raw")}
    ]

    let failure = try {
        for case in $cases {
            let before = (command-error-snapshot $root)
            let requests_before = (fake-request-count $fake)
            let result = (run-with-fake-curl $root $fake $case.command)
            assert-safe-transport-error $result 7 1 $case.label
            assert equal (fake-request-count $fake) ($requests_before + 1) $"($case.label) did not make exactly one attempt"
            assert equal (command-error-snapshot $root) $before $"($case.label) mutated history or output state"
            assert (not ($save_path | path exists)) $"($case.label) created --save output"
        }

        let scoped_debug = (run-with-fake-curl $root $fake (
            "try { api get "
            + ($url | to nuon)
            + " -H "
            + $headers
            + " --debug --output none --no-history } catch {}; "
            + "if ($env.API_DEBUG? | default false) { error make {msg: 'API_DEBUG leaked'} }"
        ))
        assert equal $scoped_debug.exit_code 0 $"debug cleanup failed: ($scoped_debug.stderr)"
        assert equal ($scoped_debug.stdout | str trim) "" "debug cleanup probe wrote stdout"
        assert equal ($scoped_debug.stderr | str trim) "" "debug cleanup probe wrote stderr"
        null
    } catch {|error| $error }

    cleanup $root
    cleanup $fake_dir
    if $failure != null { error make {msg: $failure.msg} }
}

def test-retry-policy-and-preflight [] {
    let root = (make-temp-dir "transport-retries")
    let fake_dir = (make-temp-dir "transport-retry-fake")
    let infra = (make-temp-dir "transport-retry-server")
    let fake_base = (make-fake-curl $fake_dir "8.13.0" "supported")
    let failure_fake = (transport-fake-mode $fake_base "transport-failure" "failure.log")
    let eventual_fake = (transport-fake-mode $fake_base "transport-eventual-success" "eventual.log")
    let unsupported_fake = (transport-fake-mode ($fake_base | update version "7.74.0") "unsupported" "preflight.log")
    let server = (surface-server $infra)
    let failure = try {
        setup-transport-workspace $root | ignore
        let url = "http://transport.invalid/retry"

        let zero = (run-with-fake-curl $root $failure_fake $"api get ($url | to nuon) --retries 0 --output none --no-history")
        assert-safe-transport-error $zero 7 1 "zero retries"
        assert equal (fake-request-count $failure_fake) 1 "zero retries must perform one attempt"

        rm -f $failure_fake.log
        let exhausted = (run-with-fake-curl $root $failure_fake $"api get ($url | to nuon) --retries 2 --output none --no-history")
        assert-safe-transport-error $exhausted 7 3 "exhausted retries"
        assert equal (fake-request-count $failure_fake) 3 "two retries must perform three attempts"

        let eventual = (run-with-fake-curl $root $eventual_fake $"api get ($url | to nuon) --retries 2 --output status --no-history")
        assert equal $eventual.exit_code 0 $"eventual retry success failed: ($eventual.stderr)"
        assert equal ($eventual.stdout | str trim) "200" "eventual retry success returned the wrong status"
        assert equal ($eventual.stderr | str trim) "" "eventual retry success wrote stderr"
        assert equal (fake-request-count $eventual_fake) 2 "eventual retry success did not stop after the successful attempt"

        let before = (command-error-snapshot $root)
        let missing_body = ($root | path join "missing-body.json")
        let save_path = ($root | path join "must-not-save.txt")
        let binary_path = ($root | path join "must-not-download.bin")
        let negative_cases = [
            $"api get ($url | to nuon) --retries (-1) --output none"
            $"api post ($url | to nuon) --retry-delay (-1) --body-file ($missing_body | to nuon) --save ($save_path | to nuon) --binary-save ($binary_path | to nuon) --output none"
            "api send missing --collection missing --retries (-1) --output none"
        ]
        for command in $negative_cases {
            let rejected = (run-with-fake-curl $root $unsupported_fake $command)
            surface-error $rejected "must be zero or greater" "negative retry preflight"
        }
        assert (not ($unsupported_fake.log | path exists)) "negative retry preflight invoked curl"
        assert equal (command-error-snapshot $root) $before "negative retry preflight mutated workspace state"
        assert (not ($save_path | path exists)) "negative retry delay created --save output"
        assert (not ($binary_path | path exists)) "negative retry delay created binary output"

        let base = $"http://127.0.0.1:($server.port)"
        let wire_before = (command-error-wire-events $server | length)
        let final_503 = (run-command-process $root $"api get (($base + '/http-error') | to nuon) --retries 2 --output status --no-history")
        assert equal $final_503.exit_code 0 $"final HTTP 503 became a command failure: ($final_503.stderr)"
        assert equal ($final_503.stdout | str trim) "503" "final HTTP 503 did not remain a typed response"
        assert equal ($final_503.stderr | str trim) "" "final HTTP 503 wrote stderr"
        assert equal (command-error-wire-events $server | length) ($wire_before + 3) "final HTTP 503 did not use N+1 attempts"

        let binary_503_path = ($root | path join "final-503.bin")
        let binary_wire_before = (command-error-wire-events $server | length)
        let binary_503 = (run-command-process $root $"api get (($base + '/http-error') | to nuon) --binary-save ($binary_503_path | to nuon) --retries 1 --output status --no-history")
        assert equal $binary_503.exit_code 0 $"binary HTTP 503 became a command failure: ($binary_503.stderr)"
        assert equal ($binary_503.stdout | str trim) "503" "binary HTTP 503 did not remain a typed response"
        assert ((open $binary_503_path --raw) | str contains '"ok":true') "binary HTTP 503 did not commit completed response bytes"
        assert equal (command-error-wire-events $server | length) ($binary_wire_before + 2) "binary HTTP 503 did not use N+1 attempts"
        assert equal (binary-attempt-files $binary_503_path | length) 0 "binary HTTP 503 left attempt files"
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    cleanup $root
    cleanup $fake_dir
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def test-binary-retry-transactions [] {
    let root = (make-temp-dir "binary-transactions")
    let fake_dir = (make-temp-dir "binary-transaction-fake")
    let fake_base = (make-fake-curl $fake_dir "8.13.0" "supported")
    let supported = (transport-fake-mode $fake_base "supported" "success.log")
    let eventual = (transport-fake-mode $fake_base "transport-eventual-success" "eventual.log")
    let connection = (transport-fake-mode $fake_base "transport-failure" "connection.log")
    let partial = (transport-fake-mode $fake_base "partial-timeout" "partial.log")
    let failure = try {
        setup-transport-workspace $root | ignore
        let url = "http://transport.invalid/binary"
        let initial_history = (history-entry-count $root)

        let success_path = ($root | path join "success.bin")
        let success = (run-with-fake-curl $root $supported $"api get ($url | to nuon) --binary-save ($success_path | to nuon) --output none --no-history")
        assert equal $success.exit_code 0 $"binary success failed: ($success.stderr)"
        assert equal (open $success_path --raw) "BODY" "binary success changed response bytes"
        assert equal (binary-attempt-files $success_path | length) 0 "binary success left an attempt file"

        let eventual_path = ($root | path join "eventual.bin")
        "SENTINEL" | save -f $eventual_path
        let transient = (run-with-fake-curl $root $eventual $"api get ($url | to nuon) --binary-save ($eventual_path | to nuon) --retries 2 --output none --no-history")
        assert equal $transient.exit_code 0 $"binary transient retry failed: ($transient.stderr)"
        assert equal (open $eventual_path --raw) "BODY" "binary transient retry did not commit completed bytes"
        assert equal (fake-request-count $eventual) 2 "binary transient retry did not stop after success"
        assert equal (binary-attempt-files $eventual_path | length) 0 "binary transient retry left attempt files"

        let preserved_path = ($root | path join "preserved.bin")
        0x[00 ff 01 80] | save -f $preserved_path
        let before_bytes = (open $preserved_path --raw)
        let connection_failure = (run-with-fake-curl $root $connection $"api get ($url | to nuon) --binary-save ($preserved_path | to nuon) --retries 2 --output none")
        assert-safe-transport-error $connection_failure 7 3 "binary exhausted connection"
        assert equal (fake-request-count $connection) 3 "binary exhausted connection did not make N+1 attempts"
        assert equal (open $preserved_path --raw) $before_bytes "binary exhausted connection replaced the existing destination"
        assert equal (binary-attempt-files $preserved_path | length) 0 "binary exhausted connection left attempt files"

        let absent_path = ($root | path join "absent.bin")
        let partial_failure = (run-with-fake-curl $root $partial $"api get ($url | to nuon) --binary-save ($absent_path | to nuon) --retries 2 --output none")
        assert-safe-transport-error $partial_failure 28 3 "binary partial timeout"
        assert equal (fake-request-count $partial) 3 "binary partial timeout did not make N+1 attempts"
        assert (not ($absent_path | path exists)) "binary partial timeout created an absent destination"
        assert equal (binary-attempt-files $absent_path | length) 0 "binary partial timeout left attempt files"
        assert equal (history-entry-count $root) $initial_history "failed binary transfers created history"
        null
    } catch {|error| $error }

    cleanup $root
    cleanup $fake_dir
    if $failure != null { error make {msg: $failure.msg} }
}

def chain-command [command_name: string] {
    let steps = "([{method: GET, url: 'http://transport.invalid/one'}, {method: GET, url: 'http://transport.invalid/two'}])"
    if $command_name == "run" {
        "let result = (api chain run " + $steps + " --quiet); $result | to json --raw"
    } else {
        "let result = (api chain exec transport-chain --quiet); $result | to json --raw"
    }
}

def test-chain-transport-policy [] {
    let root = (make-temp-dir "transport-chain")
    let fake_dir = (make-temp-dir "transport-chain-fake")
    let fake_base = (make-fake-curl $fake_dir "8.13.0" "supported")
    let run_fake = (transport-fake-mode $fake_base "transport-eventual-success" "run.log")
    let exec_fake = (transport-fake-mode $fake_base "transport-eventual-success" "exec.log")
    let stop_fake = (transport-fake-mode $fake_base "transport-failure" "stop.log")
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        mkdir ($root | path join "chains")
        {
            name: transport-chain
            steps: [
                {method: GET, url: "http://transport.invalid/one"}
                {method: GET, url: "http://transport.invalid/two"}
            ]
        } | to nuon --indent 4 | save ($root | path join "chains" "transport-chain.nuon")

        for case in [
            {label: "chain run", fake: $run_fake, command: (chain-command "run")}
            {label: "chain exec", fake: $exec_fake, command: (chain-command "exec")}
        ] {
            let continued = (run-with-fake-curl $root $case.fake $case.command)
            assert equal $continued.exit_code 0 $"($case.label) continuation failed: ($continued.stderr)"
            assert equal ($continued.stderr | str trim) "" $"($case.label) --quiet wrote human diagnostics"
            let summary = ($continued.stdout | from json)
            assert equal $summary.success false $"($case.label) returned success:true after a failed step"
            assert equal ($summary.results | length) 2 $"($case.label) did not record the failed step and continue"
            assert equal ($summary.results | first | get status) null $"($case.label) failed step looked successful"
            assert equal ($summary.results | last | get status) 200 $"($case.label) did not execute the later step"
            assert equal (fake-request-count $case.fake) 2 $"($case.label) did not make both transfers"
        }

        let stop_command = "api chain run ([{method: GET, url: 'http://transport.invalid/stop'}, {method: GET, url: 'http://transport.invalid/unreached'}]) --stop-on-error --quiet | ignore"
        let stopped = (run-with-fake-curl $root $stop_fake $stop_command)
        assert-safe-transport-error $stopped 7 1 "chain stop-on-error"
        assert equal (fake-request-count $stop_fake) 1 "chain --stop-on-error executed a later step"
        null
    } catch {|error| $error }

    cleanup $root
    cleanup $fake_dir
    if $failure != null { error make {msg: $failure.msg} }
}

export def run-suite-transport-failures [] {
    print $"\n(ansi yellow)── Transport failures and binary transactions ──(ansi reset)"
    [
        (run-test "transport failures are safe command errors on direct and composed surfaces" { test-transport-failure-surfaces })
        (run-test "retry counts, eventual success, HTTP 503, and negative preflight are explicit" { test-retry-policy-and-preflight })
        (run-test "binary retries commit complete bytes and preserve destinations on failure" { test-binary-retry-transactions })
        (run-test "chains continue or stop explicitly after transport failures" { test-chain-transport-policy })
    ]
}
