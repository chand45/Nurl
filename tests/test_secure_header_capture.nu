# Response-header capture confidentiality and lifecycle regressions.

def secure-capture-root [] {
    if $nu.os-info.name == "windows" {
        ($env.LOCALAPPDATA | path join "NurlPrivateHttp")
    } else {
        $nu.temp-dir
    }
}

def secure-capture-artifacts [] {
    let root = (secure-capture-root)
    if not ($root | path exists) {
        return []
    }
    try {
        ls -la $root
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

def windows-acl-snapshot [path: string] {
    let system_root = $env.SystemRoot
    let powershell = ($system_root | path join "System32" "WindowsPowerShell" "v1.0" "powershell.exe")
    let ps_modules = ($system_root | path join "System32" "WindowsPowerShell" "v1.0" "Modules")
    let script = '
$ErrorActionPreference = "Stop"
$path = $env:NURL_ACL_PATH
$item = Get-Item -Force -LiteralPath $path
$acl = Get-Acl -LiteralPath $path
$rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object {
    [pscustomobject]@{
        sid = $_.IdentityReference.Value
        rights = [int]$_.FileSystemRights
        type = $_.AccessControlType.ToString()
        inherited = $_.IsInherited
        inheritance = [int]$_.InheritanceFlags
        propagation = [int]$_.PropagationFlags
    }
})
$fsutil = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) "fsutil.exe"
$identityOutput = @(& $fsutil file queryFileId $item.FullName 2>$null)
if ($LASTEXITCODE -ne 0) { throw "identity query failed" }
$matches = [regex]::Matches(($identityOutput -join " "), "0x[0-9A-Fa-f]+")
if ($matches.Count -ne 1) { throw "identity parse failed" }
[pscustomobject]@{
    owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    current = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    protected = $acl.AreAccessRulesProtected
    reparse = (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    identity = $matches[0].Value.ToLowerInvariant()
    rules = $rules
} | ConvertTo-Json -Depth 5 -Compress
'
    let result = (with-env {NURL_ACL_PATH: $path, PSModulePath: $ps_modules} {
        ^$powershell -NoProfile -NonInteractive -Command $script | complete
    })
    assert equal $result.exit_code 0 $"could not inspect Windows capture ACL: ($result.stderr)"
    $result.stdout | from json
}

def assert-private-windows-acl [path: string, directory: bool] {
    let acl = (windows-acl-snapshot $path)
    let trusted = [$acl.current "S-1-5-18" "S-1-5-32-544"]
    assert $acl.protected "Windows capture DACL inheritance is not disabled"
    assert equal $acl.owner $acl.current "Windows capture owner is not the current user SID"
    assert (not $acl.reparse) $"Windows capture entry is a reparse point: directory=($directory), path=($path)"
    assert ($acl.identity | str starts-with "0x") "Windows capture file identity was not recorded"
    assert equal ($acl.rules | length) 3 "Windows capture DACL has unexpected entries"
    for rule in $acl.rules {
        assert ($rule.sid in $trusted) "Windows capture DACL grants an untrusted SID"
        assert equal $rule.type "Allow" "Windows capture DACL contains a deny or unknown ACE"
        assert (not $rule.inherited) "Windows capture DACL contains inherited ACEs"
        assert equal $rule.rights 2032127 "Windows capture trusted ACE is not FullControl"
        assert equal $rule.inheritance (if $directory { 3 } else { 0 }) "Windows capture ACE inheritance is invalid"
        assert equal $rule.propagation 0 "Windows capture ACE propagation is invalid"
    }
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

    if $nu.os-info.name == "windows" {
        assert-private-windows-acl (secure-capture-root) true
        assert-private-windows-acl $path true
        assert-private-windows-acl $header_path false
    } else {
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

def start-secure-client [tmp: string, root: string, command: string, label: string, redirected_temp: string = ""] {
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

def make-broad-windows-temp [path: string] {
    mkdir $path
    let system_root = $env.SystemRoot
    let powershell = ($system_root | path join "System32" "WindowsPowerShell" "v1.0" "powershell.exe")
    let ps_modules = ($system_root | path join "System32" "WindowsPowerShell" "v1.0" "Modules")
    let script = '
$ErrorActionPreference = "Stop"
$path = $env:NURL_ACL_PATH
$current = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$users = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-545")
$authenticated = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-11")
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetOwner($current)
$acl.SetAccessRuleProtection($true, $false)
$inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
$none = [System.Security.AccessControl.PropagationFlags]::None
$allow = [System.Security.AccessControl.AccessControlType]::Allow
[void]$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($current, [System.Security.AccessControl.FileSystemRights]::FullControl, $inheritance, $none, $allow)))
[void]$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($users, [System.Security.AccessControl.FileSystemRights]::ReadAndExecute, $inheritance, $none, $allow)))
[void]$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($authenticated, [System.Security.AccessControl.FileSystemRights]::Modify, $inheritance, $none, $allow)))
Set-Acl -LiteralPath $path -AclObject $acl
'
    let result = (with-env {NURL_ACL_PATH: $path, PSModulePath: $ps_modules} {
        ^$powershell -NoProfile -NonInteractive -Command $script | complete
    })
    assert equal $result.exit_code 0 "could not create deliberately broad Windows temp ACL"
    let broad = (windows-acl-snapshot $path)
    assert ($broad.rules | any {|rule| $rule.sid == "S-1-5-11" and ($rule.rights bit-and 2) != 0 }) "broad temp fixture lacks authenticated-user write access"
    assert ($broad.rules | any {|rule| $rule.sid == "S-1-5-32-545" and ($rule.rights bit-and 131209) != 0 }) "broad temp fixture lacks users read access"
}

def inject-broad-capture-ace [path: string] {
    let system_root = $env.SystemRoot
    let powershell = ($system_root | path join "System32" "WindowsPowerShell" "v1.0" "powershell.exe")
    let ps_modules = ($system_root | path join "System32" "WindowsPowerShell" "v1.0" "Modules")
    let script = '
$ErrorActionPreference = "Stop"
$path = $env:NURL_ACL_PATH
$sid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-11")
$acl = Get-Acl -LiteralPath $path
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, [System.Security.AccessControl.FileSystemRights]::Read, [System.Security.AccessControl.AccessControlType]::Allow)
[void]$acl.AddAccessRule($rule)
Set-Acl -LiteralPath $path -AclObject $acl
'
    let result = (with-env {NURL_ACL_PATH: $path, PSModulePath: $ps_modules} {
        ^$powershell -NoProfile -NonInteractive -Command $script | complete
    })
    assert equal $result.exit_code 0 "could not inject unsafe ACL for fail-closed regression"
}

def attempt-capture-replacement [path: string] {
    let system_root = $env.SystemRoot
    let powershell = ($system_root | path join "System32" "WindowsPowerShell" "v1.0" "powershell.exe")
    let script = '
$ErrorActionPreference = "Stop"
$path = $env:NURL_ACL_PATH
try {
    Remove-Item -Force -LiteralPath $path
} catch {
    "blocked"
    exit 0
}
try {
    [System.IO.File]::WriteAllText($path, "replacement")
    "replaced"
} catch {
    "deleted"
}
'
    let result = (with-env {NURL_ACL_PATH: $path} {
        ^$powershell -NoProfile -NonInteractive -Command $script | complete
    })
    assert equal $result.exit_code 0 "capture replacement probe failed"
    $result.stdout | str trim
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

def assert-no-new-secure-captures [baseline_paths: list, label: string] {
    let unexpected = (secure-capture-artifacts | where {|capture| $capture.name not-in $baseline_paths })
    assert equal ($unexpected | length) 0 $"($label) left response-header capture artifacts"
}

def test-secure-header-capture-lifecycle [] {
    let root = (make-temp-dir "secure-header-lifecycle")
    let infra = (make-temp-dir "secure-header-lifecycle-server")
    let server = (surface-server $infra)
    let baseline_paths = (secure-capture-artifacts | get name? | default [])
    let failure = try {
        surface-workspace $root $server
        let base = $"http://127.0.0.1:($server.port)"

        let success = (run-command-process $root $"api get (($base + '/success') | to nuon) --output none --no-history")
        assert equal $success.exit_code 0 "successful request failed"
        assert-no-new-secure-captures $baseline_paths "success"

        if $nu.os-info.name == "windows" {
            let wire_before_acl_unavailable = (command-error-wire-events $server | length)
            let unavailable = (run-command-process $root (
                "$env.SystemRoot = 'C:\\nurl-missing-system-root'; api get "
                + (($base + "/acl-unavailable") | to nuon)
                + " --output none --no-history"
            ))
            assert ($unavailable.exit_code != 0) "missing Windows ACL facility did not fail closed"
            assert equal ($unavailable.stdout | str trim) "" "missing Windows ACL facility wrote stdout"
            assert ($unavailable.stderr | str contains "ACL protection is unavailable") "missing Windows ACL facility diagnostic was not actionable"
            assert equal (command-error-wire-events $server | length) $wire_before_acl_unavailable "missing Windows ACL facility reached the network"
            assert-no-new-secure-captures $baseline_paths "missing Windows ACL facility"
        }

        let http_error = (run-command-process $root $"api get (($base + '/http-error') | to nuon) --output status --retries 2 --no-history")
        assert equal ($http_error.stdout | str trim) "503" "HTTP error response was not preserved"
        assert-no-new-secure-captures $baseline_paths "HTTP error and retry"

        run-command-process $root "api get 'http://127.0.0.1:1/connection-failure' --output none --retries 1 --no-history" | ignore
        assert-no-new-secure-captures $baseline_paths "curl connection failure"

        let config_path = ($root | path join "config.nuon")
        open $config_path | upsert timeout_seconds 1 | save -f $config_path
        run-command-process $root $"api get (($base + '/timeout') | to nuon) --output none --no-history" | ignore
        assert-no-new-secure-captures $baseline_paths "curl timeout"
        open $config_path | upsert timeout_seconds 30 | save -f $config_path

        let wire_before_selection = (command-error-wire-events $server | length)
        run-command-process $root $"api get (($base + '/post-capture-failure') | to nuon) --select response.body.missing --no-history" | ignore
        assert equal (command-error-wire-events $server | length) ($wire_before_selection + 1) "post-capture output selection path did not execute"
        assert-no-new-secure-captures $baseline_paths "post-capture output selection failure"

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
        assert-no-new-secure-captures $baseline_paths "sensitive response"

        let wire_before_malformed = (command-error-wire-events $server | length)
        run-command-process $root $"api get (($base + '/malformed-header') | to nuon) --output none --no-history" | ignore
        assert equal (command-error-wire-events $server | length) ($wire_before_malformed + 1) "malformed response path did not execute"
        assert-no-new-secure-captures $baseline_paths "malformed response handling"
        null
    } catch {|error| $error }

    for capture in (secure-capture-artifacts | where {|capture| $capture.name not-in $baseline_paths }) {
        assert-private-capture $capture.name
        rm -rf $capture.name
    }
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
    let baseline_paths = (secure-capture-artifacts | get name? | default [])
    mut owned_paths = []
    let failure = try {
        surface-workspace $root $server
        let url = $"http://127.0.0.1:($server.port)/acl-slow"

        let first = (start-secure-client $clients $root $"api get ($url | to nuon) --output none --no-history" "first")
        mut first_path = ""
        for _ in 1..200 {
            let captures = (secure-capture-artifacts)
            let ready = ($captures
                | where {|capture| $capture.name not-in $baseline_paths }
                | where {|capture| ($capture.name | path join "headers") | path exists })
            if not ($ready | is-empty) {
                $first_path = ($ready | first | get name)
                $owned_paths = ($owned_paths | append $first_path)
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
            let other = ($captures
                | where {|capture| $capture.name not-in $baseline_paths and $capture.name != $first_path }
                | where {|capture| ($capture.name | path join "headers") | path exists })
            if not ($other | is-empty) {
                $second_path = ($other | first | get name)
                $owned_paths = ($owned_paths | append $second_path)
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
        assert (not ($first_path | path exists)) "interrupted request left its private capture"
        assert (not ($second_path | path exists)) "completed parallel request left its private capture"
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    for path in $owned_paths {
        if ($path | path exists) {
            assert-private-capture $path
            rm -rf $path
        }
    }
    assert-no-new-secure-captures $baseline_paths "parallel test teardown"
    cleanup $root
    cleanup $infra
    cleanup $clients
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def test-windows-broad-temp-and-acl-tampering [] {
    if $nu.os-info.name != "windows" {
        print "  [capability gated: Windows DACL assertions run on Windows]"
        return
    }
    let root = (make-temp-dir "secure-header-windows")
    let infra = (make-temp-dir "secure-header-windows-server")
    let clients = (make-temp-dir "secure-header-windows-clients")
    let broad_parent = (make-temp-dir "secure-header-broad-parent")
    let broad_temp = ($broad_parent | path join "shared temp")
    let server = (surface-server $infra)
    let baseline_paths = (secure-capture-artifacts | get name? | default [])
    mut owned_paths = []
    mut client_pids = []
    let failure = try {
        make-broad-windows-temp $broad_temp
        surface-workspace $root $server
        let url = $"http://127.0.0.1:($server.port)/acl-slow"

        let replace_client = (start-secure-client $clients $root $"api get ($url | to nuon) --output none --no-history" "replace" $broad_temp)
        $client_pids = ($client_pids | append $replace_client.pid)
        mut replace_path = ""
        for _ in 1..200 {
            let captures = (secure-capture-artifacts)
            let ready = ($captures
                | where {|capture| $capture.name not-in $baseline_paths }
                | where {|capture| ($capture.name | path join "headers") | path exists })
            if not ($ready | is-empty) {
                $replace_path = ($ready | first | get name)
                $owned_paths = ($owned_paths | append $replace_path)
                break
            }
            sleep 50ms
        }
        assert ($replace_path != "") "redirected broad-temp request did not create a private capture"
        assert (not ($replace_path | str starts-with $broad_temp)) "Windows capture used the redirected broad temp root"
        assert-private-capture $replace_path
        let original_identity = (windows-acl-snapshot ($replace_path | path join "headers") | get identity)
        let replacement = (attempt-capture-replacement ($replace_path | path join "headers"))
        if $replacement == "blocked" {
            assert equal (windows-acl-snapshot ($replace_path | path join "headers") | get identity) $original_identity "blocked replacement changed file identity"
        }
        wait-for-secure-process $replace_client.pid false 400
        if $replacement != "blocked" {
            assert ((open $replace_client.stderr --raw) | str contains "private Windows response-header") "same-shape replacement did not fail closed"
        } else {
            assert equal (open $replace_client.stderr --raw | str trim) "" "blocked replacement broke the request"
        }
        if ($replace_path | path exists) {
            rm -rf $replace_path
        }

        let acl_client = (start-secure-client $clients $root $"api get ($url | to nuon) --output none --no-history" "unsafe-acl" $broad_temp)
        $client_pids = ($client_pids | append $acl_client.pid)
        mut acl_path = ""
        for _ in 1..200 {
            let captures = (secure-capture-artifacts)
            let ready = ($captures
                | where {|capture| $capture.name not-in $baseline_paths and $capture.name not-in $owned_paths }
                | where {|capture| ($capture.name | path join "headers") | path exists })
            if not ($ready | is-empty) {
                $acl_path = ($ready | first | get name)
                $owned_paths = ($owned_paths | append $acl_path)
                break
            }
            sleep 50ms
        }
        assert ($acl_path != "") "unsafe-ACL request did not create a private capture"
        assert-private-capture $acl_path
        inject-broad-capture-ace ($acl_path | path join "headers")
        wait-for-secure-process $acl_client.pid false 400
        let acl_error = (open $acl_client.stderr --raw)
        assert ($acl_error | str contains "private Windows response-header") "unsafe capture ACL did not fail closed"
        assert equal $acl_error ($acl_error | ansi strip) "unsafe ACL diagnostic contained ANSI"
        for secret in ["RESPONSE-COOKIE-SENTINEL" "RESPONSE-TOKEN-SENTINEL"] {
            assert (not ($acl_error | str contains $secret)) "unsafe ACL diagnostic leaked response-header data"
        }
        assert (not ($acl_path | path exists)) "unsafe same-identity capture was not securely removed"
        assert (not ($replace_path | path exists)) "replacement probe left its capture"
        assert (not ($acl_path | path exists)) "unsafe ACL probe left its capture"
        print $"  [Windows ACL proof: redirected broad temp ignored; SID-only protected DACLs; replacement probe=($replacement); unsafe ACE rejected]"
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    for pid in $client_pids {
        if (command-error-process-running $pid) {
            try { stop-secure-process-tree $pid $clients }
        }
    }
    for path in $owned_paths {
        if ($path | path exists) {
            try { rm -rf $path }
        }
    }
    assert-no-new-secure-captures $baseline_paths "Windows ACL test teardown"
    cleanup $root
    cleanup $infra
    cleanup $clients
    cleanup $broad_parent
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

export def run-suite-secure-header-capture [] {
    print "\n=== Secure Response-Header Capture Tests ==="
    [
        (run-test "private capture lifecycle and redaction" { test-secure-header-capture-lifecycle })
        (run-test "private capture parallelism and interruption" { test-secure-header-capture-parallel-and-interruption })
        (run-test "Windows captures ignore broad temp ACLs and fail closed on tampering" { test-windows-broad-temp-and-acl-tampering })
    ]
}
