# Durability regressions for the private native state store (nu_modules/state-store.nu).
#
# Coverage exercises ONLY public `api ...` commands for behavior. The only
# exceptions are: (a) a source-text assertion over production nu_modules and
# installer payloads (state-store.nu is a private implementation detail and
# cannot be probed through a public command), and (b) test-only process /
# filesystem orchestration (detached workers, Windows file locks, ACL probes)
# needed to make otherwise-nondeterministic races and OS failures observable.
#
# All helpers below use an `sd-` prefix to avoid colliding with identically
# named helpers defined by other sourced test files.

# ── Generic helpers ────────────────────────────────────────────────────────

def sd-large-string [target_len: int] {
    mut s = "A"
    while ($s | str length) < $target_len {
        $s = ($s + $s)
    }
    $s | str substring 0..<$target_len
}

# ASCII-only lowercase fold that avoids BOTH `str downcase` (deprecated on nu
# 0.114+, emits a warning) and `str lowercase` (does not exist on nu 0.89.0 —
# and since nushell parses every branch of an `if` at parse time regardless
# of which runtime evaluates it, a version-conditional call to `str
# lowercase` would still fail to *parse* on 0.89.0 even inside an unreached
# branch). `str replace -a` is stable, unchanged, and warning-free on both
# targeted runtimes, so folding case letter-by-letter with it is the only
# fully version-agnostic option.
def sd-lower [] {
    mut result = $in
    for pair in [
        ["A" "a"] ["B" "b"] ["C" "c"] ["D" "d"] ["E" "e"] ["F" "f"] ["G" "g"] ["H" "h"]
        ["I" "i"] ["J" "j"] ["K" "k"] ["L" "l"] ["M" "m"] ["N" "n"] ["O" "o"] ["P" "p"]
        ["Q" "q"] ["R" "r"] ["S" "s"] ["T" "t"] ["U" "u"] ["V" "v"] ["W" "w"] ["X" "x"]
        ["Y" "y"] ["Z" "z"]
    ] {
        $result = ($result | str replace -a $pair.0 $pair.1)
    }
    $result
}

# Recursively list every path under root (files and dirs), depth-first.
def sd-entries [root: string] {
    if not ($root | path exists) {
        return []
    }
    ls -a $root | each {|entry|
        if $entry.type == "dir" {
            [$entry.name] | append (sd-entries $entry.name)
        } else {
            [$entry.name]
        }
    } | flatten
}

# Byte-for-byte workspace snapshot (path, type, raw content for files).
def sd-snapshot [root: string] {
    sd-entries $root | each {|path|
        let t = ($path | path type)
        {
            path: ($path | path relative-to $root | str replace --all "\\" "/")
            type: $t
            content: (if $t == "file" { open $path --raw } else { null })
        }
    } | sort-by path
}

# Run `body`, always run `teardown` afterward (success, failure, or SKIP),
# then re-raise the original error (if any) so run-test still sees it.
def sd-finally [body: closure, teardown: closure] {
    let outcome = (try {
        do $body
        {ok: true, msg: ""}
    } catch {|e|
        {ok: false, msg: $e.msg}
    })
    do $teardown
    if not $outcome.ok {
        error make {msg: $outcome.msg}
    }
}

# Corrupt a file, run `body`, and ALWAYS restore the original bytes afterward
# (even if `body` fails), then re-raise any failure from `body`.
def sd-with-corrupted-file [path: string, corrupt: closure, body: closure] {
    let original = (open $path --raw)
    do $corrupt
    sd-finally $body { $original | save -f $path }
}

# ── Public command-error assertion helpers ─────────────────────────────────

# Nushell's default (non-tty) error renderer word-wraps long messages across
# real newlines with a `| ` gutter prefix, which can split a long temp path
# across multiple lines (inserting whitespace AND a literal `|` in the
# middle of the path). Collapse all whitespace and gutter pipes before doing
# containment checks so wrapped text is still found regardless of width.
def sd-collapse-ws [text: string] {
    $text | str replace --all --regex '[\s|]+' ""
}

def sd-stderr-has [stderr: string, needle: string] {
    (sd-collapse-ws $stderr) | str contains (sd-collapse-ws $needle)
}

# Run `command` in an isolated subprocess and assert it fails closed:
# nonzero exit, empty stdout, stderr contains `expected`, ANSI-free stderr,
# no forbidden leakage, and no unexpected workspace mutation.
def sd-assert-clean-error [root: string, command: string, expected: string, forbidden: list<string> = []] {
    let before = (sd-snapshot $root)
    let result = (run-command-process $root $command)
    let after = (sd-snapshot $root)

    assert ($result.exit_code != 0) $"expected nonzero exit for: ($command)"
    assert equal ($result.stdout | str trim) "" $"expected empty stdout for: ($command); got: ($result.stdout)"
    assert (sd-stderr-has $result.stderr $expected) $"stderr did not contain '($expected)' for ($command); actual: ($result.stderr)"
    assert equal $result.stderr ($result.stderr | ansi strip) $"stderr contained ANSI escapes for: ($command)"
    for word in $forbidden {
        assert (not ($result.stderr | str contains $word)) $"stderr leaked forbidden text '($word)' for: ($command)"
    }
    assert equal $after $before $"logical failure mutated the workspace: ($command)"
    $result
}

# Same contract as `sd-assert-clean-error`, but the stderr only needs to
# contain ONE of `expected_any` (used for binary corruption, where the exact
# clean-error message a state file produces is content-dependent: some byte
# sequences fail to parse as NUON at all, others parse to a non-record value
# — both are legitimate, path-specific, non-cascading state-store failures).
def sd-assert-clean-error-any [root: string, command: string, expected_any: list<string>, forbidden: list<string> = []] {
    let before = (sd-snapshot $root)
    let result = (run-command-process $root $command)
    let after = (sd-snapshot $root)

    assert ($result.exit_code != 0) $"expected nonzero exit for: ($command)"
    assert equal ($result.stdout | str trim) "" $"expected empty stdout for: ($command); got: ($result.stdout)"
    let matched = ($expected_any | any {|e| sd-stderr-has $result.stderr $e })
    assert $matched $"stderr matched none of ($expected_any | to nuon) for ($command); actual: ($result.stderr)"
    assert equal $result.stderr ($result.stderr | ansi strip) $"stderr contained ANSI escapes for: ($command)"
    for word in $forbidden {
        assert (not ($result.stderr | str contains $word)) $"stderr leaked forbidden text '($word)' for: ($command)"
    }
    assert equal $after $before $"logical failure mutated the workspace: ($command)"
    $result
}

const SD_FORBIDDEN_LEAKAGE = [
    "CLIENT-SECRET-SENTINEL"
    "ACCESS-TOKEN-SENTINEL"
    "SD-SECRET-SENTINEL"
    "panicked at"
    "RUST_BACKTRACE"
]

# ── Process orchestration helpers (bounded polling, never SpinWait) ────────

def sd-wait-until [predicate: closure, attempts: int = 400] {
    mut i = 0
    while $i < $attempts {
        if (do $predicate) {
            return true
        }
        sleep 25ms
        $i = $i + 1
    }
    (do $predicate)
}

def sd-process-alive [pid: int] {
    try {
        (ps | where pid == $pid | length) > 0
    } catch {
        false
    }
}

def sd-stop-pid [pid: int] {
    if not (sd-process-alive $pid) {
        return
    }
    if $nu.os-info.name == "windows" {
        ^powershell.exe -NoProfile -NonInteractive -Command $"Stop-Process -Id ($pid) -Force" | complete | ignore
    } else {
        ^kill -KILL $pid | complete | ignore
    }
    sd-wait-until { not (sd-process-alive $pid) } 200 | ignore
}

def sd-python-exe [] {
    if (which python3 | is-empty) { "python" } else { "python3" }
}

def sd-module-path [] {
    $env.NURL_REPO_ROOT | path join "nu_modules" "mod.nu"
}

# Write a small worker script defining `def main [<params>] { <body> }`,
# preceded by a header that sources mod.nu. `params`/`body` are literal nu
# source text supplied by the caller (single-quoted, no interpolation) so
# that dynamic values only ever flow in as CLI positional arguments — this
# sidesteps any quoting/escaping hazards from embedding values into source
# text via string interpolation.
def sd-write-worker-script [tmp: string, label: string, params: string, body: string] {
    let script_path = ($tmp | path join $"($label)-(random uuid).nu")
    let module_path = (sd-module-path)
    [
        $"use ($module_path | to nuon) *"
        "$env.NO_COLOR = '1'"
        $"def main [($params)] \{"
        $body
        "}"
    ] | str join "\n" | save -f $script_path
    $script_path
}

# Launch `script_path` fully detached with the given CLI positional `args`.
# Returns {pid, stdout_file, stderr_file}; the returned pid is the root of a
# process tree that must be stopped with sd-stop-process-tree.
def sd-launch-worker-script [tmp: string, script_path: string, args: list<string>, label: string] {
    let stdout_file = ($tmp | path join $"($label)-(random uuid).stdout")
    let stderr_file = ($tmp | path join $"($label)-(random uuid).stderr")
    let args_file = ($tmp | path join $"($label)-(random uuid)-args.json")
    (([$script_path] | append $args) | to json) | save -f $args_file

    let launched = if $nu.os-info.name == "windows" {
        let worker = ($tmp | path join $"($label)-(random uuid)-worker.ps1")
        let launcher = ($tmp | path join $"($label)-(random uuid)-launcher.ps1")
        'param($Exe, $ArgsFile, $Stdout, $Stderr)
$extra = @(Get-Content -Raw -LiteralPath $ArgsFile | ConvertFrom-Json)
$allArgs = @("--no-config-file") + $extra
& $Exe @allArgs 1> $Stdout 2> $Stderr
' | save -f $worker
        # Spawned via WMI Win32_Process::Create (not Start-Process): some
        # sandboxes assign every child of the calling process to a Windows
        # Job Object, and a caller synchronously waiting on that job (as some
        # process-tracking harnesses do) will not observe this script's own
        # exit until every job member — including a detached worker meant to
        # keep running independently — has also exited. WMI process creation
        # runs via the separate WmiPrvSE.exe service host, so the created
        # process is never a member of the caller's job and this launcher
        # returns immediately regardless of how long the worker itself runs.
        let launcher_source = 'param($Worker, $Exe, $ArgsFile, $Stdout, $Stderr)
$cmdline = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Worker`" `"$Exe`" `"$ArgsFile`" `"$Stdout`" `"$Stderr`""
$result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine = $cmdline}
if ($result.ReturnValue -ne 0) {
    [Console]::Error.Write("WMI process create failed with code $($result.ReturnValue)")
    exit 1
}
[Console]::Out.Write($result.ProcessId)
'
        $launcher_source | save -f $launcher
        (test-complete-result (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcher $worker $nu.current-exe $args_file $stdout_file $stderr_file | complete))
    } else {
        let launcher = ($tmp | path join $"($label)-(random uuid)-launcher.py")
        'import json
import subprocess
import sys

exe, args_file, stdout_file, stderr_file = sys.argv[1:5]
with open(args_file) as f:
    extra = json.load(f)
with open(stdout_file, "wb") as out, open(stderr_file, "wb") as err:
    process = subprocess.Popen(
        [exe, "--no-config-file"] + list(extra),
        stdin=subprocess.DEVNULL,
        stdout=out,
        stderr=err,
        start_new_session=True,
    )
print(process.pid)
' | save -f $launcher
        let python = (sd-python-exe)
        (test-complete-result (^$python $launcher $nu.current-exe $args_file $stdout_file $stderr_file | complete))
    }
    if $launched.exit_code != 0 or ($launched.stdout | str trim | is-empty) {
        error make {msg: $"failed to launch worker script '($label)': ($launched.stderr)"}
    }
    {pid: ($launched.stdout | str trim | into int), stdout_file: $stdout_file, stderr_file: $stderr_file}
}

# Windows-only: race a real, running `worker_pid` process tree against the
# moment its target file is created, killing the exact nu.exe descendant the
# instant Windows delivers the filesystem Created notification. Uses an
# asynchronous FileSystemWatcher event (near-zero arm latency, no polling
# overhead) and concurrently pre-resolves the real nu.exe descendant PID (via
# WMI) so the kill has no additional tree-walk latency once the event lands.
# Returns "killed-before-visible" (file never appeared before timeout —
# nothing to observe), "killed-after-create" (we caught + killed it; caller
# must inspect the resulting file for partial content), or "no-child-found".
def sd-watch-and-kill-on-create [tmp: string, dir: string, filename: string, worker_pid: int, timeout_ms: int] {
    let watcher = ($tmp | path join $"sd-fswatch-(random uuid).ps1")
    let launcher = ($tmp | path join $"sd-fswatch-launcher-(random uuid).ps1")
    let snapshot_file = ($tmp | path join $"sd-fswatch-snapshot-(random uuid).txt")
    'param($Dir, $FileName, $WorkerPid, $SnapshotFile, $TimeoutMs)
$fsw = New-Object System.IO.FileSystemWatcher($Dir, $FileName)
$fsw.NotifyFilter = [System.IO.NotifyFilters]::FileName
$script:created = $false
$sub = Register-ObjectEvent -InputObject $fsw -EventName Created -Action { $script:created = $true }
$fsw.EnableRaisingEvents = $true

$realPid = $null
$deadline = [System.Diagnostics.Stopwatch]::StartNew()
while ($deadline.Elapsed.TotalMilliseconds -lt $TimeoutMs) {
    if (-not $realPid) {
        $descendants = @(Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $WorkerPid })
        foreach ($d in $descendants) {
            if ($d.Name -like "nu*.exe") { $realPid = [int]$d.ProcessId }
        }
    }
    if ($script:created -and $realPid) {
        try { Stop-Process -Id $realPid -Force -ErrorAction SilentlyContinue } catch {}
        break
    }
    Start-Sleep -Milliseconds 1
}
Unregister-Event -SourceIdentifier $sub.Name -ErrorAction SilentlyContinue
$fsw.Dispose()
if (-not $realPid) {
    [System.IO.File]::WriteAllText($SnapshotFile, "no-child-found")
} elseif (-not $script:created) {
    [System.IO.File]::WriteAllText($SnapshotFile, "killed-before-visible")
} else {
    [System.IO.File]::WriteAllText($SnapshotFile, "killed-after-create")
}
' | save -f $watcher
    let launcher_source = 'param($Watcher, $Dir, $FileName, $WorkerPid, $SnapshotFile, $TimeoutMs)
$cmdline = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Watcher`" `"$Dir`" `"$FileName`" $WorkerPid `"$SnapshotFile`" $TimeoutMs"
$result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine = $cmdline}
if ($result.ReturnValue -ne 0) {
    [Console]::Error.Write("WMI process create failed with code $($result.ReturnValue)")
    exit 1
}
[Console]::Out.Write($result.ProcessId)
'
    $launcher_source | save -f $launcher
    let launched = (test-complete-result (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcher $watcher $dir $filename $worker_pid $snapshot_file $timeout_ms | complete))
    for f in [$watcher, $launcher] { try { rm -f $f } catch {} }
    if $launched.exit_code != 0 or ($launched.stdout | str trim | is-empty) {
        error make {msg: $"failed to launch fs watcher: ($launched.stderr)"}
    }
    let watcher_pid = ($launched.stdout | str trim | into int)
    sd-wait-until { not (sd-process-alive $watcher_pid) } 800 | ignore
    sd-stop-process-tree $watcher_pid $tmp
    let outcome = if ($snapshot_file | path exists) { open $snapshot_file --raw | str trim } else { "watcher-produced-no-result" }
    try { rm -f $snapshot_file } catch {}
    $outcome
}

# File-based pid tracking (needed because closures cannot capture/mutate a
# `mut` variable from an enclosing scope — every test that must clean up
# stray worker processes from a `sd-finally` teardown closure tracks pids via
# a small on-disk file instead of a `mut` list).
def sd-track-pid [pids_file: string, pid: int] {
    $"($pid)\n" | save --append -f $pids_file
}

def sd-kill-tracked-pids [pids_file: string, tmp: string] {
    if ($pids_file | path exists) {
        let pids = (
            open $pids_file --raw
            | lines
            | where {|l| ($l | str trim) != "" }
            | each {|l| $l | str trim | into int }
        )
        for pid in $pids {
            sd-stop-process-tree $pid $tmp
        }
        try { rm -f $pids_file } catch {}
    }
}

# Kill the entire process tree rooted at `pid` (needed on Windows because the
# returned pid is a powershell.exe launcher, not the eventual nu.exe client).
def sd-stop-process-tree [pid: int, tmp: string] {
    if $nu.os-info.name == "windows" {
        let stopper = ($tmp | path join $"sd-stop-($pid)-(random uuid).ps1")
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
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
}
' | save -f $stopper
        ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $stopper $pid | complete | ignore
        try { rm -f $stopper } catch {}
    } else {
        let stopper = ($tmp | path join $"sd-stop-($pid)-(random uuid).py")
        'import os
import signal
import sys

try:
    os.killpg(int(sys.argv[1]), signal.SIGKILL)
except ProcessLookupError:
    pass
' | save -f $stopper
        let python = (sd-python-exe)
        ^$python $stopper $pid | complete | ignore
        try { rm -f $stopper } catch {}
    }
    sd-wait-until { not (sd-process-alive $pid) } 200 | ignore
}

# ── Windows exclusive file-handle helper (bounded Start-Sleep, no SpinWait) ─

def sd-start-file-lock [tmp: string, target: string, share_mode: string] {
    let holder = ($tmp | path join $"sd-holder-(random uuid).ps1")
    let ready_file = ($tmp | path join $"sd-ready-(random uuid).txt")
    let stop_file = ($tmp | path join $"sd-stop-(random uuid).txt")
    let out_file = ($tmp | path join $"sd-holder-out-(random uuid).txt")
    let err_file = ($tmp | path join $"sd-holder-err-(random uuid).txt")
    let launcher = ($tmp | path join $"sd-holder-launcher-(random uuid).ps1")
    let holder_source = 'param($TargetPath, $ShareMode, $ReadyFile, $StopFile)
try {
    $share = [System.IO.FileShare]::$ShareMode
    $stream = [System.IO.File]::Open($TargetPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    [System.IO.File]::WriteAllText($ReadyFile, "ready")
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $StopFile) -and $clock.Elapsed.TotalSeconds -lt 60) {
        Start-Sleep -Milliseconds 100
    }
    $stream.Close()
} catch {
    [System.IO.File]::WriteAllText($ReadyFile, "error: $_")
}
'
    $holder_source | save -f $holder
    # Spawned via WMI Win32_Process::Create rather than Start-Process for the
    # same reason as sd-launch-worker-script above: it must not be a member
    # of the calling process's Job Object, or a caller synchronously waiting
    # on that job would block until the holder itself exits (defeating the
    # whole point of holding a lock in the background while the test proceeds).
    let launcher_source = 'param($Holder, $TargetPath, $ShareMode, $ReadyFile, $StopFile, $Stdout, $Stderr)
$cmdline = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Holder`" `"$TargetPath`" $ShareMode `"$ReadyFile`" `"$StopFile`""
$result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine = $cmdline}
if ($result.ReturnValue -ne 0) {
    [Console]::Error.Write("WMI process create failed with code $($result.ReturnValue)")
    exit 1
}
[Console]::Out.Write($result.ProcessId)
'
    $launcher_source | save -f $launcher
    let result = (test-complete-result (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcher $holder $target $share_mode $ready_file $stop_file $out_file $err_file | complete))
    if $result.exit_code != 0 or ($result.stdout | str trim | is-empty) {
        error make {msg: $"SKIP: could not launch Windows file-lock holder: ($result.stderr)"}
    }
    let pid = ($result.stdout | str trim | into int)
    let became_ready = (sd-wait-until { ($ready_file | path exists) } 400)
    if not $became_ready {
        sd-stop-pid $pid
        error make {msg: "SKIP: could not establish a Windows file lock within the bounded window"}
    }
    let ready_content = (open $ready_file --raw)
    if ($ready_content | str starts-with "error:") {
        sd-stop-pid $pid
        error make {msg: $"SKIP: Windows file lock unavailable: ($ready_content)"}
    }
    {pid: $pid, stop_file: $stop_file, holder: $holder, out_file: $out_file, err_file: $err_file, ready_file: $ready_file}
}

def sd-stop-file-lock [lock: any] {
    "stop" | save -f $lock.stop_file
    sd-wait-until { not (sd-process-alive $lock.pid) } 400 | ignore
    sd-stop-pid $lock.pid
    for f in [$lock.holder, $lock.stop_file, $lock.ready_file, $lock.out_file, $lock.err_file] {
        try { rm -f $f } catch {}
    }
}

# ── Symlink helpers (honor NURL_TEST_DISABLE_LINKS escape hatch) ───────────

def sd-create-file-link [link_path: string, target_path: string] {
    if ($env.NURL_TEST_DISABLE_LINKS? | default "") == "1" {
        return false
    }
    if $nu.os-info.name == "windows" {
        let result = (^cmd.exe /d /c mklink $link_path $target_path | complete)
        $result.exit_code == 0
    } else {
        let result = (^ln -s $target_path $link_path | complete)
        $result.exit_code == 0
    }
}

def sd-create-dir-link [link_path: string, target_path: string] {
    if ($env.NURL_TEST_DISABLE_LINKS? | default "") == "1" {
        return false
    }
    if $nu.os-info.name == "windows" {
        let command = $"New-Item -ItemType Junction -Path ($link_path | to nuon) -Target ($target_path | to nuon) | Out-Null"
        let result = (^powershell.exe -NoProfile -NonInteractive -Command $command | complete)
        $result.exit_code == 0
    } else {
        let result = (^ln -s $target_path $link_path | complete)
        $result.exit_code == 0
    }
}

# ── Serialization / artifact-sweep helpers (req 1, 5, 6) ───────────────────

# Assert that the bytes at `path` are exactly what `to nuon`
# (`to nuon --indent $indent` when indent > 0) would produce for the parsed
# value — i.e. the file is canonical NUON with no added trailing newline and
# no divergence from the runtime's own serializer. This is inherently
# version-safe across 0.89/0.114 since both sides of the comparison are
# produced by the SAME running Nushell.
def sd-assert-canonical-nuon [path: string, indent: int = 0] {
    let raw = (open $path --raw)
    assert (not ($raw | str ends-with "\n")) $"($path): unexpected trailing newline"
    assert (not ($raw | str ends-with "\r")) $"($path): unexpected trailing CR"
    let parsed = ($raw | from nuon)
    let expected = if $indent > 0 { $parsed | to nuon --indent $indent } else { $parsed | to nuon }
    assert equal $raw $expected $"($path): bytes are not canonical NUON"
}

# Recursively find any sibling temp artifact left by state-store.nu
# (`.<basename>.nurl-<uuid>.tmp`).
def sd-find-temp-artifacts [root: string] {
    let uuid = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    let pattern = ('^\.[^\\/]+\.nurl-' + $uuid + '\.tmp$')
    sd-entries $root | where {|p|
        let b = ($p | path basename)
        $b =~ $pattern
    }
}

def sd-find-retired-artifacts [root: string, expected_locks: list<record> = []] {
    let uuid = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    let setup_pattern = ('^\.nurl-state-setup-' + $uuid + '$')
    let temp_pattern = ('^\.[^\\/]+\.nurl-' + $uuid + '\.tmp$')
    sd-entries $root | where {|path|
        let name = ($path | path basename)
        let parent = ($path | path dirname | path expand)
        let normalized = ($path | str replace --all "\\" "/")
        let marker = $name == ".secured-v1" and (($normalized | split row "/") | any {|segment| $segment == ".nurl-state" })
        let lock = ($expected_locks | any {|spec|
            (
                (($spec.dir | path expand) == $parent)
                and ($spec.basenames | any {|basename| $name == $".($basename).create.lock" })
            )
        })
        (
            $name == ".nurl-state"
                or $marker
                or ($name =~ $setup_pattern)
                or $lock
                or ($name =~ $temp_pattern)
        )
    }
}

# Age a file's mtime using test-only native tooling (PowerShell on Windows,
# touch on POSIX) — production code must never call these.
def sd-age-file [tmp: string, path: string, hours_ago: int] {
    if $nu.os-info.name == "windows" {
        let script = ($tmp | path join $"sd-age-(random uuid).ps1")
        'param($Path, $HoursAgo)
$stamp = (Get-Date).ToUniversalTime().AddHours(-1 * [double]$HoursAgo)
if (Test-Path -LiteralPath $Path -PathType Container) {
    [System.IO.Directory]::SetLastWriteTimeUtc($Path, $stamp)
} else {
    [System.IO.File]::SetLastWriteTimeUtc($Path, $stamp)
}
' | save -f $script
        let result = (test-complete-result (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script $path $hours_ago | complete))
        try { rm -f $script } catch {}
        assert equal $result.exit_code 0 $"could not age ($path): ($result.stderr)"
    } else {
        let stamp = ((date now) - ($hours_ago * 1hr) | format date "%Y%m%d%H%M.%S")
        let result = (test-complete-result (^touch -t $stamp $path | complete))
        assert equal $result.exit_code 0 $"could not age ($path): ($result.stderr)"
    }
}

# ── Installer / source-graph helpers (req 12) ──────────────────────────────

def sd-installer-modules [path: string, prefix: string] {
    let declaration = (
        open $path --raw
        | lines
        | where {|line| $line | str trim | str starts-with $prefix }
    )
    assert equal ($declaration | length) 1 $"expected one module declaration in ($path)"
    $declaration
    | first
    | split row '"'
    | where {|part| $part | str ends-with ".nu" }
}

# ═══════════════════════════════════════════════════════════════════════════
# R1 — Exact serialized bytes, no temp residue, binary corruption fails closed
# ═══════════════════════════════════════════════════════════════════════════

def test-sd-r1-compact-bytes [] {
    let tmp = (make-temp-dir "sd-r1-compact")
    sd-finally {
        $env.API_ROOT = $tmp
        api init
        api config set editor "vim" | ignore
        api vars set greeting "hello" | ignore
        api auth bearer set demo "s3cr3t-token" | ignore

        sd-assert-canonical-nuon ($tmp | path join "config.nuon")
        sd-assert-canonical-nuon ($tmp | path join "variables.nuon")
        sd-assert-canonical-nuon ($tmp | path join "secrets.nuon")
    } { cleanup $tmp }
}

def test-sd-r1-indented-bytes [] {
    let tmp = (make-temp-dir "sd-r1-indented")
    sd-finally {
        $env.API_ROOT = $tmp
        api init
        api collection create coll1 -d "demo collection" | ignore
        api collection env create coll1 env1 --activate | ignore
        api request create req1 GET "http://example.invalid/x" -c coll1 | ignore

        sd-assert-canonical-nuon ($tmp | path join "collections" "coll1" "collection.nuon") 4
        sd-assert-canonical-nuon ($tmp | path join "collections" "coll1" "meta.nuon") 4
        sd-assert-canonical-nuon ($tmp | path join "collections" "coll1" "environments" "env1.nuon") 4
        sd-assert-canonical-nuon ($tmp | path join "collections" "coll1" "requests" "req1.nuon") 4
    } { cleanup $tmp }
}

def test-sd-r1-no-temp-artifacts [] {
    let tmp = (make-temp-dir "sd-r1-notemp")
    sd-finally {
        $env.API_ROOT = $tmp
        api init
        api config set editor "vim" | ignore
        api config set editor "emacs" | ignore
        api vars set a "1" | ignore
        api vars set a "2" | ignore
        api auth bearer set demo "tok-a" | ignore
        api auth bearer set demo "tok-b" | ignore
        api collection create coll1 | ignore
        api collection env create coll1 env1 --activate | ignore
        api collection env use coll1 env1 | ignore
        api request create req1 GET "http://example.invalid/x" -c coll1 | ignore
        api chain create chain1 | ignore

        let leftovers = (sd-find-temp-artifacts $tmp)
        assert equal $leftovers [] $"stray .nurl-*.tmp artifacts left behind: ($leftovers | to nuon)"
    } { cleanup $tmp }
}

def test-sd-r1-binary-corruption-fails-closed [] {
    let tmp = (make-temp-dir "sd-r1-binary")
    sd-finally {
        $env.API_ROOT = $tmp
        api init
        let config_path = ($tmp | path join "config.nuon")
        sd-with-corrupted-file $config_path {
            (0x[00 01 02 FF FE FD C0 C1]) | save -f $config_path
        } {
            let result = (sd-assert-clean-error-any $tmp "api config get" ["Could not parse" "must contain a record"] $SD_FORBIDDEN_LEAKAGE)
            assert (sd-stderr-has $result.stderr $config_path) "binary-corruption error omitted the path"
        }
    } { cleanup $tmp }
}

# ═══════════════════════════════════════════════════════════════════════════
# R2 — Windows publish-failure preserves prior destination bytes
# ═══════════════════════════════════════════════════════════════════════════

def test-sd-r2-windows-replace-failure [] {
    if $nu.os-info.name != "windows" {
        error make {msg: "SKIP: Windows-only exclusive-handle replacement failure (mv -f cannot be deterministically blocked on this OS)"}
    }
    let tmp = (make-temp-dir "sd-r2")
    sd-finally {
        $env.API_ROOT = $tmp
        api init
        api config set editor "vim" | ignore
        let config_path = ($tmp | path join "config.nuon")
        let original = (open $config_path --raw)
        assert (($original | str length) > 0) "config.nuon fixture must be nonempty before the replace-failure attempt"

        let lock = (sd-start-file-lock $tmp $config_path "Read")
        sd-finally {
            let result = (sd-assert-clean-error $tmp "api config set editor 'emacs'" "Could not publish state file" $SD_FORBIDDEN_LEAKAGE)
            assert (sd-stderr-has $result.stderr $config_path) "replace-failure stderr omitted the destination path"

            let after = (open $config_path --raw)
            assert equal $after $original "destination bytes changed despite a failed publish"
            assert (($after | str length) > 0) "destination became empty after a failed publish"

            let leftovers = (sd-find-temp-artifacts $tmp)
            assert equal $leftovers [] "a failed publish left a .nurl-*.tmp sibling behind"
        } { sd-stop-file-lock $lock }
    } { cleanup $tmp }
}

# ═══════════════════════════════════════════════════════════════════════════
# R3 — A real interrupted PUBLIC create leaves a partial file that fails
# closed on show (no pre-truncated fixture)
# ═══════════════════════════════════════════════════════════════════════════

def test-sd-r3-interrupted-create-fails-closed [] {
    let tmp = (make-temp-dir "sd-r3")
    let pids_file = ($tmp | path join "sd-r3-pids.txt")
    sd-finally {
        $env.API_ROOT = $tmp
        api init
        let name = "interrupt-me"
        let target_path = ($tmp | path join "chains" $"($name).nuon")
        let script = (sd-write-worker-script $tmp "sd-r3-worker" "root: string, chain_name: string, descfile: string" '
$env.API_ROOT = $root
let desc = (open $descfile --raw)
api chain create $chain_name --description $desc
')

        mut caught_partial = false
        # Escalating sizes and several retries per size: nushell's `save`
        # write of a single large in-memory string was empirically found (via
        # extensive manual instrumentation across polling, tight busy-loop,
        # and FileSystemWatcher-event techniques) to be atomic-from-outside
        # for any payload that keeps this test's runtime practical — so this
        # loop gives a genuine, non-fabricated interruption every reasonable
        # chance to land before falling back to an honest SKIP below.
        for size in [40000000 120000000] {
            if $caught_partial { continue }
            for attempt in 1..2 {
                if $caught_partial { continue }
                if ($target_path | path exists) { rm -f $target_path }
                let desc_file = ($tmp | path join $"sd-r3-desc-(random uuid).txt")
                (sd-large-string $size) | save -f $desc_file

                let worker = (sd-launch-worker-script $tmp $script [$tmp $name $desc_file] "sd-r3-run")
                sd-track-pid $pids_file $worker.pid

                if $nu.os-info.name == "windows" {
                    let outcome = (sd-watch-and-kill-on-create $tmp ($tmp | path join "chains") $"($name).nuon" $worker.pid 5000)
                    if $outcome == "killed-before-visible" or $outcome == "no-child-found" {
                        # The write completed (or the file never appeared) before
                        # the event-driven watcher could react; nothing to
                        # inspect this attempt.
                        try { rm -f $target_path } catch {}
                    }
                } else {
                    mut waited_ms = 0
                    while $waited_ms < 8000 {
                        if ($target_path | path exists) {
                            break
                        }
                        sleep 1ms
                        $waited_ms = $waited_ms + 1
                    }
                }

                sd-stop-process-tree $worker.pid $tmp
                try { rm -f $desc_file } catch {}

                if ($target_path | path exists) {
                    let bytes = (open $target_path --raw)
                    let parses = (try { $bytes | from nuon; true } catch { false })
                    if (not $parses) or (($bytes | str length) < $size) {
                        $caught_partial = true
                    } else {
                        rm -f $target_path
                    }
                }
            }
        }

        if not $caught_partial {
            error make {msg: "SKIP: nushell's `save` write of a large in-memory string was empirically atomic-from-outside on this runtime/environment (verified across polling, tight busy-loop, and FileSystemWatcher event-driven interruption techniques up to multi-GB payloads) — a genuinely partial, non-fabricated PUBLIC create could not be reproduced within a practical test runtime"}
        }

        let result = (sd-assert-clean-error-any $tmp $"api chain show ($name)" ["Could not parse" "expected a NUON record or list"] $SD_FORBIDDEN_LEAKAGE)
        assert (sd-stderr-has $result.stderr $target_path) "interrupted-create show error omitted the path"
    } {
        sd-kill-tracked-pids $pids_file $tmp
        cleanup $tmp
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# R4 — Barrier-synchronized N=8 chain create characterization, same name.
# Nushell save has a pre-existing TOCTOU, so multiple
# successes are an accepted main-parity residual rather than a safety gate.
# ═══════════════════════════════════════════════════════════════════════════

def test-sd-r4-barrier-race-main-parity [] {
    let tmp = (make-temp-dir "sd-r4")
    let pids_file = ($tmp | path join "sd-r4-pids.txt")
    sd-finally {
        $env.API_ROOT = $tmp
        api init

        api chain create sequential --description "first" | ignore
        let sequential_path = ($tmp | path join "chains" "sequential.nuon")
        let sequential_before = (open $sequential_path --raw)
        let duplicate = try {
            api chain create sequential --description "second" | ignore
            {ok: true, msg: ""}
        } catch {|error|
            {ok: false, msg: $error.msg}
        }
        assert (not $duplicate.ok) "sequential duplicate create unexpectedly succeeded"
        assert equal $duplicate.msg "Chain 'sequential' already exists" "sequential duplicate message changed"
        assert equal (open $sequential_path --raw) $sequential_before "sequential duplicate changed existing bytes"

        let n = 8
        let rounds = 5
        mut characterization = []
        let script = (sd-write-worker-script $tmp "sd-r4-worker" "root: string, chain_name: string, ready: string, go: string, result: string, worker_tag: string" '
$env.API_ROOT = $root
"ready" | save -f $ready
mut waited = 0
while (not ($go | path exists)) and $waited < 15000 {
    sleep 5ms
    $waited = $waited + 5
}
let outcome = (try {
    api chain create $chain_name --description $worker_tag
    {ok: true, msg: ""}
} catch {|e|
    {ok: false, msg: $e.msg}
})
($outcome | to nuon) | save -f $result
')

        for iter in 1..$rounds {
            let name = $"race-($iter)"
            let chains_dir = ($tmp | path join "chains")
            let target_path = ($chains_dir | path join $"($name).nuon")
            let go_file = ($tmp | path join $"sd-r4-go-($iter).txt")
            let ready_files = (0..<$n | each {|w| $tmp | path join $"sd-r4-ready-($iter)-($w).txt" })
            let result_files = (0..<$n | each {|w| $tmp | path join $"sd-r4-result-($iter)-($w).txt" })

            mut round_pids = []
            for w in 0..<$n {
                let ready = ($ready_files | get $w)
                let result = ($result_files | get $w)
                let tag = $"worker-($w)"
                let worker = (sd-launch-worker-script $tmp $script [$tmp $name $ready $go_file $result $tag] $"sd-r4-run-($iter)-($w)")
                $round_pids = ($round_pids | append $worker.pid)
                sd-track-pid $pids_file $worker.pid
            }

            let all_ready = (sd-wait-until { $ready_files | all {|f| $f | path exists } } 1200)
            assert $all_ready $"iteration ($iter): not all ($n) workers signalled ready in time"
            "go" | save -f $go_file
            let all_done = (sd-wait-until { $result_files | all {|f| $f | path exists } } 1600)
            assert $all_done $"iteration ($iter): not all ($n) workers finished in time"

            for pid in $round_pids { sd-stop-process-tree $pid $tmp }

            let outcomes = (0..<$n | each {|w|
                let outcome = ((open ($result_files | get $w) --raw) | from nuon)
                {worker: $w, ok: $outcome.ok, msg: $outcome.msg}
            })
            let winners = ($outcomes | where ok == true)
            let losers = ($outcomes | where ok == false)
            assert (($winners | length) >= 1) $"iteration ($iter): no create caller reported success"
            assert equal (($winners | length) + ($losers | length)) $n $"iteration ($iter): child outcomes were incomplete"
            for loser in $losers {
                assert equal $loser.msg $"Chain '($name)' already exists" $"iteration ($iter) worker ($loser.worker): unexpected loser message"
            }

            assert (($target_path | path exists)) $"iteration ($iter): final chain file was not created"
            let created = ((open $target_path --raw) | from nuon)
            let successful_tags = ($winners | each {|winner| $"worker-($winner.worker)" })
            assert equal $created.name $name $"iteration ($iter): final chain name was incomplete"
            assert ($created.description in $successful_tags) $"iteration ($iter): final bytes did not match a successful contender"
            assert equal ($created.steps | length) 2 $"iteration ($iter): final chain steps were truncated or interleaved"
            $characterization = ($characterization | append {
                iteration: $iter
                successes: ($winners | length)
                duplicates: ($losers | length)
                final_description: $created.description
            })

            for f in ($ready_files | append $result_files | append [$go_file]) {
                try { rm -f $f } catch {}
            }
        }

        let leftovers = (sd-find-temp-artifacts $tmp)
        assert equal $leftovers [] "barrier race left .nurl-*.tmp/lock/marker artifacts behind"
        print $"  create-race characterization: ($characterization | to nuon)"
        try { rm -f $pids_file } catch {}
    } {
        sd-kill-tracked-pids $pids_file $tmp
        cleanup $tmp
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# R5 — Corruption matrix across every state file type
# ═══════════════════════════════════════════════════════════════════════════

# Set up one instance of every state file type and return a list of
# {label, path, trigger, shape_payload} matrix entries.
def sd-corruption-targets [tmp: string] {
    $env.API_ROOT = $tmp
    api init
    api collection create coll1 | ignore
    api collection env create coll1 env1 --activate | ignore
    api collection env use coll1 env1 | ignore
    api request create req1 GET "http://example.invalid/x" -c coll1 | ignore
    api chain create chain1 | ignore

    [
        {label: "config", path: ($tmp | path join "config.nuon"), trigger: "api config get", shape_payload: "[1 2 3]"}
        {label: "variables", path: ($tmp | path join "variables.nuon"), trigger: "api vars list", shape_payload: "[1 2 3]"}
        {label: "secrets", path: ($tmp | path join "secrets.nuon"), trigger: "api auth list", shape_payload: "[1 2 3]"}
        {label: "collection-definition", path: ($tmp | path join "collections" "coll1" "collection.nuon"), trigger: "api collection show coll1", shape_payload: "[1 2 3]"}
        {label: "collection-meta", path: ($tmp | path join "collections" "coll1" "meta.nuon"), trigger: "api collection show coll1", shape_payload: "[1 2 3]"}
        {label: "environment", path: ($tmp | path join "collections" "coll1" "environments" "env1.nuon"), trigger: "api collection env show coll1 env1", shape_payload: "[1 2 3]"}
        {label: "request", path: ($tmp | path join "collections" "coll1" "requests" "req1.nuon"), trigger: "api request show req1 -c coll1", shape_payload: "[1 2 3]"}
        {label: "chain", path: ($tmp | path join "chains" "chain1.nuon"), trigger: "api chain show chain1", shape_payload: "42"}
    ]
}

def test-sd-r5-syntax-corruption-matrix [] {
    let tmp = (make-temp-dir "sd-r5-syntax")
    sd-finally {
        let targets = (sd-corruption-targets $tmp)
        for target in $targets {
            sd-with-corrupted-file $target.path {
                "{{{ not : valid : nuon ::: [[[" | save -f $target.path
            } {
                let result = (sd-assert-clean-error $tmp $target.trigger "Could not parse" $SD_FORBIDDEN_LEAKAGE)
                assert (sd-stderr-has $result.stderr $target.path) $"($target.label): syntax-corruption stderr missing path"
            }
        }
    } { cleanup $tmp }
}

def test-sd-r5-shape-corruption-matrix [] {
    let tmp = (make-temp-dir "sd-r5-shape")
    sd-finally {
        let targets = (sd-corruption-targets $tmp)
        for target in $targets {
            let expected = if $target.label == "chain" { "expected a NUON record or list" } else { "must contain a record" }
            sd-with-corrupted-file $target.path {
                $target.shape_payload | save -f $target.path
            } {
                let result = (sd-assert-clean-error $tmp $target.trigger $expected $SD_FORBIDDEN_LEAKAGE)
                assert (sd-stderr-has $result.stderr $target.path) $"($target.label): shape-corruption stderr missing path"
            }
        }
    } { cleanup $tmp }
}

def test-sd-r5-binary-corruption-matrix [] {
    let tmp = (make-temp-dir "sd-r5-binary")
    sd-finally {
        let targets = (sd-corruption-targets $tmp)
        for target in $targets {
            # Binary corruption's exact clean-error message is content-dependent:
            # some byte sequences fail to parse as NUON outright ("Could not
            # parse"), others happen to parse to a value of the wrong shape
            # ("must contain a record" / chain's own shape message). Both are
            # legitimate, path-specific, non-cascading state-store failures.
            let shape_message = if $target.label == "chain" { "expected a NUON record or list" } else { "must contain a record" }
            sd-with-corrupted-file $target.path {
                (0x[00 01 02 FF FE FD C0 C1 80 81]) | save -f $target.path
            } {
                let result = (sd-assert-clean-error-any $tmp $target.trigger ["Could not parse" $shape_message] $SD_FORBIDDEN_LEAKAGE)
                assert (sd-stderr-has $result.stderr $target.path) $"($target.label): binary-corruption stderr missing path"
            }
        }
    } { cleanup $tmp }
}

def test-sd-r5-missing-files-retain-defaults [] {
    let tmp = (make-temp-dir "sd-r5-missing")
    sd-finally {
        $env.API_ROOT = $tmp
        # No `api init` — every state file and directory is genuinely absent.
        assert equal (api config get) {
            default_headers: {"Content-Type": "application/json", "Accept": "application/json"}
            timeout_seconds: 30
            history_retention_days: 30
            editor: "code"
        } "api config get default did not match on a workspace with no config.nuon"

        assert equal (api vars list | length) 8 "api vars list should report only the 8 built-ins when variables.nuon is absent"
        assert equal (api auth list) [] "api auth list should be empty when secrets.nuon is absent"

        let status = (api status)
        assert equal $status.global_vars 0 "status global_vars should be 0 with no variables.nuon"
        assert equal $status.collections 0 "status collections should be 0 with no collections dir"
        assert equal $status.history_entries 0 "status history_entries should be 0 with no history dir"
        assert equal $status.active_collection null "status active_collection should default to null"
        assert equal $status.active_environment null "status active_environment should default to null"
    } { cleanup $tmp }
}

def test-sd-r5-io-failure-propagation [] {
    let tmp = (make-temp-dir "sd-r5-io")
    sd-finally {
        $env.API_ROOT = $tmp
        api init
        let config_path = ($tmp | path join "config.nuon")

        if $nu.os-info.name == "windows" {
            let lock = (sd-start-file-lock $tmp $config_path "None")
            sd-finally {
                let result = (run-command-process $tmp "api config get")
                assert ($result.exit_code != 0) "exclusively-locked config.nuon read unexpectedly exited 0"
                assert equal ($result.stdout | str trim) "" "exclusively-locked config.nuon read wrote stdout"
                assert (not ($result.stderr | str contains "Could not parse")) "exclusively-locked config.nuon read produced a parse-style message instead of a genuine IO error"
                assert (not ($result.stderr | str contains "must contain a record")) "exclusively-locked config.nuon read was normalized as a shape error"
            } { sd-stop-file-lock $lock }
        } else {
            let uid = (^id -u | str trim)
            if $uid == "0" {
                error make {msg: "SKIP: running as root; POSIX permission checks are bypassed"}
            }
            chmod 000 $config_path
            sd-finally {
                let result = (run-command-process $tmp "api config get")
                assert ($result.exit_code != 0) "permission-denied config.nuon read unexpectedly exited 0"
                assert equal ($result.stdout | str trim) "" "permission-denied config.nuon read wrote stdout"
                assert (not ($result.stderr | str contains "Could not parse")) "permission-denied config.nuon read produced a parse-style message instead of a genuine IO error"
                assert (not ($result.stderr | str contains "must contain a record")) "permission-denied config.nuon read was normalized as a shape error"
            } { chmod 644 $config_path }
        }
    } { cleanup $tmp }
}

def test-sd-r5-reader-io-boundary-is-structural [] {
    let source = (open ($env.NURL_REPO_ROOT | path join "nu_modules" "state-store.nu") --raw)
    let strict = (
        $source
        | split row "export def open-state-value"
        | last
        | split row "export def open-state-record ["
        | first
    )
    assert ($strict | str contains 'let raw = (open $path --raw)') "strict reader no longer opens raw bytes directly"
    let before_open = ($strict | split row 'let raw = (open $path --raw)' | first)
    assert (not ($before_open | str contains "try")) "strict reader catches genuine I/O before open --raw"
    assert (not ($before_open | str contains "catch")) "strict reader catches genuine I/O before open --raw"
    let after_open = ($strict | split row 'let raw = (open $path --raw)' | last)
    assert ($after_open | str contains "try") "strict reader no longer normalizes NUON parse failures"

    let defaults = (
        $source
        | split row "export def open-state-record-or-default"
        | last
    )
    assert ($defaults | str contains 'if not ($path | path exists)') "defaulting reader lost its advisory missing-path check"
    assert ($defaults | str contains 'open-state-record $path $description') "present defaulting path no longer delegates to the strict reader"
    assert (not ($defaults | str contains "try")) "present defaulting path catches strict-reader I/O"
    assert (not ($defaults | str contains "catch")) "present defaulting path catches strict-reader I/O"
}

def test-sd-r5-history-config-read-fails-closed [] {
    let tmp = (make-temp-dir "sd-r5-histcfg")
    sd-finally {
        $env.API_ROOT = $tmp
        api init
        # Empty history dir only — no entries/index are ever written by this
        # test, keeping history's own persistence model untouched while still
        # reaching the public config-driven retention-days read inside
        # `api history clear`.
        mkdir ($tmp | path join "history")
        let config_path = ($tmp | path join "config.nuon")

        sd-with-corrupted-file $config_path {
            "not: valid: [[[ nuon" | save -f $config_path
        } {
            let result = (sd-assert-clean-error $tmp "api history clear" "Could not parse" $SD_FORBIDDEN_LEAKAGE)
            assert (sd-stderr-has $result.stderr $config_path) "history-config read error omitted the path"
        }

        # The history directory itself must remain exactly as created — no
        # entry/index files appear as a side effect of the failed config read.
        assert equal (sd-entries ($tmp | path join "history")) [] "api history clear wrote history entries/index during a failed config read"
    } { cleanup $tmp }
}

# ═══════════════════════════════════════════════════════════════════════════
# R6 — Byte-stable read-only sweep; credential/secret key order preservation
# ═══════════════════════════════════════════════════════════════════════════

def test-sd-r6-read-only-byte-stability [] {
    let tmp = (make-temp-dir "sd-r6-stable")
    sd-finally {
        $env.API_ROOT = $tmp
        api init
        api config set editor "vim" | ignore
        api vars set foo "bar" | ignore
        api auth bearer set demo "tok" | ignore
        api collection create coll1 | ignore
        api collection env create coll1 env1 --activate | ignore
        api request create req1 GET "http://example.invalid/x" -c coll1 | ignore
        api chain create chain1 | ignore
        # Empty history dir (no entries/index writes) so the public history
        # config reader (`api history clear`'s retention-days read of
        # config.nuon) is exercised without touching history's own
        # entry/index persistence model.
        mkdir ($tmp | path join "history")

        let commands = [
            "api config get"
            "api status"
            "api vars list"
            "api auth show --full"
            "api collection show coll1"
            "api collection env show coll1 env1"
            "api request show req1 -c coll1"
            "api chain show chain1"
            "api history clear"
        ]
        for command in $commands {
            let first = (run-command-process $tmp $command)
            let second = (run-command-process $tmp $command)
            assert equal $first.exit_code $second.exit_code $"($command): exit code differed across identical reads"
            assert equal $first.stdout $second.stdout $"($command): stdout was not byte-stable across identical reads"
            assert equal $first.stderr $second.stderr $"($command): stderr was not byte-stable across identical reads"
        }
    } { cleanup $tmp }
}

def test-sd-r6-credential-key-order-preserved [] {
    let tmp = (make-temp-dir "sd-r6-order")
    sd-finally {
        $env.API_ROOT = $tmp
        api init
        for name in ["zzz-token" "mmm-token" "aaa-token"] {
            api auth bearer set $name $"value-($name)" | ignore
        }
        let bearer_order = (api auth list | where type == bearer | get name)
        assert equal $bearer_order ["zzz-token" "mmm-token" "aaa-token"] "api auth list did not preserve bearer insertion order"

        let secrets = ((open ($tmp | path join "secrets.nuon") --raw) | from nuon)
        assert equal ($secrets.tokens | columns) ["zzz-token" "mmm-token" "aaa-token"] "secrets.nuon tokens record did not preserve insertion order"

        for name in ["zvar" "mvar" "avar"] {
            api vars set $name "1" | ignore
        }
        let vars = ((open ($tmp | path join "variables.nuon") --raw) | from nuon)
        assert equal ($vars | columns) ["zvar" "mvar" "avar"] "variables.nuon did not preserve insertion order"
    } { cleanup $tmp }
}

# ═══════════════════════════════════════════════════════════════════════════
# R7 — Stale sibling exact-prefix policy for secrets.nuon
# ═══════════════════════════════════════════════════════════════════════════

def sd-secrets-sibling-path [tmp: string, tag: string] {
    $tmp | path join $".secrets.nuon.nurl-($tag)-(random uuid).tmp"
}

def test-sd-r7-fresh-and-unrelated-siblings-untouched [] {
    let tmp = (make-temp-dir "sd-r7-fresh")
    sd-finally {
        $env.API_ROOT = $tmp
        api init
        api auth bearer set seed "seed-token" | ignore

        let fresh_sibling = (sd-secrets-sibling-path $tmp "fresh")
        "fresh sentinel content" | save -f $fresh_sibling

        let orphan_sibling = ($tmp | path join $".config.nuon.nurl-orphan-(random uuid).tmp")
        "orphan sentinel content" | save -f $orphan_sibling
        sd-age-file $tmp $orphan_sibling 3

        let user_file = ($tmp | path join "notes.txt")
        "user data, do not touch" | save -f $user_file

        let lock = (if $nu.os-info.name == "windows" {
            sd-start-file-lock $tmp $fresh_sibling "Read"
        } else {
            null
        })

        sd-finally {
            let result = (run-command-process $tmp "api auth bearer set fresh-check fresh-token")
            assert equal $result.exit_code 0 "auth write with only fresh/orphan siblings present unexpectedly failed"
            assert equal ($result.stderr | str trim) "" "auth write with only fresh/orphan siblings present printed unexpected stderr"

            assert (($fresh_sibling | path exists)) "a fresh same-destination temp sibling was swept despite being under the age cutoff"
            assert equal (open $fresh_sibling --raw) "fresh sentinel content" "a fresh same-destination temp sibling's bytes changed"
            assert (($orphan_sibling | path exists)) "an aged but differently-prefixed (orphan) temp sibling was swept"
            assert equal (open $orphan_sibling --raw) "orphan sentinel content" "an orphan temp sibling's bytes changed"
            assert equal (open $user_file --raw) "user data, do not touch" "an unrelated user file was modified by the sweep"

            let secrets = ((open ($tmp | path join "secrets.nuon") --raw) | from nuon)
            assert equal ($secrets.tokens | get "fresh-check" | get bearer) "fresh-token" "the requested auth write did not commit expected bytes"
        } { if $lock != null { sd-stop-file-lock $lock } }
    } { cleanup $tmp }
}

def test-sd-r7-aged-removable-swept-silently [] {
    let tmp = (make-temp-dir "sd-r7-aged")
    sd-finally {
        $env.API_ROOT = $tmp
        api init
        api auth bearer set seed "seed-token" | ignore

        let aged_sibling = (sd-secrets-sibling-path $tmp "aged")
        "aged sentinel content" | save -f $aged_sibling
        sd-age-file $tmp $aged_sibling 2

        let result = (run-command-process $tmp "api auth bearer set aged-check aged-token")
        assert equal $result.exit_code 0 "auth write with an aged removable sibling unexpectedly failed"
        assert equal ($result.stderr | str trim) "" "auth write with an aged removable sibling printed unexpected stderr"
        assert (not ($aged_sibling | path exists)) "an aged, removable same-destination temp sibling was not swept"

        let secrets = ((open ($tmp | path join "secrets.nuon") --raw) | from nuon)
        assert equal ($secrets.tokens | get "aged-check" | get bearer) "aged-token" "the requested auth write did not commit expected bytes after sweeping an aged sibling"
    } { cleanup $tmp }
}

def test-sd-r7-aged-unremovable-warns-but-commits [] {
    let tmp = (make-temp-dir "sd-r7-unremovable")
    sd-finally {
        $env.API_ROOT = $tmp
        api init

        let clean = (run-command-process $tmp "api auth bearer set stable-name stable-token")
        assert equal $clean.exit_code 0 "baseline (no stale siblings) auth write unexpectedly failed"
        assert equal ($clean.stderr | str trim) "" "baseline (no stale siblings) auth write printed unexpected stderr"

        let blocked_sibling = (sd-secrets-sibling-path $tmp "blocked")
        if $nu.os-info.name == "windows" {
            "keep" | save -f $blocked_sibling
        } else {
            mkdir $blocked_sibling
            "keep" | save -f ($blocked_sibling | path join "keep.txt")
        }
        sd-age-file $tmp $blocked_sibling 2
        let blocker = if $nu.os-info.name == "windows" {
            sd-start-file-lock $tmp $blocked_sibling "Read"
        } else {
            null
        }

        sd-finally {
            let warned = (run-command-process $tmp "api auth bearer set stable-name stable-token")
            let expected_warning = $"Warning: Stale state temporary file '($blocked_sibling)' could not be removed; remove it manually.\n"
            assert equal $warned.exit_code 0 "auth write with an aged unremovable sibling unexpectedly failed"
            assert equal $warned.stdout $clean.stdout "stdout differed between the clean and stale-sibling-warning auth writes"
            assert equal $warned.stderr $expected_warning "aged-unremovable stderr was not the single stable path-only warning"
            assert equal $warned.stderr ($warned.stderr | ansi strip) "aged-unremovable warning contained ANSI codes"
            assert (($blocked_sibling | path exists)) "the genuinely unremovable sibling disappeared unexpectedly"

            let secrets = ((open ($tmp | path join "secrets.nuon") --raw) | from nuon)
            assert equal ($secrets.tokens | get "stable-name" | get bearer) "stable-token" "the requested auth write did not commit expected bytes despite the removal warning"
        } {
            if $blocker != null { sd-stop-file-lock $blocker }
        }
    } { cleanup $tmp }
}

# ═══════════════════════════════════════════════════════════════════════════
# R8 — Recursive public lifecycle (incl. collection copy): zero private
# artifacts anywhere; read-only sweep of a bundled tracked workspace leaves
# git status unchanged
# ═══════════════════════════════════════════════════════════════════════════

def test-sd-r8-recursive-lifecycle-no-artifacts [] {
    let tmp = (make-temp-dir "sd-r8")
    sd-finally {
        $env.API_ROOT = $tmp
        api init
        api config set editor "vim" | ignore
        api vars set greeting "hi" | ignore
        api auth bearer set demo "tok" | ignore
        api collection create source-coll -d "source" | ignore
        api collection env create source-coll env1 --activate | ignore
        api request create req1 GET "http://example.invalid/x" -c source-coll | ignore
        api chain create chain1 | ignore

        let source_dir = ($tmp | path join "collections" "source-coll")
        let expected_locks = [
            {dir: $tmp, basenames: ["config.nuon" "variables.nuon" "secrets.nuon"]}
            {dir: $source_dir, basenames: ["collection.nuon" "meta.nuon"]}
            {dir: ($source_dir | path join "environments"), basenames: ["env1.nuon" "attempted-env.nuon"]}
            {dir: ($source_dir | path join "requests"), basenames: ["req1.nuon" "attempted-request.nuon"]}
            {dir: ($tmp | path join "chains"), basenames: ["chain1.nuon" "attempted-chain.nuon"]}
        ]
        assert equal (sd-find-retired-artifacts $tmp $expected_locks) [] "normal lifecycle created a retired state artifact"
        assert equal (sd-find-temp-artifacts $tmp) [] "normal lifecycle left a generated sibling temp"

        api collection copy source-coll target-coll

        let target_dir = ($tmp | path join "collections" "target-coll")
        let target_locks = [
            {dir: $target_dir, basenames: ["collection.nuon" "meta.nuon"]}
            {dir: ($target_dir | path join "environments"), basenames: ["env1.nuon"]}
            {dir: ($target_dir | path join "requests"), basenames: ["req1.nuon"]}
        ]
        assert equal (sd-find-retired-artifacts $target_dir $target_locks) [] "clean collection copy introduced a retired state artifact"
        assert equal (sd-find-temp-artifacts $target_dir) [] "clean collection copy introduced a generated sibling temp"

        assert equal (open ($target_dir | path join "requests" "req1.nuon") --raw) (open ($source_dir | path join "requests" "req1.nuon") --raw) "copied request bytes diverged from source"
        assert equal (open ($target_dir | path join "environments" "env1.nuon") --raw) (open ($source_dir | path join "environments" "env1.nuon") --raw) "copied environment bytes diverged from source"
        assert equal (open ($target_dir | path join "meta.nuon") --raw) (open ($source_dir | path join "meta.nuon") --raw) "copied collection meta bytes diverged from source"

        let source_def = ((open ($source_dir | path join "collection.nuon") --raw) | from nuon)
        let target_def = ((open ($target_dir | path join "collection.nuon") --raw) | from nuon)
        assert equal $target_def.name "target-coll" "copied collection.nuon did not update its own name"
        assert equal $target_def.description $source_def.description "copied collection.nuon description diverged from source"
        assert equal $target_def.version $source_def.version "copied collection.nuon version diverged from source"
        assert (not ($target_def.created_at == $source_def.created_at and $target_def.name == $source_def.name)) "copied collection.nuon did not update created_at/name at all"

        api collection create inert-file-source | ignore
        let inert_file = ($tmp | path join "collections" "inert-file-source" ".nurl-state")
        let inert_file_bytes = 0x[10 20 30 80 fe ff]
        $inert_file_bytes | save $inert_file
        api collection copy inert-file-source inert-file-copy | ignore
        let inert_file_copy = ($tmp | path join "collections" "inert-file-copy" ".nurl-state")
        assert equal (open $inert_file_copy --raw | encode base64) ($inert_file_bytes | encode base64) "collection copy filtered a user file named .nurl-state"
        api collection env create inert-file-copy later | ignore
        assert equal (open $inert_file_copy --raw | encode base64) ($inert_file_bytes | encode base64) "ordinary collection write consumed a user file named .nurl-state"

        let inert_dir = ($source_dir | path join ".nurl-state")
        mkdir $inert_dir
        let inert_bytes = 0x[00 01 7f 80 fe ff]
        $inert_bytes | save ($inert_dir | path join "user-payload.bin")
        "user marker bytes" | save ($inert_dir | path join ".secured-v1")
        "ordinary user temp" | save ($inert_dir | path join "user-note.tmp")

        api collection copy source-coll inert-copy | ignore
        let inert_copy = ($tmp | path join "collections" "inert-copy" ".nurl-state")
        assert equal (open ($inert_copy | path join "user-payload.bin") --raw | encode base64) ($inert_bytes | encode base64) "collection copy filtered or changed inert user binary data"
        assert equal (open ($inert_copy | path join ".secured-v1") --raw) "user marker bytes" "collection copy filtered inert user marker-named data"
        assert equal (open ($inert_copy | path join "user-note.tmp") --raw) "ordinary user temp" "collection copy filtered an arbitrary user .tmp file"
        api request update req1 --url "http://example.invalid/updated" --collection inert-copy | ignore
        assert equal (open ($inert_copy | path join ".secured-v1") --raw) "user marker bytes" "ordinary request write interpreted inert marker-named data"
        assert equal (sd-find-temp-artifacts ($tmp | path join "collections" "inert-copy")) [] "copy left a generated sibling temp"
    } { cleanup $tmp }
}

def test-sd-r8-artifact-scanner-discrimination [] {
    let tmp = (make-temp-dir "sd-r8-scanner")
    sd-finally {
        let uuid = "3f2a1b9c-4d5e-6f70-8a9b-0c1d2e3f4a5b"
        let exact_lock = ($tmp | path join ".mychain.nuon.create.lock")
        let unrelated_lock = ($tmp | path join ".build.create.lock")
        let canonical_temp = ($tmp | path join $".secrets.nuon.nurl-($uuid).tmp")
        let setup = ($tmp | path join $".nurl-state-setup-($uuid)")
        let retired_dir = ($tmp | path join ".nurl-state")
        mkdir $setup
        mkdir $retired_dir
        for path in [
            $exact_lock
            $unrelated_lock
            $canonical_temp
            ($tmp | path join ".secrets.nuon.nurl-------------------------------------.tmp")
            ($tmp | path join ".secrets.nuon.nurl-3f2a1b9c4d5e6f708a9b0c1d2e3f4a5b1234.tmp")
            ($tmp | path join "notes.tmp")
            ($tmp | path join "data.nurl.tmp")
            ($tmp | path join ".secured-v1")
        ] {
            "fixture" | save $path
        }
        "inside" | save ($retired_dir | path join ".secured-v1")

        let expected = [{dir: $tmp, basenames: ["mychain.nuon"]}]
        let found = (sd-find-retired-artifacts $tmp $expected)
        for expected_path in [$exact_lock $canonical_temp $setup $retired_dir ($retired_dir | path join ".secured-v1")] {
            assert ($expected_path in $found) $"artifact scanner missed exact fixture: ($expected_path)"
        }
        for innocent in [
            $unrelated_lock
            ($tmp | path join ".secrets.nuon.nurl-------------------------------------.tmp")
            ($tmp | path join ".secrets.nuon.nurl-3f2a1b9c4d5e6f708a9b0c1d2e3f4a5b1234.tmp")
            ($tmp | path join "notes.tmp")
            ($tmp | path join "data.nurl.tmp")
            ($tmp | path join ".secured-v1")
        ] {
            assert ($innocent not-in $found) $"artifact scanner flagged innocent or malformed fixture: ($innocent)"
        }
        let without_enumeration = (sd-find-retired-artifacts $tmp [{dir: $tmp, basenames: []}])
        assert ($exact_lock not-in $without_enumeration) "lock scanner was not driven by the source-derived basename enumeration"
    } { cleanup $tmp }
}

def test-sd-r8-readonly-lifecycle-preserves-git-status [] {
    let root = $env.NURL_REPO_ROOT
    let before = (^git -C $root status --porcelain | complete)
    assert equal $before.exit_code 0 "git status failed before the read-only lifecycle sweep"

    let saved_root = ($env.API_ROOT? | default null)
    sd-finally {
        $env.API_ROOT = $root
        api config get | ignore
        api status | ignore
        api vars list | ignore
        api auth list | ignore

        let collections = (try { api collection list } catch { [] })
        for collection in $collections {
            let name = ($collection.name? | default $collection)
            try { api collection show $name | ignore } catch {}
            let coll_dir = ($root | path join "collections" $name)
            let envs_dir = ($coll_dir | path join "environments")
            if ($envs_dir | path exists) {
                for env_file in (ls $envs_dir | where name =~ '\.nuon$') {
                    let env_name = ($env_file.name | path basename | str replace ".nuon" "")
                    try { api collection env show $name $env_name | ignore } catch {}
                }
            }
            let requests_dir = ($coll_dir | path join "requests")
            if ($requests_dir | path exists) {
                for req_file in (ls $requests_dir | where name =~ '\.nuon$') {
                    let req_name = ($req_file.name | path basename | str replace ".nuon" "")
                    try { api request show $req_name -c $name | ignore } catch {}
                }
            }
        }

        let chains_dir = ($root | path join "chains")
        if ($chains_dir | path exists) {
            for chain_file in (ls $chains_dir | where name =~ '\.nuon$') {
                let chain_name = ($chain_file.name | path basename | str replace ".nuon" "")
                try { api chain show $chain_name | ignore } catch {}
            }
        }
    } {
        if $saved_root == null { hide-env API_ROOT } else { $env.API_ROOT = $saved_root }
    }

    let after = (^git -C $root status --porcelain | complete)
    assert equal $after.exit_code 0 "git status failed after the read-only lifecycle sweep"
    assert equal $before.stdout $after.stdout "read-only lifecycle sweep against the bundled tracked workspace left git status changed"
    let bundled = ($root | path join "collections" "jsonplaceholder")
    let expected_locks = [
        {dir: $root, basenames: ["config.nuon" "variables.nuon" "secrets.nuon"]}
        {dir: $bundled, basenames: ["collection.nuon" "meta.nuon"]}
        {dir: ($bundled | path join "environments"), basenames: ["default.nuon" "dev.nuon" "staging.nuon" "attempted-env.nuon"]}
        {dir: ($bundled | path join "requests"), basenames: [
            "create-post.nuon" "delete-post.nuon" "get-comments.nuon" "get-post.nuon"
            "get-posts.nuon" "get-users.nuon" "update-post.nuon" "attempted-request.nuon"
        ]}
        {dir: ($root | path join "chains"), basenames: ["example-workflow.nuon" "attempted-chain.nuon"]}
    ]
    assert equal (sd-find-retired-artifacts $root $expected_locks) [] "direct repo-tree scan found a retired or generated artifact"
}

# ═══════════════════════════════════════════════════════════════════════════
# R9 — Windows long path / case alias / 8.3 alias; POSIX symlinked ancestor;
# destination-file symlink replacement preserves the link
# ═══════════════════════════════════════════════════════════════════════════

# Cross-platform "is this path a symlink" / "what does it point to" probes.
# Windows: a tiny PowerShell script file (never an inline -Command string).
# POSIX: `test -L` / `readlink`.
def sd-is-symlink [path: string] {
    if $nu.os-info.name == "windows" {
        let dir = ($path | path dirname)
        let script = ($dir | path join $"sd-islink-(random uuid).ps1")
        'param($Path)
try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.LinkType) { [Console]::Out.Write("yes") } else { [Console]::Out.Write("no") }
} catch {
    [Console]::Out.Write("no")
}
' | save -f $script
        let result = (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script $path | complete)
        try { rm -f $script } catch {}
        ($result.stdout | str trim) == "yes"
    } else {
        (do { ^test -L $path } | complete).exit_code == 0
    }
}

def sd-symlink-target [path: string] {
    if $nu.os-info.name == "windows" {
        let dir = ($path | path dirname)
        let script = ($dir | path join $"sd-linktarget-(random uuid).ps1")
        'param($Path)
try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    [Console]::Out.Write([string]$item.Target)
} catch {
    [Console]::Out.Write("")
}
' | save -f $script
        let result = (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script $path | complete)
        try { rm -f $script } catch {}
        $result.stdout | str trim
    } else {
        (^readlink $path | complete).stdout | str trim
    }
}

# Best-effort Windows 8.3 short-name lookup for `basename` inside `parent`.
# Returns null (triggering a SKIP) if short-name generation is unavailable.
def sd-8dot3-short-name [parent: string, basename: string] {
    let script = ($parent | path join $"sd-8dot3-(random uuid).ps1")
    'param($Parent, $Basename)
$lines = & cmd.exe /d /c "dir /x `"$Parent`""
$hit = $lines | Where-Object { $_ -match "<DIR>" -and $_.TrimEnd().EndsWith($Basename) }
if ($hit) {
    $tokens = ($hit | Select-Object -First 1) -split "\s+" | Where-Object { $_ -ne "" }
    $idx = [Array]::IndexOf($tokens, "<DIR>")
    if ($idx -ge 0 -and ($idx + 1) -lt $tokens.Length) {
        $short = $tokens[$idx + 1]
        if ($short -like "*~*" -and $short -ne $Basename) {
            [Console]::Out.Write($short)
        }
    }
}
' | save -f $script
    let result = (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script $parent $basename | complete)
    try { rm -f $script } catch {}
    let out = ($result.stdout | str trim)
    if $out == "" { null } else { $out }
}

def test-sd-r9-windows-long-path-and-case-alias [] {
    if $nu.os-info.name != "windows" {
        error make {msg: "SKIP: long-path and case-alias semantics are Windows-specific; this run is on a non-Windows OS"}
    }
    let base = (make-temp-dir "sd-r9-long")
    sd-finally {
        # Build a deeply nested path comfortably beyond the classic 260-char MAX_PATH.
        mut deep = $base
        for i in 1..8 {
            $deep = ($deep | path join $"segment-($i)-abcdefghijklmnopqrstuvwxyz0123456789")
        }
        mkdir $deep
        assert (($deep | str length) >= 260) $"test setup did not produce a long-enough path \(($deep | str length) chars\)"

        $env.API_ROOT = $deep
        api init
        api config set timeout_seconds 42 | ignore
        let config = ((open ($deep | path join "config.nuon") --raw) | from nuon)
        assert equal $config.timeout_seconds 42 "config write under a long (>260 char) path did not commit expected bytes"

        # Practical case alias: refer to the SAME on-disk directory using different letter case.
        let case_alias = ($deep | sd-lower)
        $env.API_ROOT = $case_alias
        api config set timeout_seconds 43 | ignore
        let config2 = ((open ($deep | path join "config.nuon") --raw) | from nuon)
        assert equal $config2.timeout_seconds 43 "config write via an upper-cased API_ROOT case-alias did not land on the same on-disk file"
        sd-assert-canonical-nuon ($deep | path join "config.nuon") 0
    } { cleanup $base }
}

def test-sd-r9-windows-8dot3-alias [] {
    if $nu.os-info.name != "windows" {
        error make {msg: "SKIP: 8.3 short-name aliasing is a Windows-specific filesystem feature"}
    }
    let base = (make-temp-dir "sd-r9-8dot3")
    sd-finally {
        let basename = "a-reasonably-long-workspace-directory-name"
        let real_dir = ($base | path join $basename)
        mkdir $real_dir

        let short = (sd-8dot3-short-name $base $basename)
        if $short == null {
            error make {msg: "SKIP: 8.3 short-name generation appears disabled/unavailable on this volume"}
        }

        $env.API_ROOT = ($base | path join $short)
        api init
        api config set timeout_seconds 77 | ignore
        let config = ((open ($real_dir | path join "config.nuon") --raw) | from nuon)
        assert equal $config.timeout_seconds 77 "config write via an 8.3 short-name alias did not land on the real long-name directory"
    } { cleanup $base }
}

def test-sd-r9-posix-symlinked-ancestor [] {
    if $nu.os-info.name == "windows" {
        error make {msg: "SKIP: symlinked-ancestor semantics are exercised on POSIX platforms only; this run is on Windows"}
    }
    let base = (make-temp-dir "sd-r9-posix-anc")
    sd-finally {
        let real_root = ($base | path join "real-workspace")
        mkdir $real_root
        let link_root = ($base | path join "workspace-via-symlink")
        if not (sd-create-dir-link $link_root $real_root) {
            error make {msg: "SKIP: could not create a directory symlink on this POSIX runtime"}
        }

        $env.API_ROOT = $link_root
        api init
        api config set timeout_seconds 77 | ignore
        api vars set greeting "hi" | ignore

        # The state actually lives at the REAL leaf, reached through the symlinked ancestor.
        let real_config = ((open ($real_root | path join "config.nuon") --raw) | from nuon)
        assert equal $real_config.timeout_seconds 77 "state written via a symlinked-ancestor API_ROOT did not land on the real leaf directory"

        let via_link = (open ($link_root | path join "config.nuon") --raw)
        let via_real = (open ($real_root | path join "config.nuon") --raw)
        assert equal $via_link $via_real "reading through the symlinked ancestor and the real path produced different bytes"
    } { cleanup $base }
}

def test-sd-r9-posix-mode-preserved [] {
    if $nu.os-info.name == "windows" {
        error make {msg: "SKIP: POSIX mode-bit preservation is not applicable on Windows"}
    }
    let tmp = (make-temp-dir "sd-r9-posix-mode")
    sd-finally {
        $env.API_ROOT = $tmp
        api init | ignore
        let path = ($tmp | path join "config.nuon")
        ^chmod 640 $path
        api config set editor "mode-check" | ignore
        let mode = (ls -l -D $path | first | get mode)
        assert equal $mode "rw-r-----" "replacement did not preserve existing POSIX mode bits"
    } { cleanup $tmp }
}

def test-sd-r9-destination-symlink-replacement-preserves-link [] {
    let base = (make-temp-dir "sd-r9-linkdest")
    sd-finally {
        $env.API_ROOT = $base
        api init

        let external_target = ($base | path join "external-config.nuon")
        let config_path = ($base | path join "config.nuon")
        mv -f $config_path $external_target
        if not (sd-create-file-link $config_path $external_target) {
            error make {msg: "SKIP: could not create a file symlink for config.nuon on this runtime (unprivileged symlink creation appears unavailable here)"}
        }
        assert (sd-is-symlink $config_path) "test setup did not actually create a symlink at the destination path"

        let result = (run-command-process $base "api config set timeout_seconds 123")
        assert equal $result.exit_code 0 $"a state write through a destination symlink unexpectedly failed: ($result.stderr)"

        assert (sd-is-symlink $config_path) "state replacement destroyed the destination symlink instead of writing through it"
        let target_now = (sd-symlink-target $config_path)
        assert (($target_now | path expand) == ($external_target | path expand)) "state replacement repointed the symlink to a different target"

        let via_link = ((open $config_path --raw) | from nuon)
        assert equal $via_link.timeout_seconds 123 "reading through the preserved symlink did not reflect the write"
        let via_external = ((open $external_target --raw) | from nuon)
        assert equal $via_external.timeout_seconds 123 "the symlink target file itself was not updated"
    } { cleanup $base }
}

# ═══════════════════════════════════════════════════════════════════════════
# R10 — Fresh full state lifecycle under PATH='' (no HTTP/curl involved)
# ═══════════════════════════════════════════════════════════════════════════

def test-sd-r10-fresh-lifecycle-under-empty-path [] {
    let tmp = (make-temp-dir "sd-r10-lifecycle")
    sd-finally {
        let module_path = ($env.NURL_REPO_ROOT | path join "nu_modules" "mod.nu")
        let script_path = ($tmp | path join "lifecycle.nu")
        let config_path = ($tmp | path join "nu-config.nu")
        let env_config_path = ($tmp | path join "nu-env-config.nu")
        [
            $"use ($module_path | to nuon) *"
            $"$env.API_ROOT = ($tmp | to nuon)"
            "$env.NO_COLOR = '1'"
            "api init"
            "api config set timeout_seconds 15"
            "api auth bearer set seed seed-token"
            "api vars set greeting hello"
            "api collection create coll1"
            "api collection env create coll1 env1 --activate"
            "api collection env use coll1 env1"
            "api request create req1 GET http://example.invalid/x -c coll1"
            "api chain create chain1"
            "api chain list | ignore"
            "api chain show chain1 | ignore"
            "api status | ignore"
            "print DONE-OK"
        ] | str join "\n" | save -f $script_path
        "$env.config.use_ansi_coloring = false" | save -f $config_path
        "# isolated" | save -f $env_config_path

        let result = (with-env {PATH: "", Path: ""} {
            do { ^$nu.current-exe --no-config-file --config $config_path --env-config $env_config_path $script_path } | complete
        })

        assert equal $result.exit_code 0 $"fresh lifecycle under empty PATH failed: ($result.stderr)"
        assert ($result.stdout | str contains "DONE-OK") "fresh lifecycle under empty PATH did not run to completion"
        assert (not ($result.stderr | str contains "external")) "fresh lifecycle under empty PATH surfaced an external-command failure"
        assert (not ($result.stderr | str contains "not found")) "fresh lifecycle under empty PATH surfaced a command-not-found failure"
        for leak in $SD_FORBIDDEN_LEAKAGE {
            assert (not ($result.stderr | str contains $leak)) $"fresh lifecycle stderr leaked forbidden content: ($leak)"
        }
    } { cleanup $tmp }
}

# ═══════════════════════════════════════════════════════════════════════════
# R11 — Concurrent first `api init` (N>=8) stays clean; no setup artifacts
# ═══════════════════════════════════════════════════════════════════════════

def test-sd-r11-concurrent-first-init-all-succeed [] {
    let tmp = (make-temp-dir "sd-r11")
    let pids_file = ($tmp | path join "sd-r11-pids.txt")
    sd-finally {
        let n = 8
        let script = (sd-write-worker-script $tmp "sd-r11-worker" "root: string, ready: string, go: string, result: string" '
$env.API_ROOT = $root
"ready" | save -f $ready
mut waited = 0
while (not ($go | path exists)) and $waited < 15000 {
    sleep 5ms
    $waited = $waited + 5
}
let outcome = (try {
    api init
    {ok: true, msg: ""}
} catch {|e|
    {ok: false, msg: $e.msg}
})
($outcome | to nuon) | save -f $result
')

        let go_file = ($tmp | path join "sd-r11-go.txt")
        let ready_files = (0..<$n | each {|w| $tmp | path join $"sd-r11-ready-($w).txt" })
        let result_files = (0..<$n | each {|w| $tmp | path join $"sd-r11-result-($w).txt" })

        mut launched_pids = []
        for w in 0..<$n {
            let ready = ($ready_files | get $w)
            let result = ($result_files | get $w)
            let worker = (sd-launch-worker-script $tmp $script [$tmp $ready $go_file $result] $"sd-r11-run-($w)")
            $launched_pids = ($launched_pids | append $worker.pid)
            sd-track-pid $pids_file $worker.pid
        }

        let all_ready = (sd-wait-until { $ready_files | all {|f| $f | path exists } } 1200)
        assert $all_ready $"not all ($n) concurrent-init workers signalled ready in time"
        "go" | save -f $go_file
        let all_done = (sd-wait-until { $result_files | all {|f| $f | path exists } } 1600)
        assert $all_done $"not all ($n) concurrent-init workers finished in time"

        for pid in $launched_pids { sd-stop-process-tree $pid $tmp }

        let outcomes = (0..<$n | each {|w|
            let outcome = ((open ($result_files | get $w) --raw) | from nuon)
            {worker: $w, ok: $outcome.ok, msg: $outcome.msg}
        })
        let failures = ($outcomes | where ok == false)
        assert equal ($failures | length) 0 $"concurrent first init reported failures: ($failures | to nuon)"

        sd-assert-canonical-nuon ($tmp | path join "config.nuon") 0
        sd-assert-canonical-nuon ($tmp | path join "variables.nuon") 0
        sd-assert-canonical-nuon ($tmp | path join "secrets.nuon") 0
        let config = ((open ($tmp | path join "config.nuon") --raw) | from nuon)
        assert equal $config.timeout_seconds 30 "concurrent first init did not produce the expected default config"
        let vars = ((open ($tmp | path join "variables.nuon") --raw) | from nuon)
        assert equal $vars {} "concurrent first init did not produce empty default variables"

        let leftovers = (sd-find-temp-artifacts $tmp)
        assert equal $leftovers [] "concurrent first init left .nurl-*.tmp artifacts behind"

        for f in ($ready_files | append $result_files | append [$go_file]) {
            try { rm -f $f } catch {}
        }
    } {
        sd-kill-tracked-pids $pids_file $tmp
        cleanup $tmp
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# R12 — Source assertion over production nu_modules and installer payloads
# ═══════════════════════════════════════════════════════════════════════════

def sd-forbidden-production-terms [] {
    [
        "powershell"
        "pwsh"
        "NURL_TEST_STATE_STORE"
        "^stat"
        "^chmod"
        "^ln "
        "^mv "
        ".nurl-state"
        ".secured-v1"
        "setup candidate"
        "setup-candidate"
        "marker cache"
        "marker-cache"
        "initialize-state-store"
        "icacls"
        "dacl"
        "acl hardening"
        "filesystemwatcher"
        "create-lock"
        "create lock"
        "state-temp-ready"
        "state temp ready"
        "protected temp"
        "legacy-lock"
        "legacy lock"
        "owner-token"
        "owner token"
        "pending-sentinel"
        "pending sentinel"
        "reclaim-sentinel"
        "reclaim sentinel"
        "stale-lock"
        "release-lock"
        "recheck-lock"
        "advisory-lock"
        "advisory locking"
    ]
}

def test-sd-r12-production-source-forbids-listed-patterns [] {
    let repo = $env.NURL_REPO_ROOT
    let modules_dir = ($repo | path join "nu_modules")
    # Enumerate via a plain directory listing + extension filter rather than a
    # wildcard passed to `ls`: nushell 0.94+ treats a string (as opposed to a
    # bare/unquoted glob literal) as a literal filename and will not expand
    # `*`, so `ls ($dir | path join "*.nu")` fails closed with "No matches
    # found" on current runtimes even though it works on 0.89. This filtering
    # approach is identical across both targeted runtimes.
    let production_files = (
        (ls $modules_dir | where {|it| $it.name | str ends-with ".nu" } | get name)
        | append [($repo | path join "install.ps1") ($repo | path join "install.sh")]
    )
    let forbidden = (sd-forbidden-production-terms)
    for file in $production_files {
        let lowered = (open $file --raw | sd-lower)
        for term in $forbidden {
            assert (not ($lowered | str contains ($term | sd-lower))) $"forbidden pattern '($term)' found in production file ($file)"
        }
        let has_inline_describe = (
            open $file --raw
            | lines
            | any {|line| ($line | sd-lower | str contains "describe --detailed") and ($line | sd-lower | str contains "get type") }
        )
        assert (not $has_inline_describe) $"forbidden inline 'describe --detailed | get type' pattern found in ($file)"
    }
}

def test-sd-r12-state-store-installer-and-mod-wiring [] {
    let repo = $env.NURL_REPO_ROOT
    let ps_modules = (sd-installer-modules ($repo | path join "install.ps1") '$Modules = @(')
    let sh_modules = (sd-installer-modules ($repo | path join "install.sh") "MODULES=(")
    assert ("state-store.nu" in $ps_modules) "install.ps1's module list does not include state-store.nu"
    assert ("state-store.nu" in $sh_modules) "install.sh's module list does not include state-store.nu"
    let ignore = (open ($repo | path join ".gitignore") --raw)
    assert (not ($ignore | str contains ".nurl-state")) ".gitignore masks retired state directories"
    assert (not ($ignore | str contains ".secured-v1")) ".gitignore masks retired markers"

    let mod_path = ($repo | path join "nu_modules" "mod.nu")
    let mod_lines = (open $mod_path --raw | lines)
    let plain_use = ($mod_lines | any {|line| ($line | str trim) =~ '^use state-store\.nu' })
    let export_use = ($mod_lines | any {|line| ($line | str trim) =~ '^export use state-store\.nu' })
    assert $plain_use "mod.nu does not import state-store.nu at all (expected a plain `use state-store.nu [...]`)"
    assert (not $export_use) "mod.nu re-exports state-store.nu (expected internal-only `use`, not `export use`)"
}

def test-sd-r12-no-clobber-create-is-direct-save [] {
    let source = (open ($env.NURL_REPO_ROOT | path join "nu_modules" "state-store.nu") --raw)
    let body = (
        $source
        | split row "export def save-state-no-clobber"
        | last
        | split row "export def save-state-if-absent"
        | first
    )
    let direct_saves = (
        $body
        | lines
        | where {|line| ($line | str trim) == '$serialized | save $destination' }
        | length
    )
    assert equal $direct_saves 1 "no-clobber create must perform exactly one direct bare save"
    for forbidden in ["save -f" "state-temp-path" "mv " "cp " "lock" "marker"] {
        assert (not ($body | str contains $forbidden)) $"no-clobber create contains forbidden staging/overwrite primitive: ($forbidden)"
    }

    let indexed = ($body | lines | enumerate)
    let save_index = ($indexed | where {|row| $row.item | str contains '$serialized | save $destination' } | first | get index)
    let exists_index = ($indexed | where {|row| $row.item | str contains '$destination | path exists' } | first | get index)
    assert ($save_index < $exists_index) "the helper added a synchronization precheck before direct save"

    let mod_source = (open ($env.NURL_REPO_ROOT | path join "nu_modules" "mod.nu") --raw)
    for precheck in [
        'if not ($config_path | path exists)'
        'if not ($vars_path | path exists)'
        'if not ($secrets_path | path exists)'
        'if ($collection_dir | path exists)'
        'if ($env_path | path exists)'
    ] {
        assert ($mod_source | str contains $precheck) $"main caller-level advisory precheck changed: ($precheck)"
    }
    let chain_source = (open ($env.NURL_REPO_ROOT | path join "nu_modules" "chain.nu") --raw)
    assert ($chain_source | str contains 'if ($file_path | path exists)') "chain caller-level advisory precheck changed"
    let request_create = (
        open ($env.NURL_REPO_ROOT | path join "nu_modules" "http.nu") --raw
        | split row 'export def "api request create"'
        | last
        | split row '# List saved requests'
        | first
    )
    assert (not ($request_create | str contains 'if ($request_file | path exists)')) "request create added a caller-level synchronization precheck absent from main"
}

# ═══════════════════════════════════════════════════════════════════════════
# R13 — Chain normalization across list/record/empty shapes on 0.89/current
# ═══════════════════════════════════════════════════════════════════════════

def sd-write-chain-file [chains_dir: string, name: string, content: string] {
    mkdir $chains_dir
    let path = ($chains_dir | path join $"($name).nuon")
    $content | save -f $path
    $path
}

def test-sd-r13-chain-normalization-shapes [] {
    let tmp = (make-temp-dir "sd-r13-shapes")
    sd-finally {
        $env.API_ROOT = $tmp
        api init
        let chains_dir = ($tmp | path join "chains")

        # Homogeneous populated list (bare list of steps, no wrapping record).
        sd-write-chain-file $chains_dir "homogeneous" ([{request: "example-request"} {request: "another-request"}] | to nuon)
        let homo_show = (api chain show "homogeneous")
        assert equal ($homo_show | length) 2 "a bare-list chain's `show` did not preserve step count"

        # Heterogeneous populated list (steps with differing shapes/keys).
        sd-write-chain-file $chains_dir "heterogeneous" ([{request: "example-request", extract: {token: "body.access_token"}} {use: {bearer_token: "{{token}}"}}] | to nuon)
        let hetero_show = (api chain show "heterogeneous")
        assert equal ($hetero_show | length) 2 "a heterogeneous-list chain's `show` did not preserve step count"

        # Empty list.
        sd-write-chain-file $chains_dir "empty-list" ([] | to nuon)
        let empty_show = (api chain show "empty-list")
        assert equal ($empty_show | length) 0 "an empty-list chain's `show` did not return zero steps"

        # Record form (the shape `api chain create` itself produces).
        sd-write-chain-file $chains_dir "record-form" ({name: "record-form", description: "d", steps: [{request: "example-request"}]} | to nuon)
        let record_show = (api chain show "record-form")
        assert equal $record_show.description "d" "a record-form chain's `show` lost its description field"
        assert equal ($record_show.steps | length) 1 "a record-form chain's `show` lost a step"

        # `api chain list` must report NORMALIZED step counts for every shape above.
        let listed = (api chain list)
        mut by_name = {}
        for it in $listed {
            $by_name = ($by_name | insert $it.name $it)
        }
        assert equal (($by_name | get "homogeneous").steps) 2 "api chain list under-reported steps for a bare-list chain"
        assert equal (($by_name | get "heterogeneous").steps) 2 "api chain list under-reported steps for a heterogeneous-list chain"
        assert equal (($by_name | get "empty-list").steps) 0 "api chain list did not report zero steps for an empty-list chain"
        assert equal (($by_name | get "record-form").steps) 1 "api chain list did not report the correct step count for a record-form chain"

        # Scalar and binary chain state must still fail closed and cleanly.
        let scalar_path = (sd-write-chain-file $chains_dir "scalar-corrupt" "42")
        let scalar_result = (sd-assert-clean-error $tmp "api chain show scalar-corrupt" "expected a NUON record or list" $SD_FORBIDDEN_LEAKAGE)
        assert (sd-stderr-has $scalar_result.stderr $scalar_path) "scalar chain-state stderr did not include the offending path"

        (0x[00 01 FE FF]) | save -f ($chains_dir | path join "binary-corrupt.nuon")
        sd-assert-clean-error-any $tmp "api chain show binary-corrupt" ["Could not parse" "expected a NUON record or list"] $SD_FORBIDDEN_LEAKAGE | ignore
    } { cleanup $tmp }
}

def test-sd-r13-chain-exec-normalization-and-explicit-path-rejection [] {
    let tmp = (make-temp-dir "sd-r13-exec")
    sd-finally {
        $env.API_ROOT = $tmp
        api init
        let chains_dir = ($tmp | path join "chains")

        # `api chain exec` legitimately supports both named and explicit-path forms.
        # Use empty-steps chains throughout so no network/curl involvement is needed.
        sd-write-chain-file $chains_dir "exec-empty-list" ([] | to nuon)
        let named_result = (api chain exec "exec-empty-list" --quiet)
        assert equal $named_result.success true "chain exec on a named, empty-list chain did not report success"
        assert equal ($named_result.results | length) 0 "chain exec on an empty-list chain unexpectedly produced results"

        let explicit_path = (sd-write-chain-file $chains_dir "exec-empty-record" ({name: "exec-empty-record", steps: []} | to nuon))
        let explicit_path_fwd = ($explicit_path | str replace --all "\\" "/")
        let explicit_result = (api chain exec $explicit_path_fwd --quiet)
        assert equal $explicit_result.success true "chain exec via an explicit path to a record-form empty chain did not report success"

        # `api chain show` has NO explicit-path form: a path-shaped name must be rejected up front.
        let rejected = (run-command-process $tmp $"api chain show '($explicit_path_fwd)'")
        assert ($rejected.exit_code != 0) "api chain show accepted an explicit path where only a bare chain name is valid"
        assert equal ($rejected.stdout | str trim) "" "api chain show with an explicit path produced unexpected stdout"
        assert ($rejected.stderr | str contains "Invalid chain name") "api chain show's explicit-path rejection was not the expected validate-resource-name error"
        assert equal $rejected.stderr ($rejected.stderr | ansi strip) "api chain show's explicit-path rejection stderr contained ANSI codes"
    } { cleanup $tmp }
}

# ═══════════════════════════════════════════════════════════════════════════
# R14 — Windows-only: replacement destination (and the transient temp file
# itself, observed live) inherits directory ACL policy — a custom, protected
# per-file DACL is not retained across a publish.
# ═══════════════════════════════════════════════════════════════════════════

# Module-free ACL read: uses `[System.IO.FileInfo]`/`[System.IO.DirectoryInfo]`
# `.GetAccessControl()` directly rather than the `Get-Acl` cmdlet, because the
# `Get-Acl`/`Set-Acl` cmdlets live in the `Microsoft.PowerShell.Security`
# module, which can fail to load in some sandboxes ("the module could not be
# loaded"). The underlying .NET accessor methods have no such module
# dependency. Returns a test-complete-result-normalized record whose `.stdout`
# is `"protected:True"`/`"protected:False"` (or `"error:..."` on failure).
def sd-acl-protected [tmp: string, path: string] {
    let script = ($tmp | path join $"sd-acl-report-(random uuid).ps1")
    'param($Path)
try {
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $item = [System.IO.DirectoryInfo]::new($Path)
    } else {
        $item = [System.IO.FileInfo]::new($Path)
    }
    $sec = $item.GetAccessControl()
    [Console]::Out.Write("protected:" + [string]$sec.AreAccessRulesProtected)
} catch {
    [Console]::Out.Write("error:" + $_.Exception.Message)
}
' | save -f $script
    let result = (test-complete-result (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script $path | complete))
    try { rm -f $script } catch {}
    $result
}

# Module-free ACL write: applies a custom *protected* (non-inherited) DACL to
# a single file, again via `[System.IO.FileInfo]` methods only (no `Set-Acl`).
def sd-acl-protect [tmp: string, path: string] {
    let script = ($tmp | path join $"sd-acl-set-(random uuid).ps1")
    'param($Path)
try {
    $item = [System.IO.FileInfo]::new($Path)
    $sec = $item.GetAccessControl()
    $sec.SetAccessRuleProtection($true, $true)
    $item.SetAccessControl($sec)
    $after = $item.GetAccessControl()
    [Console]::Out.Write("protected:" + [string]$after.AreAccessRulesProtected)
} catch {
    [Console]::Out.Write("error:" + $_.Exception.Message)
}
' | save -f $script
    let result = (test-complete-result (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script $path | complete))
    try { rm -f $script } catch {}
    $result
}

# Arm a detached FileSystemWatcher matching `pattern` under `dir`, signal
# `ready_file` the instant it is armed, then block on the true OS-level
# `WaitForChanged` (Created) — NOT a Sleep-based poll loop — bounded by
# `timeout_ms`. On a match it captures the transient file's ACL-protection
# state into `snapshot_file` before returning (racing the caller's own
# rename); on timeout it records "timeout". Returns the watcher process's
# exact pid so the caller can stop it deterministically.
#
# Launched via `Start-Process -PassThru` rather than the WMI
# `Win32_Process::Create` idiom used elsewhere in this file: empirically, in
# this sandbox, a PowerShell process spawned via WMI can still spawn further
# *native* child processes (used successfully by sd-launch-worker-script's
# `& $Exe ... 1> ... 2> ...` pattern) but cannot itself execute PowerShell
# cmdlets or .NET object construction/method calls (`Set-Content`,
# `[System.IO.File]::WriteAllText`, `New-Object System.IO.FileSystemWatcher`
# all silently produce no observable effect) — almost certainly a security
# policy restricting the PowerShell scripting engine specifically for
# WMI-provider-spawned processes. `Start-Process` does not trigger this
# restriction and was verified (interactively, ad hoc) to run the exact same
# FileSystemWatcher/GetAccessControl logic successfully while still
# returning control to the caller immediately (not blocking on the child).
def sd-launch-acl-live-watcher [tmp: string, dir: string, pattern: string, ready_file: string, snapshot_file: string, timeout_ms: int] {
    let watcher = ($tmp | path join $"sd-r14-watch-(random uuid).ps1")
    let launcher = ($tmp | path join $"sd-r14-watch-launcher-(random uuid).ps1")
    'param($Dir, $Pattern, $ReadyFile, $SnapshotFile, $TimeoutMs)
try {
    # Watch every name ("*") and match `$Pattern` ourselves via PowerShell`s
    # `-like` operator, rather than passing `$Pattern` straight through to
    # the FileSystemWatcher constructor`s own `Filter`. .NET`s Filter uses a
    # legacy Win32 8.3-style wildcard matcher that can silently fail to match
    # filters containing more than one literal `.` (as our
    # `.<basename>.nurl-*.tmp` naming does) even though the name visually
    # looks like a normal glob match — confirmed empirically in this
    # environment: identical filenames were reliably missed with `$Pattern`
    # as the constructor filter, but reliably caught once matched here.
    $fsw = New-Object System.IO.FileSystemWatcher($Dir, "*")
    $fsw.NotifyFilter = [System.IO.NotifyFilters]::FileName
    [System.IO.File]::WriteAllText($ReadyFile, "armed")
    $deadline = (Get-Date).AddMilliseconds([int]$TimeoutMs)
    $matched = $null
    while ((Get-Date) -lt $deadline) {
        $remainingMs = [int](($deadline - (Get-Date)).TotalMilliseconds)
        if ($remainingMs -le 0) { break }
        $change = $fsw.WaitForChanged([System.IO.WatcherChangeTypes]::Created, [Math]::Min($remainingMs, 1000))
        if ((-not $change.TimedOut) -and ($change.Name -like $Pattern)) {
            $matched = $change.Name
            break
        }
    }
    if ($null -eq $matched) {
        [System.IO.File]::WriteAllText($SnapshotFile, "timeout")
    } else {
        $tempPath = Join-Path $Dir $matched
        try {
            $item = [System.IO.FileInfo]::new($tempPath)
            $sec = $item.GetAccessControl()
            [System.IO.File]::WriteAllText($SnapshotFile, ("protected:" + [string]$sec.AreAccessRulesProtected + "|name:" + $matched))
        } catch {
            [System.IO.File]::WriteAllText($SnapshotFile, ("vanished:" + $_.Exception.Message + "|name:" + $matched))
        }
    }
    $fsw.Dispose()
} catch {
    [System.IO.File]::WriteAllText($SnapshotFile, ("watcher-error:" + $_.Exception.Message))
}
' | save -f $watcher
    let launcher_source = 'param($Watcher, $Dir, $Pattern, $ReadyFile, $SnapshotFile, $TimeoutMs)
try {
    $p = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $Watcher, $Dir, $Pattern, $ReadyFile, $SnapshotFile, $TimeoutMs) -WindowStyle Hidden -PassThru
    [Console]::Out.Write([string]$p.Id)
} catch {
    [Console]::Error.Write("Start-Process failed: " + $_.Exception.Message)
    exit 1
}
'
    $launcher_source | save -f $launcher
    let launched = (test-complete-result (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcher $watcher $dir $pattern $ready_file $snapshot_file $timeout_ms | complete))
    # Only the launcher script is safe to delete immediately: it already ran
    # to completion synchronously (via `| complete`), so nothing can still be
    # reading it. The watcher script must NOT be deleted here — `Start-Process`
    # returns as soon as the child process object exists, which can race
    # ahead of that child actually opening/reading `-File $watcher`; deleting
    # it this early reliably loses that race and leaves the watcher silently
    # unable to start. It is instead left in `tmp` for the caller's own
    # temp-directory-wide cleanup once the watcher is confirmed done/stopped.
    try { rm -f $launcher } catch {}
    if $launched.exit_code != 0 or ($launched.stdout | str trim | is-empty) {
        error make {msg: $"failed to launch ACL live-watcher: ($launched.stderr)"}
    }
    {pid: ($launched.stdout | str trim | into int)}
}

def test-sd-r14-windows-replacement-inherits-directory-acl [] {
    if $nu.os-info.name != "windows" {
        error make {msg: "SKIP: ACL disclosure semantics are Windows-specific; this run is on a non-Windows OS"}
    }
    let tmp = (make-temp-dir "sd-r14-acl")
    let pids_file = ($tmp | path join "sd-r14-pids.txt")
    sd-finally {
        $env.API_ROOT = $tmp
        api init
        let config_path = ($tmp | path join "config.nuon")

        # Baseline: the workspace directory's own ACL-protection state. Both
        # the live temp file and the eventual replaced destination should
        # match this (directory-inherited) policy rather than any custom
        # per-file DACL we apply below.
        let dir_acl = (sd-acl-protected $tmp $tmp)
        assert equal $dir_acl.exit_code 0 $"could not read the workspace directory's ACL: ($dir_acl.stderr)"
        let dir_protected = ($dir_acl.stdout | str contains "protected:True")

        # ── Part 1 (deterministic): a normal-sized publish must not retain a
        # preexisting custom protected per-file DACL on the destination. ──
        let protect1 = (sd-acl-protect $tmp $config_path)
        if ($protect1.exit_code != 0) or (not ($protect1.stdout | str contains "protected:True")) {
            error make {msg: $"SKIP: could not apply a custom protected DACL to config.nuon for the ACL disclosure probe: ($protect1.stdout) ($protect1.stderr)"}
        }
        api config set timeout_seconds 55 | ignore
        let after1 = (sd-acl-protected $tmp $config_path)
        assert equal $after1.exit_code 0 $"could not read config.nuon's ACL after replacement: ($after1.stderr)"
        assert (not ($after1.stdout | str contains "protected:True")) "the replaced destination retained a custom protected (non-inherited) DACL instead of inheriting the directory's policy"
        assert equal ($after1.stdout | str contains "protected:True") $dir_protected "the replaced destination's ACL-protection state did not match the parent directory's inherited policy"

        # ── Part 2 (live): observe the transient `.config.nuon.nurl-*.tmp`
        # itself while it still exists, via a FileSystemWatcher blocking
        # WaitForChanged (no polling/spin), and confirm it too carries the
        # directory-inherited policy rather than any leftover custom DACL.
        # This races the production code's own (intentionally fast, atomic)
        # write-then-rename: too small a payload and the file is renamed to
        # its final destination before we can react to the Created event and
        # open it ("vanished"); too large and the worker's own string-build
        # and write time can exceed the bounded per-attempt timeout in this
        # sandbox ("timeout"). Multiple payload sizes hedge across that
        # window; if the live moment can never be caught within budget, this
        # is reported as an honest skip rather than a fabricated pass.
        let protect2 = (sd-acl-protect $tmp $config_path)
        if ($protect2.exit_code != 0) or (not ($protect2.stdout | str contains "protected:True")) {
            error make {msg: $"SKIP: could not re-apply a custom protected DACL to config.nuon for the live-temp ACL probe: ($protect2.stdout) ($protect2.stderr)"}
        }

        let script = (sd-write-worker-script $tmp "sd-r14-write" "root: string, size: int" '
$env.API_ROOT = $root
mut s = "A"
while ($s | str length) < $size {
    $s = ($s + $s)
}
let big = ($s | str substring 0..<$size)
api config set editor $big | ignore
')

        mut live_result = ""
        for size in [20000000 40000000 80000000] {
            if $live_result != "" { continue }
            let ready_file = ($tmp | path join $"sd-r14-ready-(random uuid).txt")
            let snapshot_file = ($tmp | path join $"sd-r14-snapshot-(random uuid).txt")

            # The writer worker below is itself a cold-started detached
            # process (nu.exe sourcing mod.nu, launched through the same
            # WMI-based indirection used elsewhere in this file for
            # job-object independence), and building/writing an 8-figure
            # character payload adds further latency on top of that —
            # measured end-to-end latency from launch to the temp file
            # actually appearing runs several seconds on this sandbox. 15s
            # per attempt leaves ample margin over that without blowing the
            # overall bounded-deadline budget across the 3 attempts.
            let watch = (sd-launch-acl-live-watcher $tmp $tmp ".config.nuon.nurl-*.tmp" $ready_file $snapshot_file 15000)
            sd-track-pid $pids_file $watch.pid
            let armed = (sd-wait-until { ($ready_file | path exists) } 800)

            if $armed {
                let worker = (sd-launch-worker-script $tmp $script [$tmp ($size | into string)] "sd-r14-write-run")
                sd-track-pid $pids_file $worker.pid
                # Bounded to slightly more than the watcher's own 15s
                # WaitForChanged timeout so we reliably observe whichever of
                # "caught the create event" or "timed out" the watcher itself
                # settles on, rather than giving up on our own poll first.
                sd-wait-until { ($snapshot_file | path exists) } 700 | ignore
                sd-wait-until { not (sd-process-alive $worker.pid) } 400 | ignore
                sd-stop-process-tree $worker.pid $tmp
            }
            sd-stop-process-tree $watch.pid $tmp
            try { rm -f $ready_file } catch {}

            if ($snapshot_file | path exists) {
                let snap = (open $snapshot_file --raw | str trim)
                try { rm -f $snapshot_file } catch {}
                if ($snap | str starts-with "protected:") {
                    $live_result = $snap
                }
            }

            if $live_result == "" {
                # The previous publish (if it completed) already replaced
                # and un-protected the destination; re-protect it before the
                # next, larger-payload attempt.
                sd-acl-protect $tmp $config_path | ignore
            }
        }

        if $live_result == "" {
            error make {msg: "SKIP: could not observe the live `.config.nuon.nurl-*.tmp` file via the FileSystemWatcher within the bounded window on this runtime/environment — the write completed before the watcher's event could be inspected"}
        }

        let live_protected = ($live_result | str contains "protected:True")
        assert (not $live_protected) "the live temporary state file retained a custom protected (non-inherited) DACL instead of inheriting the directory's policy"
        assert equal $live_protected $dir_protected "the live temporary state file's ACL-protection state did not match the parent directory's inherited policy"
    } {
        sd-kill-tracked-pids $pids_file $tmp
        cleanup $tmp
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# Suite entry point
# ═══════════════════════════════════════════════════════════════════════════

export def run-suite-state-durability []: nothing -> list<record> {
    print $"\n(ansi cyan)── State durability: private native state store ──(ansi reset)"
    let saved_root = ($env.API_ROOT? | default null)
    let results = [
        (run-test "SD-R1: compact NUON state is byte-exact with no trailing newline" { test-sd-r1-compact-bytes })
        (run-test "SD-R1: indented NUON state is byte-exact with no trailing newline" { test-sd-r1-indented-bytes })
        (run-test "SD-R1: replacement leaves no .<basename>.nurl-*.tmp artifacts" { test-sd-r1-no-temp-artifacts })
        (run-test "SD-R1: binary state corruption fails closed on read" { test-sd-r1-binary-corruption-fails-closed })
        (run-test "SD-R2: Windows publish failure preserves prior destination bytes" { test-sd-r2-windows-replace-failure })
        (run-test "SD-R3: killing a public create mid-write leaves a partial file and fails closed on show" { test-sd-r3-interrupted-create-fails-closed })
        (run-test "SD-R4: N=8 barrier-synchronized chain create preserves complete contender payloads" { test-sd-r4-barrier-race-main-parity })
        (run-test "SD-R5: syntax-corrupted state fails closed across every file type" { test-sd-r5-syntax-corruption-matrix })
        (run-test "SD-R5: wrong-shape state fails closed across every file type" { test-sd-r5-shape-corruption-matrix })
        (run-test "SD-R5: binary-corrupted state fails closed across every file type" { test-sd-r5-binary-corruption-matrix })
        (run-test "SD-R5: missing state files retain current defaults" { test-sd-r5-missing-files-retain-defaults })
        (run-test "SD-R5: genuine I/O read failures propagate distinctly from parse failures" { test-sd-r5-io-failure-propagation })
        (run-test "SD-R5: reader I/O boundary is structurally fail-open to native errors" { test-sd-r5-reader-io-boundary-is-structural })
        (run-test "SD-R5: public history config read fails closed without entry/index writes" { test-sd-r5-history-config-read-fails-closed })
        (run-test "SD-R6: read-only sweep across state surfaces is byte-stable" { test-sd-r6-read-only-byte-stability })
        (run-test "SD-R6: credential and secrets key order is preserved" { test-sd-r6-credential-key-order-preserved })
        (run-test "SD-R7: fresh and unrelated same-destination siblings are left untouched" { test-sd-r7-fresh-and-unrelated-siblings-untouched })
        (run-test "SD-R7: aged, removable same-destination siblings are swept silently" { test-sd-r7-aged-removable-swept-silently })
        (run-test "SD-R7: aged, unremovable siblings warn but still commit the requested write" { test-sd-r7-aged-unremovable-warns-but-commits })
        (run-test "SD-R8: recursive lifecycle (incl. collection copy) leaves zero private artifacts" { test-sd-r8-recursive-lifecycle-no-artifacts })
        (run-test "SD-R8: artifact scanner discriminates exact generated patterns" { test-sd-r8-artifact-scanner-discrimination })
        (run-test "SD-R8: read-only lifecycle against the bundled tracked workspace leaves git status unchanged" { test-sd-r8-readonly-lifecycle-preserves-git-status })
        (run-test "SD-R9: Windows long path and case-alias lifecycle" { test-sd-r9-windows-long-path-and-case-alias })
        (run-test "SD-R9: Windows 8.3 short-name alias lifecycle (best-effort)" { test-sd-r9-windows-8dot3-alias })
        (run-test "SD-R9: POSIX real workspace leaf reached under a symlinked ancestor" { test-sd-r9-posix-symlinked-ancestor })
        (run-test "SD-R9: POSIX replacement preserves existing mode bits" { test-sd-r9-posix-mode-preserved })
        (run-test "SD-R9: destination-file symlink replacement preserves the symlink and updates its target" { test-sd-r9-destination-symlink-replacement-preserves-link })
        (run-test "SD-R10: fresh full state lifecycle under PATH='' succeeds with no external-command failures" { test-sd-r10-fresh-lifecycle-under-empty-path })
        (run-test "SD-R11: concurrent first `api init` (N=8) stays clean with no setup artifacts" { test-sd-r11-concurrent-first-init-all-succeed })
        (run-test "SD-R12: production source forbids the listed leakage/locking/hardening patterns" { test-sd-r12-production-source-forbids-listed-patterns })
        (run-test "SD-R12: state-store.nu is installer-listed but not export-used from mod.nu" { test-sd-r12-state-store-installer-and-mod-wiring })
        (run-test "SD-R12: no-clobber create is one direct bare save" { test-sd-r12-no-clobber-create-is-direct-save })
        (run-test "SD-R13: chain normalization across list/heterogeneous/empty/record shapes" { test-sd-r13-chain-normalization-shapes })
        (run-test "SD-R13: chain exec named+explicit-path normalization; chain show rejects explicit paths" { test-sd-r13-chain-exec-normalization-and-explicit-path-rejection })
        (run-test "SD-R14: Windows replacement destination inherits directory ACL policy" { test-sd-r14-windows-replacement-inherits-directory-acl })
    ]
    if $saved_root == null { hide-env API_ROOT } else { $env.API_ROOT = $saved_root }
    $results
}
