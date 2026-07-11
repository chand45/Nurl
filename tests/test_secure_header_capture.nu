# Fileless response-header transport security, compatibility, and latency regressions.

def response-header-artifact-roots [extra_roots: list = []] {
    mut roots = [$nu.temp-dir]
    if $nu.os-info.name == "windows" {
        let local = ($env.LOCALAPPDATA? | default "")
        if not ($local | is-empty) {
            $roots = ($roots | append ($local | path join "NurlPrivateHttp"))
        }
    }
    $roots
    | append $extra_roots
    | where {|root| not ($root | is-empty) }
    | uniq
}

def response-header-artifacts [extra_roots: list = []] {
    response-header-artifact-roots $extra_roots
    | each {|root|
        if not ($root | path exists) {
            []
        } else {
            try {
                ls -la $root
                | where {|entry|
                    ($entry.name | path basename) | str starts-with "nurl-response-headers-"
                }
            } catch {
                []
            }
        }
    }
    | flatten
}

def assert-no-new-header-artifacts [baseline_paths: list, label: string, extra_roots: list = []] {
    let unexpected = (
        response-header-artifacts $extra_roots
        | where {|artifact| $artifact.name not-in $baseline_paths }
    )
    assert equal ($unexpected | length) 0 $"($label) created a response-header filesystem artifact"
}

def wait-for-secure-process [pid: int, expected_running: bool, attempts: int = 200] {
    mut reached = false
    for _ in 1..$attempts {
        if (command-error-process-running $pid) == $expected_running {
            $reached = true
            break
        }
        sleep 50ms
    }
    assert $reached $"process ($pid) did not reach the expected state"
}

def wait-for-wire-count [server: record, expected: int, attempts: int = 200] {
    mut reached = false
    for _ in 1..$attempts {
        if (command-error-wire-events $server | length) >= $expected {
            $reached = true
            break
        }
        sleep 50ms
    }
    assert $reached $"server did not observe ($expected) requests"
}

def secure-python [] {
    let candidates = (
        (which python3 | append (which python))
        | where type == "external"
        | get command
    )
    if ($candidates | is-empty) {
        error make {msg: "Python is required for POSIX response-header process tests"}
    }
    $candidates | first
}

def start-secure-client [
    tmp: string
    root: string
    command: string
    label: string
    redirected_temp: string = ""
] {
    let script = ($tmp | path join $"($label).nu")
    let stdout = ($tmp | path join $"($label).stdout")
    let stderr = ($tmp | path join $"($label).stderr")
    let module_path = ($env.NURL_REPO_ROOT | path join "nu_modules" "mod.nu")
    [
        $"use ($module_path | to nuon) *"
        $"$env.API_ROOT = ($root | to nuon)"
        $command
    ] | str join "\n" | save -f $script

    let launched = if $nu.os-info.name == "windows" {
        let worker = ($tmp | path join $"($label)-worker.ps1")
        let launcher = ($tmp | path join $"($label)-launcher.ps1")
        'param($Exe, $Script, $Stdout, $Stderr, $RedirectedTemp)
if ($RedirectedTemp -ne "") {
    $env:TEMP = $RedirectedTemp
    $env:TMP = $RedirectedTemp
}
$process = Start-Process -PassThru -WindowStyle Hidden -FilePath $Exe -ArgumentList @("--no-config-file", $Script) -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
Wait-Process -Id $process.Id
' | save -f $worker
        let launcher_source = "param($Worker, $Exe, $Script, $Stdout, $Stderr, $RedirectedTemp)
$arguments = @(
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    ('\"{0}\"' -f $Worker),
    ('\"{0}\"' -f $Exe),
    ('\"{0}\"' -f $Script),
    ('\"{0}\"' -f $Stdout),
    ('\"{0}\"' -f $Stderr),
    ('\"{0}\"' -f $RedirectedTemp)
)
$process = Start-Process -PassThru -WindowStyle Hidden -FilePath 'powershell.exe' -ArgumentList $arguments
[Console]::Out.Write($process.Id)
"
        $launcher_source | save -f $launcher
        ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcher $worker $nu.current-exe $script $stdout $stderr $redirected_temp | complete
    } else {
        let launcher = ($tmp | path join $"($label)-launcher.py")
        'import os
import subprocess
import sys

if sys.argv[5]:
    os.environ["TMPDIR"] = sys.argv[5]
with open(sys.argv[3], "wb") as stdout, open(sys.argv[4], "wb") as stderr:
    process = subprocess.Popen(
        [sys.argv[1], "--no-config-file", sys.argv[2]],
        stdin=subprocess.DEVNULL,
        stdout=stdout,
        stderr=stderr,
        start_new_session=True,
    )
print(process.pid)
' | save -f $launcher
        let python = (secure-python)
        ^$python $launcher $nu.current-exe $script $stdout $stderr $redirected_temp | complete
    }
    assert equal $launched.exit_code 0 $"could not launch response-header client: ($launched.stderr)"
    {
        pid: ($launched.stdout | str trim | into int)
        stdout: $stdout
        stderr: $stderr
    }
}

def stop-secure-process-tree [pid: int, tmp: string] {
    if $nu.os-info.name == "windows" {
        let stopper = ($tmp | path join $"stop-($pid).ps1")
        'param([int]$RootPid)
$frontier = @($RootPid)
$all = @($RootPid)
while ($frontier.Count -gt 0) {
    $next = @(Get-CimInstance Win32_Process | Where-Object { $frontier -contains [int]$_.ParentProcessId } | ForEach-Object { [int]$_.ProcessId })
    if ($next.Count -eq 0) { break }
    $all += $next
    $frontier = $next
}
[array]::Reverse($all)
foreach ($processId in $all) {
    if (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
        Stop-Process -Id $processId -Force
    }
}
' | save -f $stopper
        let stopped = (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $stopper $pid | complete)
        assert equal $stopped.exit_code 0 $"could not stop client PID tree: ($stopped.stderr)"
    } else {
        let stopper = ($tmp | path join $"stop-($pid).py")
        'import os
import signal
import sys

try:
    os.killpg(int(sys.argv[1]), signal.SIGTERM)
except ProcessLookupError:
    pass
' | save -f $stopper
        let python = (secure-python)
        let stopped = (^$python $stopper $pid | complete)
        assert equal $stopped.exit_code 0 $"could not stop client process group: ($stopped.stderr)"
    }
    wait-for-secure-process $pid false
}

def make-fake-curl [dir: string, version: string, mode: string] {
    let log = ($dir | path join "request-invocations.log")
    if $nu.os-info.name == "windows" {
        let fake = ($dir | path join "curl.exe")
        let compile_script = '
$ErrorActionPreference = "Stop"
$source = @"
using System;
using System.IO;

public static class FakeCurl
{
    public static int Main(string[] args)
    {
        string version = Environment.GetEnvironmentVariable("NURL_FAKE_CURL_VERSION") ?? "8.13.0";
        if (args.Length > 0 && args[0] == "--version")
        {
            Console.WriteLine("curl " + version + " Windows libcurl/" + version);
            return 0;
        }
        string log = Environment.GetEnvironmentVariable("NURL_FAKE_CURL_LOG");
        if (!String.IsNullOrEmpty(log))
        {
            File.AppendAllText(log, "request" + Environment.NewLine);
        }
        if (Environment.GetEnvironmentVariable("NURL_FAKE_CURL_MODE") == "malformed")
        {
            Console.Error.WriteLine("FAKE-CURL-DIAGNOSTIC NURL_RESPONSE_META_static_BEGIN INTERNAL-METADATA-SENTINEL");
            Console.Out.Write("UNTRUSTED-BODY-SENTINEL");
            return 0;
        }
        return 99;
    }
}
"@
Add-Type -TypeDefinition $source -OutputAssembly $env:NURL_FAKE_CURL_EXE -OutputType ConsoleApplication
'
        let compiled = (with-env {NURL_FAKE_CURL_EXE: $fake} {
            ^powershell.exe -NoProfile -NonInteractive -Command $compile_script | complete
        })
        assert equal $compiled.exit_code 0 $"could not compile deterministic fake curl: ($compiled.stderr)"
    } else {
        let fake = ($dir | path join "curl")
        let request_action = if $mode == "malformed" {
            'printf "%s\n" "FAKE-CURL-DIAGNOSTIC NURL_RESPONSE_META_static_BEGIN INTERNAL-METADATA-SENTINEL" >&2
printf "%s" "UNTRUSTED-BODY-SENTINEL"
exit 0'
        } else {
            'exit 99'
        }
        $"#!/bin/sh
if [ \"x$1\" = \"x--version\" ]; then
  echo \"curl ($version) libcurl/($version)\"
  exit 0
fi
echo request >> \"$NURL_FAKE_CURL_LOG\"
($request_action)
" | save -f $fake
        ^chmod 700 $fake
    }
    {path: $dir, log: $log, version: $version, mode: $mode}
}

def run-with-fake-curl [root: string, fake: record, command: string] {
    let setup = (
        "$env.PATH = (["
        + ($fake.path | to nuon)
        + "] | append $env.PATH)\n$env.NURL_FAKE_CURL_LOG = "
        + ($fake.log | to nuon)
        + "\n$env.NURL_FAKE_CURL_VERSION = "
        + ($fake.version | to nuon)
        + "\n$env.NURL_FAKE_CURL_MODE = "
        + ($fake.mode | to nuon)
    )
    run-command-process $root ($setup + "\n" + $command)
}

def summarize-latency [samples: list] {
    let sorted = ($samples | sort)
    let p95_index = (((($sorted | length) * 0.95) | math ceil) - 1)
    {
        median_ms: ($sorted | math median | math round --precision 2)
        p95_ms: ($sorted | get $p95_index | math round --precision 2)
    }
}

def measure-latency [count: int, operation: closure] {
    1..$count | each {
        let started = (date now)
        do $operation
        ((date now) - $started) / 1ms
    }
}

def test-fileless-header-correctness-and-secrecy [] {
    let root = (make-temp-dir "fileless-header-correctness")
    let infra = (make-temp-dir "fileless-header-correctness-server")
    let server = (surface-server $infra)
    let baseline = (response-header-artifacts | get name? | default [])
    let failure = try {
        surface-workspace $root $server
        let base = $"http://127.0.0.1:($server.port)"

        let sensitive_command = (
            "let result = (api get "
            + (($base + "/sensitive-headers") | to nuon)
            + " --raw); if ($result.response.headers | get 'Set-Cookie') != 'session=RESPONSE-COOKIE-SENTINEL; HttpOnly' { error make {msg: 'cookie header was not parsed'} }; if ($result.response.headers | get 'X-Session-Token') != 'RESPONSE-TOKEN-SENTINEL' { error make {msg: 'token header was not parsed'} }; if ($result.response.headers | get 'X-Debug-Auth' | is-empty) { error make {msg: 'auth-like header was not parsed'} }; print 'sensitive response headers parsed'"
        )
        let sensitive = (run-command-process $root $sensitive_command)
        assert equal $sensitive.exit_code 0 "sensitive response-header parse failed"
        assert ($sensitive.stdout | str contains "sensitive response headers parsed") "sensitive headers were not available to the typed response"

        let displayed = (run-command-process $root $"api get (($base + '/sensitive-headers') | to nuon) --include --no-history")
        assert equal $displayed.exit_code 0 "redacted human response failed"
        assert ($displayed.stdout | str contains "******") "sensitive human response headers were not redacted"

        let duplicate = (run-command-process $root (
            "let result = (api get "
            + (($base + "/duplicate-headers") | to nuon)
            + " --raw --no-history); if ($result.response.headers | get 'X-Duplicate') != 'second' { error make {msg: 'duplicate-header compatibility changed'} }; if ($result.response.headers | get 'X-Marker-Like') != 'NURL_RESPONSE_META_static_BEGIN' { error make {msg: 'marker-like header changed'} }; print 'duplicate and marker headers parsed'"
        ))
        assert equal $duplicate.exit_code 0 $"duplicate response-header parse failed: ($duplicate.stderr)"

        let redirected = (run-command-process $root (
            "let result = (api get "
            + (($base + "/redirect") | to nuon)
            + " --follow-redirects --raw --no-history); if $result.response.status != 200 { error make {msg: 'redirect final status changed'} }; if ($result.response.headers | get 'Set-Cookie') != 'session=RESPONSE-COOKIE-SENTINEL; HttpOnly' { error make {msg: 'redirect final headers missing'} }; print 'redirect final response parsed'"
        ))
        assert equal $redirected.exit_code 0 $"redirect response-header parse failed: ($redirected.stderr)"

        let early = (run-command-process $root (
            "let result = (api get "
            + (($base + "/early-hints") | to nuon)
            + " --raw --no-history); if $result.response.status != 200 { error make {msg: 'early-hints final status changed'} }; if ($result.response.headers | get 'X-Final') != 'final-value' { error make {msg: 'early-hints final headers missing'} }; print 'early hints final response parsed'"
        ))
        assert equal $early.exit_code 0 $"1xx response-header parse failed: ($early.stderr)"

        let empty_headers = (run-command-process $root (
            "let result = (api get "
            + (($base + "/empty-headers") | to nuon)
            + " --raw --no-history); if $result.response.status != 204 { error make {msg: 'empty-header status changed'} }; if ($result.response.headers | columns | is-not-empty) { error make {msg: 'empty-header response gained headers'} }; print 'empty headers parsed'"
        ))
        assert equal $empty_headers.exit_code 0 $"empty response-header parse failed: ($empty_headers.stderr)"

        for path in ["/sentinel" "/http-like-text" "/whitespace" "/json-string" "/json-null" "/empty"] {
            let result = (run-command-process $root $"api get (($base + $path) | to nuon) --raw --no-history | ignore")
            assert equal $result.exit_code 0 $"marker/scalar/empty body failed: ($path): ($result.stderr)"
        }

        for mode in ["pretty" "raw" "body" "json" "headers" "status" "none"] {
            let result = (run-command-process $root $"api get (($base + '/success') | to nuon) --output ($mode) --no-history")
            assert equal $result.exit_code 0 $"fileless response failed for --output ($mode)"
            assert equal ($result.stderr | str trim) "" $"fileless response wrote stderr for --output ($mode)"
            assert-no-new-header-artifacts $baseline $"output mode ($mode)"
        }

        let binary_path = ($root | path join "binary-response.bin")
        let binary = (run-command-process $root $"api get (($base + '/sentinel') | to nuon) --binary-save ($binary_path | to nuon) --output none --no-history")
        assert equal $binary.exit_code 0 $"binary response failed: ($binary.stderr)"
        assert ($binary_path | path exists) "binary response was not saved"

        let persisted = (command-error-snapshot $root | to nuon)
        let public_streams = ([
            $sensitive.stdout $sensitive.stderr
            $displayed.stdout $displayed.stderr
            $duplicate.stdout $duplicate.stderr
            $redirected.stdout $redirected.stderr
            $early.stdout $early.stderr
            $empty_headers.stdout $empty_headers.stderr
        ] | str join "\n")
        let bearer_secret = (["RESPONSE" "BEARER" "SENTINEL"] | str join "-")
        for secret in [
            "RESPONSE-COOKIE-SENTINEL"
            "RESPONSE-TOKEN-SENTINEL"
            $bearer_secret
            "INTERNAL-METADATA-SENTINEL"
        ] {
            assert (not ($public_streams | str contains $secret)) $"sensitive/internal header transport data leaked publicly: ($secret)"
            assert (not ($persisted | str contains $secret)) $"sensitive/internal header transport data leaked to persisted state: ($secret)"
        }
        assert (not ($public_streams | str contains "NURL_RESPONSE_META_")) "internal response metadata frame leaked publicly"
        assert-no-new-header-artifacts $baseline "correctness and secrecy"
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    assert-no-new-header-artifacts $baseline "correctness teardown"
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def test-fileless-failure-retry-and-capability-contracts [] {
    let root = (make-temp-dir "fileless-header-failures")
    let infra = (make-temp-dir "fileless-header-failures-server")
    let fake_dir = (make-temp-dir "fileless-header-fake-curl")
    let server = (surface-server $infra)
    let baseline = (response-header-artifacts | get name? | default [])
    let failure = try {
        surface-workspace $root $server
        let base = $"http://127.0.0.1:($server.port)"

        let http_error = (run-command-process $root $"api get (($base + '/http-error') | to nuon) --output status --retries 2 --no-history")
        assert equal $http_error.exit_code 0 "HTTP error response/retry failed"
        assert equal ($http_error.stdout | str trim) "503" "HTTP error status was not preserved"
        assert-no-new-header-artifacts $baseline "HTTP error and retry"

        let connection = (run-command-process $root "api get 'http://127.0.0.1:1/connection-failure' --output none --retries 1 --no-history")
        assert (not ($connection.stderr | str contains "NURL_RESPONSE_META_")) "curl connection failure exposed an internal metadata frame"
        assert-no-new-header-artifacts $baseline "curl connection failure"

        let config_path = ($root | path join "config.nuon")
        open $config_path | upsert timeout_seconds 1 | save -f $config_path
        let wire_before_timeout = (command-error-wire-events $server | length)
        let timeout_started = (date now)
        let timeout = (run-command-process $root $"api get (($base + '/timeout') | to nuon) --output none --no-history")
        let timeout_ms = (((date now) - $timeout_started) / 1ms)
        assert equal (command-error-wire-events $server | length) ($wire_before_timeout + 1) "curl timeout path did not reach the endpoint"
        assert ($timeout_ms >= 500 and $timeout_ms < 2500) $"curl timeout did not stop the slow transfer near its configured bound: ($timeout_ms) ms"
        assert (not ($timeout.stderr | str contains "NURL_RESPONSE_META_")) "curl timeout exposed an internal metadata frame"
        open $config_path | upsert timeout_seconds 30 | save -f $config_path
        assert-no-new-header-artifacts $baseline "curl timeout"

        let malformed_header = (run-command-process $root $"api get (($base + '/malformed-header') | to nuon) --output none --no-history")
        assert ($malformed_header.exit_code != 0) "non-UTF8 structured response metadata unexpectedly succeeded"
        assert equal ($malformed_header.stdout | str trim) "" "non-UTF8 structured response metadata wrote stdout"
        assert ($malformed_header.stderr | str contains "malformed structured response metadata") "non-UTF8 structured response metadata diagnostic was not actionable"
        assert (not ($malformed_header.stderr | str contains "NURL_RESPONSE_META_")) "non-UTF8 structured response metadata exposed its internal frame"
        assert-no-new-header-artifacts $baseline "malformed wire header"

        let wire_before_selection = (command-error-wire-events $server | length)
        let selection = (run-command-process $root $"api get (($base + '/post-capture-failure') | to nuon) --select response.body.missing --no-history")
        assert (not ($selection.stderr | str contains "NURL_RESPONSE_META_")) "post-response selection path exposed an internal metadata frame"
        assert equal (command-error-wire-events $server | length) ($wire_before_selection + 1) "post-response output failure did not execute"
        assert-no-new-header-artifacts $baseline "post-response output failure"

        let unsupported_dir = ($fake_dir | path join "unsupported")
        mkdir $unsupported_dir
        let unsupported = (make-fake-curl $unsupported_dir "7.82.0" "unsupported")
        let wire_before_unsupported = (command-error-wire-events $server | length)
        let old_curl = (run-with-fake-curl $root $unsupported $"api get (($base + '/must-not-run') | to nuon) --output none --no-history")
        assert ($old_curl.exit_code != 0) "unsupported curl version unexpectedly succeeded"
        assert equal ($old_curl.stdout | str trim) "" "unsupported curl version wrote stdout"
        assert ($old_curl.stderr | str contains "requires curl 7.83.0 or newer") "unsupported curl diagnostic was not actionable"
        assert equal $old_curl.stderr ($old_curl.stderr | ansi strip) "unsupported curl diagnostic contained ANSI"
        assert equal (command-error-wire-events $server | length) $wire_before_unsupported "unsupported curl reached the network"
        assert (not ($unsupported.log | path exists)) "unsupported curl advanced past the version preflight"

        let malformed_dir = ($fake_dir | path join "malformed")
        mkdir $malformed_dir
        let malformed = (make-fake-curl $malformed_dir "8.13.0" "malformed")
        let malformed_frame = (run-with-fake-curl $root $malformed $"api get (($base + '/fake-transfer') | to nuon) --output none --no-history")
        assert ($malformed_frame.exit_code != 0) "missing trusted metadata frame unexpectedly succeeded"
        assert equal ($malformed_frame.stdout | str trim) "" "malformed metadata frame exposed response body"
        assert ($malformed_frame.stderr | str contains "trusted response metadata") $"malformed metadata diagnostic was not actionable: ($malformed_frame.stderr)"
        for forbidden in ["FAKE-CURL-DIAGNOSTIC" "INTERNAL-METADATA-SENTINEL" "UNTRUSTED-BODY-SENTINEL" "NURL_RESPONSE_META_static_BEGIN"] {
            assert (not ($malformed_frame.stdout | str contains $forbidden)) $"malformed metadata leaked to stdout: ($forbidden)"
            assert (not ($malformed_frame.stderr | str contains $forbidden)) $"malformed metadata leaked to stderr: ($forbidden)"
        }
        assert-no-new-header-artifacts $baseline "capability and malformed framing"
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    assert-no-new-header-artifacts $baseline "failure teardown"
    cleanup $root
    cleanup $infra
    cleanup $fake_dir
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def test-fileless-parallel-interruption-and-redirected-temp [] {
    let root = (make-temp-dir "fileless-header-parallel")
    let infra = (make-temp-dir "fileless-header-parallel-server")
    let clients = (make-temp-dir "fileless-header-clients")
    let redirected_temp = (make-temp-dir "fileless-header-redirected-temp")
    let server = (surface-server $infra)
    let baseline = (response-header-artifacts [$redirected_temp] | get name? | default [])
    mut clients_to_stop = []
    let failure = try {
        surface-workspace $root $server
        let url = $"http://127.0.0.1:($server.port)/acl-slow"
        let wire_before = (command-error-wire-events $server | length)

        let first = (start-secure-client $clients $root $"api get ($url | to nuon) --output none --no-history" "first" $redirected_temp)
        $clients_to_stop = ($clients_to_stop | append $first.pid)
        wait-for-wire-count $server ($wire_before + 1)
        assert (command-error-process-running $first.pid) "interrupt target exited before observation"
        assert-no-new-header-artifacts $baseline "active redirected-temp request" [$redirected_temp]

        let second = (start-secure-client $clients $root $"api get ($url | to nuon) --output none --no-history" "second" $redirected_temp)
        $clients_to_stop = ($clients_to_stop | append $second.pid)
        sleep 200ms
        assert ($first.pid != $second.pid) "parallel requests shared a client process"
        assert (command-error-process-running $second.pid) "parallel request exited before overlap"
        assert-no-new-header-artifacts $baseline "parallel active requests" [$redirected_temp]

        stop-secure-process-tree $first.pid $clients
        $clients_to_stop = ($clients_to_stop | where {|pid| $pid != $first.pid })
        assert-no-new-header-artifacts $baseline "controlled interruption" [$redirected_temp]

        wait-for-secure-process $second.pid false 400
        $clients_to_stop = ($clients_to_stop | where {|pid| $pid != $second.pid })
        assert equal (open $second.stderr --raw | str trim) "" "completed parallel request wrote diagnostics"
        assert-no-new-header-artifacts $baseline "parallel completion" [$redirected_temp]
        null
    } catch {|error| $error }

    for pid in $clients_to_stop {
        if (command-error-process-running $pid) {
            try { stop-secure-process-tree $pid $clients }
        }
    }
    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    assert-no-new-header-artifacts $baseline "parallel teardown" [$redirected_temp]
    cleanup $root
    cleanup $infra
    cleanup $clients
    cleanup $redirected_temp
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def test-fileless-windows-latency-regression [] {
    if $nu.os-info.name != "windows" {
        print "  [capability gated: Windows process-startup latency regression runs on Windows]"
        return
    }

    let root = (make-temp-dir "fileless-header-latency")
    let infra = (make-temp-dir "fileless-header-latency-server")
    let server = (surface-server $infra)
    let baseline = (response-header-artifacts | get name? | default [])
    let failure = try {
        surface-workspace $root $server
        let url = $"http://127.0.0.1:($server.port)/success"
        let retry_url = $"http://127.0.0.1:($server.port)/http-error"
        let null_device = "NUL"

        for _ in 1..2 {
            let direct_warmup = (curl --silent --output $null_device $url | complete)
            assert equal $direct_warmup.exit_code 0 "direct curl warm-up failed"
            api get $url --output none --no-history
        }

        let direct_samples = (measure-latency 7 {
            let result = (curl --silent --output $null_device $url | complete)
            assert equal $result.exit_code 0 "direct curl benchmark request failed"
        })
        let nurl_samples = (measure-latency 7 {
            api get $url --output none --no-history
        })
        let retry_started = (date now)
        api get $retry_url --output none --retries 2 --no-history
        let retry_ms = (((date now) - $retry_started) / 1ms)
        let direct = (summarize-latency $direct_samples)
        let nurl = (summarize-latency $nurl_samples)
        let added_median = ($nurl.median_ms - $direct.median_ms)

        assert ($added_median < 1500) $"fileless response metadata added too much median latency: ($added_median) ms"
        assert ($nurl.p95_ms < ($direct.p95_ms + 2000)) $"fileless response metadata added too much p95 latency: direct=($direct.p95_ms) ms, nurl=($nurl.p95_ms) ms"
        assert ($retry_ms < 5000) $"three-attempt local retry exceeded the regression ceiling: ($retry_ms) ms"
        assert-no-new-header-artifacts $baseline "latency benchmark"
        print $"  [latency proof: 2 warm-ups, 7 samples; direct median/p95=($direct.median_ms)/($direct.p95_ms) ms; Nurl median/p95=($nurl.median_ms)/($nurl.p95_ms) ms; three attempts=($retry_ms | math round --precision 2) ms]"
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    assert-no-new-header-artifacts $baseline "latency teardown"
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

export def run-suite-secure-header-capture [] {
    print "\n=== Fileless Response-Header Transport Tests ==="
    [
        (run-test "fileless headers preserve structured responses without secret/frame leaks" { test-fileless-header-correctness-and-secrecy })
        (run-test "fileless failures, retries, capability checks, and malformed frames create no artifacts" { test-fileless-failure-retry-and-capability-contracts })
        (run-test "fileless parallel, interruption, and redirected-temp paths create no artifacts" { test-fileless-parallel-interruption-and-redirected-temp })
        (run-test "Windows local-request latency excludes cold PowerShell regressions" { test-fileless-windows-latency-regression })
    ]
}
