# Response-header capture confidentiality and lifecycle regressions.

def secure-capture-artifacts [] {
    try {
        ls -la $nu.temp-dir
            | where {|entry| ($entry.name | path basename) | str starts-with "nurl-response-headers-" }
    } catch {
        []
    }
}

def secure-posix-mode [path: string] {
    let gnu = (^stat -c "%a" $path | complete)
    let raw = if $gnu.exit_code == 0 {
        $gnu.stdout | str trim
    } else {
        let bsd = (^stat -f "%Lp" $path | complete)
        assert equal $bsd.exit_code 0 "could not inspect private capture permissions"
        $bsd.stdout | str trim
    }
    $raw | into int
}

def assert-private-capture [path: string] {
    let dir = (ls -la ($path | path dirname)
        | where {|entry| ($entry.name | path basename) == ($path | path basename) }
        | first)
    assert equal $dir.type "dir" "response-header capture is not a directory"
    assert equal ($dir.target? | default null) null "response-header capture is a link or reparse point"

    let header_path = ($path | path join "headers")
    let header = (ls -la $path
        | where {|entry| ($entry.name | path basename) == "headers" }
        | first)
    assert equal $header.type "file" "response-header capture payload is not a file"
    assert equal ($header.target? | default null) null "response-header capture payload is a link or reparse point"

    if $nu.os-info.name != "windows" {
        assert equal (secure-posix-mode $path) 700 "response-header capture directory mode is not 0700"
        assert equal (secure-posix-mode $header_path) 600 "response-header capture file mode is not 0600"
    }
}

def wait-for-secure-process [pid: int, expected_running: bool, attempts: int = 200] {
    mut reached = false
    for _ in 1..$attempts {
        let running = (command-error-process-running $pid)
        if $running == $expected_running {
            $reached = true
            break
        }
        sleep 50ms
    }
    assert $reached $"process ($pid) did not reach the expected state"
}

def secure-python [] {
    let candidate = (which python3 | append (which python) | where type == "external" | get command | first)
    if ($candidate | is-empty) {
        error make {msg: "Python is required for POSIX secure-capture process tests"}
    }
    $candidate
}

def start-secure-client [tmp: string, root: string, command: string, label: string] {
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
        'param($Exe, $Script, $Stdout, $Stderr)
$process = Start-Process -PassThru -WindowStyle Hidden -FilePath $Exe -ArgumentList @("--no-config-file", $Script) -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
Wait-Process -Id $process.Id
' | save -f $worker
        let launcher_source = "param($Worker, $Exe, $Script, $Stdout, $Stderr)
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
    ('\"{0}\"' -f $Stderr)
)
$process = Start-Process -PassThru -WindowStyle Hidden -FilePath 'powershell.exe' -ArgumentList $arguments
[Console]::Out.Write($process.Id)
"
        $launcher_source | save -f $launcher
        ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcher $worker $nu.current-exe $script $stdout $stderr | complete
    } else {
        let launcher = ($tmp | path join $"($label)-launcher.py")
        'import os
import subprocess
import sys

os.umask(0o022)
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
        ^$python $launcher $nu.current-exe $script $stdout $stderr | complete
    }
    assert equal $launched.exit_code 0 $"could not launch secure capture client: ($launched.stderr)"
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

def assert-no-secure-captures [label: string] {
    assert equal (secure-capture-artifacts | length) 0 $"($label) left response-header capture artifacts"
}

def test-secure-header-capture-lifecycle [] {
    let root = (make-temp-dir "secure-header-lifecycle")
    let infra = (make-temp-dir "secure-header-lifecycle-server")
    let server = (surface-server $infra)
    let failure = try {
        surface-workspace $root $server
        assert-no-secure-captures "test baseline"
        let base = $"http://127.0.0.1:($server.port)"

        let success = (run-command-process $root $"api get (($base + '/success') | to nuon) --output none --no-history")
        assert equal $success.exit_code 0 "successful request failed"
        assert-no-secure-captures "success"

        let http_error = (run-command-process $root $"api get (($base + '/http-error') | to nuon) --output status --retries 2 --no-history")
        assert equal ($http_error.stdout | str trim) "503" "HTTP error response was not preserved"
        assert-no-secure-captures "HTTP error and retry"

        run-command-process $root "api get 'http://127.0.0.1:1/connection-failure' --output none --retries 1 --no-history" | ignore
        assert-no-secure-captures "curl connection failure"

        let config_path = ($root | path join "config.nuon")
        open $config_path | upsert timeout_seconds 1 | save -f $config_path
        run-command-process $root $"api get (($base + '/timeout') | to nuon) --output none --no-history" | ignore
        assert-no-secure-captures "curl timeout"
        open $config_path | upsert timeout_seconds 30 | save -f $config_path

        let wire_before_selection = (command-error-wire-events $server | length)
        run-command-process $root $"api get (($base + '/post-capture-failure') | to nuon) --select response.body.missing --no-history" | ignore
        assert equal (command-error-wire-events $server | length) ($wire_before_selection + 1) "post-capture output selection path did not execute"
        assert-no-secure-captures "post-capture output selection failure"

        let sensitive_command = ("let result = (api get "
            + (($base + "/sensitive-headers") | to nuon)
            + " --raw); if ($result.response.headers | get 'Set-Cookie') != 'session=RESPONSE-COOKIE-SENTINEL; HttpOnly' { error make {msg: 'cookie header was not parsed'} }; if ($result.response.headers | get 'X-Session-Token') != 'RESPONSE-TOKEN-SENTINEL' { error make {msg: 'token header was not parsed'} }; if ($result.response.headers | get 'X-Debug-Auth') != 'Bearer RESPONSE-BEARER-SENTINEL' { error make {msg: 'bearer-like header was not parsed'} }; print 'sensitive response headers parsed'")
        let sensitive = (run-command-process $root $sensitive_command)
        assert equal $sensitive.exit_code 0 "sensitive response-header parse failed"
        assert ($sensitive.stdout | str contains "sensitive response headers parsed") "sensitive response headers were not parsed"
        let displayed = (run-command-process $root $"api get (($base + '/sensitive-headers') | to nuon) --include --no-history")
        assert ($displayed.stdout | str contains "******") "displayed sensitive response headers were not redacted"

        let persisted = (command-error-snapshot $root | to nuon)
        for secret in ["RESPONSE-COOKIE-SENTINEL" "RESPONSE-TOKEN-SENTINEL" "RESPONSE-BEARER-SENTINEL"] {
            assert (not ($sensitive.stdout | str contains $secret)) "sensitive header leaked to subprocess stdout"
            assert (not ($sensitive.stderr | str contains $secret)) "sensitive header leaked to subprocess stderr"
            assert (not ($displayed.stdout | str contains $secret)) "sensitive header leaked to human output"
            assert (not ($displayed.stderr | str contains $secret)) "sensitive header leaked to human diagnostics"
            assert (not ($persisted | str contains $secret)) "sensitive header leaked to persisted workspace state"
        }
        assert-no-secure-captures "sensitive response"

        let wire_before_malformed = (command-error-wire-events $server | length)
        run-command-process $root $"api get (($base + '/malformed-header') | to nuon) --output none --no-history" | ignore
        assert equal (command-error-wire-events $server | length) ($wire_before_malformed + 1) "malformed response path did not execute"
        assert-no-secure-captures "malformed response handling"
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def test-secure-header-capture-parallel-and-interruption [] {
    let root = (make-temp-dir "secure-header-parallel")
    let infra = (make-temp-dir "secure-header-parallel-server")
    let clients = (make-temp-dir "secure-header-clients")
    let server = (surface-server $infra)
    let failure = try {
        surface-workspace $root $server
        assert-no-secure-captures "parallel test baseline"
        let url = $"http://127.0.0.1:($server.port)/slow"

        let first = (start-secure-client $clients $root $"api get ($url | to nuon) --output none --no-history" "first")
        mut first_path = ""
        for _ in 1..200 {
            let captures = (secure-capture-artifacts)
            if not ($captures | is-empty) {
                $first_path = ($captures | first | get name)
                break
            }
            sleep 50ms
        }
        assert ($first_path != "") $"first request did not expose an active private capture: running=(command-error-process-running $first.pid), stdout=(open $first.stdout --raw), stderr=(open $first.stderr --raw), wire=(open $server.wire_file --raw)"
        assert-private-capture $first_path

        let second = (start-secure-client $clients $root $"api get ($url | to nuon) --output none --no-history" "second")
        mut second_path = ""
        for _ in 1..100 {
            let captures = (secure-capture-artifacts)
            let other = ($captures | where name != $first_path)
            if not ($other | is-empty) {
                $second_path = ($other | first | get name)
                break
            }
            sleep 50ms
        }
        assert ($second_path != "") $"parallel request did not use a distinct private capture: (open $second.stderr --raw)"
        assert ($second_path != $first_path) "parallel requests shared response-header capture storage"
        assert-private-capture $second_path

        stop-secure-process-tree $first.pid $clients
        if ($first_path | path exists) {
            assert-private-capture $first_path
            rm -rf $first_path
        }

        wait-for-secure-process $second.pid false 400
        assert (not ($second_path | path exists)) "completed parallel request left private capture storage"
        assert equal (open $second.stderr --raw | str trim) "" "parallel request wrote diagnostics"
        assert-no-secure-captures "parallel and interrupted requests"
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    for capture in (secure-capture-artifacts) {
        assert-private-capture $capture.name
        rm -rf $capture.name
    }
    cleanup $root
    cleanup $infra
    cleanup $clients
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

export def run-suite-secure-header-capture [] {
    print "\n=== Secure Response-Header Capture Tests ==="
    [
        (run-test "private capture lifecycle and redaction" { test-secure-header-capture-lifecycle })
        (run-test "private capture parallelism and interruption" { test-secure-header-capture-parallel-and-interruption })
    ]
}
