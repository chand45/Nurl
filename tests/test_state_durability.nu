# Durable native state persistence regressions.

use ../nu_modules/string-compat.nu [ascii-upcase]
use ../nu_modules/state-store.nu [commit-state-replace state-persistence-contract verify-state-publication]

const SD_UUID = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
const SD_FORBIDDEN_ERROR_TEXT = [
    "nu::parser"
    "nu::shell::outsidespan"
    "Unexpected end of code"
    "STATE-CONTENT-SENTINEL"
    "CREDENTIAL-SENTINEL"
]

def sd-finally [body: closure, teardown: closure] {
    let outcome = try {
        do $body
        {ok: true, message: ""}
    } catch {|error|
        {ok: false, message: $error.msg}
    }
    do $teardown
    if not $outcome.ok {
        error make {msg: $outcome.message}
    }
}

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

def sd-snapshot [root: string] {
    sd-entries $root | each {|path|
        let kind = ($path | path type)
        {
            path: ($path | path relative-to $root | str replace --all "\\" "/")
            type: $kind
            content: (if $kind == "file" { open $path --raw } else { null })
        }
    } | sort-by path
}

def sd-message-count [text: string, message: string] {
    (($text | split row $message | length) - 1)
}

def sd-collapse-rendering [text: string] {
    $text | str replace --all --regex '[\s|]+' ""
}

def sd-stderr-has [stderr: string, expected: string] {
    (sd-collapse-rendering $stderr) | str contains (sd-collapse-rendering $expected)
}

def sd-is-nu-089 [] {
    (version | get version | str starts-with "0.89.")
}

def sd-assert-clean-failure [
    root: string
    command: string
    expected: string
    --unchanged
] {
    let before = if $unchanged { sd-snapshot $root } else { [] }
    let result = (run-command-process $root $command)
    assert ($result.exit_code != 0) $"expected nonzero exit for: ($command)"
    assert equal ($result.stdout | str trim) "" $"expected empty stdout for: ($command)"
    assert (sd-stderr-has $result.stderr $expected) $"stderr omitted '($expected)' for ($command): ($result.stderr)"
    assert equal $result.stderr ($result.stderr | ansi strip) $"stderr contained ANSI for: ($command)"
    for forbidden in $SD_FORBIDDEN_ERROR_TEXT {
        assert (not ($result.stderr | str contains $forbidden)) $"stderr leaked '($forbidden)' for: ($command)"
    }
    if $unchanged {
        assert equal (sd-snapshot $root) $before $"failure mutated state for: ($command)"
    }
    $result
}

def sd-with-original-bytes [path: string, body: closure] {
    let original = (open $path --raw)
    sd-finally $body { $original | save -f $path }
}

def sd-python [] {
    if $nu.os-info.name == "windows" {
        "python"
    } else {
        "python3"
    }
}

def sd-process-alive [pid: int] {
    try {
        (ps | where pid == $pid | length) > 0
    } catch {
        false
    }
}

def sd-wait-for [predicate: closure, attempts: int = 400] {
    mut index = 0
    while $index < $attempts {
        if (do $predicate) {
            return true
        }
        sleep 25ms
        $index = $index + 1
    }
    do $predicate
}

def sd-start-windows-lock [tmp: string, target: string, share: string] {
    let holder = ($tmp | path join $"lock-holder-(random uuid).ps1")
    let launcher = ($tmp | path join $"lock-launcher-(random uuid).ps1")
    let ready = ($tmp | path join $"lock-ready-(random uuid).txt")
    let stop = ($tmp | path join $"lock-stop-(random uuid).txt")
    'param($Target, $Share, $Ready, $Stop)
$stream = [System.IO.File]::Open(
    $Target,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::$Share
)
[System.IO.File]::WriteAllText($Ready, "ready")
$clock = [System.Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path -LiteralPath $Stop) -and $clock.Elapsed.TotalSeconds -lt 90) {
    Start-Sleep -Milliseconds 50
}
$stream.Close()
' | save -f $holder
    'param($Holder, $Target, $Share, $Ready, $Stop)
$command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Holder`" `"$Target`" `"$Share`" `"$Ready`" `"$Stop`""
$created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine = $command}
if ($created.ReturnValue -ne 0) { exit $created.ReturnValue }
[Console]::Out.Write($created.ProcessId)
' | save -f $launcher
    let launched = (test-complete-result (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcher $holder $target $share $ready $stop | complete))
    assert equal $launched.exit_code 0 $"could not launch file-lock holder: ($launched.stderr)"
    let pid = ($launched.stdout | str trim | into int)
    assert (sd-wait-for { $ready | path exists } 1200) "file-lock holder did not become ready"
    {pid: $pid, holder: $holder, launcher: $launcher, ready: $ready, stop: $stop}
}

def sd-stop-windows-lock [lock: record] {
    "stop" | save -f $lock.stop
    sd-wait-for { not (sd-process-alive $lock.pid) } 400 | ignore
    if (sd-process-alive $lock.pid) {
        ^powershell.exe -NoProfile -NonInteractive -Command $"Stop-Process -Id ($lock.pid) -Force" | complete | ignore
    }
    for path in [$lock.holder $lock.launcher $lock.ready $lock.stop] {
        try { rm -f $path } catch {}
    }
}

def sd-start-windows-file-holder [
    tmp: string
    target: string
    access: string
    share: string
    lock_offset: int = -1
    lock_length: int = 1
] {
    let holder = ($tmp | path join $"file-holder-(random uuid).ps1")
    let launcher = ($tmp | path join $"file-holder-launcher-(random uuid).ps1")
    let ready = ($tmp | path join $"file-holder-ready-(random uuid).txt")
    let stop = ($tmp | path join $"file-holder-stop-(random uuid).txt")
    'param($Target, $Access, $Share, $LockOffsetText, $LockLengthText, $Ready, $Stop)
try {
    $LockOffset = [long]$LockOffsetText.Substring(1)
    $LockLength = [long]$LockLengthText.Substring(1)
    $stream = [System.IO.File]::Open(
        $Target,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::$Access,
        [System.Enum]::Parse([System.IO.FileShare], $Share)
    )
    if ($LockOffset -ge 0) { $stream.Lock($LockOffset, $LockLength) }
    [System.IO.File]::WriteAllText($Ready, "ready")
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $Stop) -and $clock.Elapsed.TotalSeconds -lt 90) {
        Start-Sleep -Milliseconds 25
    }
    if ($LockOffset -ge 0) {
        try { $stream.Unlock($LockOffset, $LockLength) } catch {}
    }
    $stream.Close()
} catch {
    [System.IO.File]::WriteAllText($Ready, "error: " + $_.Exception.Message)
    exit 1
}
' | save -f $holder
    'param($Holder, $Target, $Access, $Share, $LockOffsetText, $LockLengthText, $Ready, $Stop)
$command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Holder`" `"$Target`" `"$Access`" `"$Share`" `"$LockOffsetText`" `"$LockLengthText`" `"$Ready`" `"$Stop`""
$created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine = $command}
if ($created.ReturnValue -ne 0) { exit $created.ReturnValue }
[Console]::Out.Write($created.ProcessId)
' | save -f $launcher
    let launched = (test-complete-result (
    ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcher $holder $target $access $share $"v($lock_offset)" $"v($lock_length)" $ready $stop
        | complete
    ))
    assert equal $launched.exit_code 0 $"could not launch file holder: ($launched.stderr)"
    let pid = ($launched.stdout | str trim | into int)
    assert (sd-wait-for { $ready | path exists } 1200) "file holder did not become ready"
    assert equal (open $ready --raw) "ready" $"file holder failed: (open $ready --raw)"
    {pid: $pid, holder: $holder, launcher: $launcher, ready: $ready, stop: $stop}
}

def sd-start-windows-reader-monitor [
    tmp: string
    target: string
    old_byte: int
    intended_byte: int
] {
    let monitor = ($tmp | path join $"reader-monitor-(random uuid).ps1")
    let launcher = ($tmp | path join $"reader-monitor-launcher-(random uuid).ps1")
    let ready = ($tmp | path join $"reader-monitor-ready-(random uuid).txt")
    let stop = ($tmp | path join $"reader-monitor-stop-(random uuid).txt")
    let observation = ($tmp | path join $"reader-monitor-observation-(random uuid).txt")
    'param($Target, [int]$OldByte, [int]$IntendedByte, $Ready, $Stop, $Observation)
[System.IO.File]::WriteAllText($Ready, "ready")
$observed = $false
$clock = [System.Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path -LiteralPath $Stop) -and $clock.Elapsed.TotalSeconds -lt 90) {
    try {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stream = [System.IO.File]::Open($Target, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        $length = $stream.Length
        if ($length -gt 0) {
            $positions = @(0, [Math]::Floor(($length - 1) / 2), $length - 1)
            $samples = foreach ($position in $positions) {
                [void]$stream.Seek($position, [System.IO.SeekOrigin]::Begin)
                $stream.ReadByte()
            }
            $allOld = ($samples | Where-Object { $_ -ne $OldByte }).Count -eq 0
            $allIntended = ($samples | Where-Object { $_ -ne $IntendedByte }).Count -eq 0
            if (-not $allOld -and -not $allIntended) { $observed = $true }
        }
        $stream.Close()
    } catch {}
}
$result = if ($observed) { "torn-observed" } else { "not-observed" }
[System.IO.File]::WriteAllText($Observation, $result)
' | save -f $monitor
    'param($Monitor, $Target, $OldByte, $IntendedByte, $Ready, $Stop, $Observation)
$command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Monitor`" `"$Target`" `"$OldByte`" `"$IntendedByte`" `"$Ready`" `"$Stop`" `"$Observation`""
$created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine = $command}
if ($created.ReturnValue -ne 0) { exit $created.ReturnValue }
[Console]::Out.Write($created.ProcessId)
' | save -f $launcher
    let launched = (test-complete-result (
        ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcher $monitor $target $old_byte $intended_byte $ready $stop $observation
        | complete
    ))
    assert equal $launched.exit_code 0 $"could not launch reader monitor: ($launched.stderr)"
    let pid = ($launched.stdout | str trim | into int)
    assert (sd-wait-for { $ready | path exists } 1200) "reader monitor did not become ready"
    {pid: $pid, monitor: $monitor, launcher: $launcher, ready: $ready, stop: $stop, observation: $observation}
}

def sd-stop-windows-reader-monitor [monitor: record] {
    "stop" | save -f $monitor.stop
    assert (sd-wait-for { not (sd-process-alive $monitor.pid) } 400) "reader monitor did not stop"
    assert ($monitor.observation | path exists) "reader monitor omitted its observation"
    let observation = (open $monitor.observation --raw)
    for path in [$monitor.monitor $monitor.launcher $monitor.ready $monitor.stop $monitor.observation] {
        try { rm -f $path } catch {}
    }
    $observation
}

def sd-write-windows-byte-file [tmp: string, path: string, byte: int, length: int] {
    let script = ($tmp | path join $"write-byte-file-(random uuid).ps1")
    'param($Path, $ByteText, $LengthText)
$ErrorActionPreference = "Stop"
$value = [byte]$ByteText.Substring(1)
$length = [long]$LengthText.Substring(1)
$buffer = [byte[]]::new(1048576)
if ($value -ne 0) {
    for ($index = 0; $index -lt $buffer.Length; $index++) { $buffer[$index] = $value }
}
$stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
$remaining = $length
while ($remaining -gt 0) {
    $count = [int][Math]::Min($buffer.Length, $remaining)
    $stream.Write($buffer, 0, $count)
    $remaining -= $count
}
$stream.Close()
' | save -f $script
    let result = (test-complete-result (
        ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script $path $"v($byte)" $"v($length)"
        | complete
    ))
    rm -f $script
    assert equal $result.exit_code 0 $"could not create byte fixture: ($result.stderr)"
}

def sd-sample-windows-file [tmp: string, path: string, positions: list<int>] {
    let script = ($tmp | path join $"sample-byte-file-(random uuid).ps1")
    'param($Path, $PositionsText)
$positions = $PositionsText.Substring(1).Split(",") | ForEach-Object { [long]$_ }
$share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
$stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
$samples = foreach ($position in $positions) {
    [void]$stream.Seek($position, [System.IO.SeekOrigin]::Begin)
    $stream.ReadByte()
}
$length = $stream.Length
$stream.Close()
[Console]::Out.Write("$length;$($samples -join ",")")
' | save -f $script
    let encoded_positions = ($positions | each {|position| $position | into string } | str join ",")
    let result = (test-complete-result (
        ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script $path $"v($encoded_positions)"
        | complete
    ))
    rm -f $script
    assert equal $result.exit_code 0 $"could not sample byte fixture: ($result.stderr)"
    let fields = ($result.stdout | split row ";")
    {
        length: ($fields | get 0 | into int)
        samples: ($fields | get 1 | split row "," | each {|sample| $sample | into int })
    }
}

def sd-state-commit-command [temp_path: string, destination: string] {
    let module = ($env.NURL_REPO_ROOT | path join "nu_modules" "state-store.nu")
    $"use ($module | to nuon) [commit-state-replace]; let intended = \(open ($temp_path | to nuon) --raw\); commit-state-replace $intended ($temp_path | to nuon) ($destination | to nuon)"
}

def sd-state-commit-caught-command [
    temp_path: string
    destination: string
    intended_path: string = ""
] {
    let module = ($env.NURL_REPO_ROOT | path join "nu_modules" "state-store.nu")
    let intended_source = if ($intended_path | is-empty) { $temp_path } else { $intended_path }
    [
        $"use ($module | to nuon) [commit-state-replace]"
        $"let intended = \(open ($intended_source | to nuon) --raw\)"
        "try {"
        $"    commit-state-replace $intended ($temp_path | to nuon) ($destination | to nuon)"
        "} catch {|error|"
        '    error make {msg: ("STATE_PUBLICATION_CAUGHT: " + $error.msg)}'
        "}"
    ] | str join "\n"
}

def sd-state-verify-command [serialized: any, temp_path: string, destination: string] {
    let module = ($env.NURL_REPO_ROOT | path join "nu_modules" "state-store.nu")
    $"use ($module | to nuon) [verify-state-publication]; verify-state-publication ($serialized | to nuon) ($temp_path | to nuon) ($destination | to nuon)"
}

def sd-state-verify-from-file-command [intended_path: string, temp_path: string, destination: string] {
    let module = ($env.NURL_REPO_ROOT | path join "nu_modules" "state-store.nu")
    $"use ($module | to nuon) [verify-state-publication]; let intended = \(open ($intended_path | to nuon) --raw\); verify-state-publication $intended ($temp_path | to nuon) ($destination | to nuon)"
}

def sd-assert-no-publication-claim [stderr: string] {
    for forbidden in ["previous file was preserved" "corrupt" "atomic" "non-atomic"] {
        assert (not (($stderr | ascii-upcase) | str contains ($forbidden | ascii-upcase))) $"publication diagnostic asserted '($forbidden)': ($stderr)"
    }
}

def sd-byte-at [value: any, index: int] {
    let end = ($index + 1)
    $value | into binary | bytes at $index..<$end
}

def sd-age-path [tmp: string, path: string] {
    if $nu.os-info.name == "windows" {
        let script = ($tmp | path join $"age-(random uuid).ps1")
        'param($Path)
$stamp = (Get-Date).ToUniversalTime().AddHours(-2)
if (Test-Path -LiteralPath $Path -PathType Container) {
    [System.IO.Directory]::SetLastWriteTimeUtc($Path, $stamp)
} else {
    [System.IO.File]::SetLastWriteTimeUtc($Path, $stamp)
}
' | save -f $script
        let result = (test-complete-result (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script $path | complete))
        rm -f $script
        assert equal $result.exit_code 0 $"could not age path: ($result.stderr)"
    } else {
        let stamp = ((date now) - 2hr | format date "%Y%m%d%H%M.%S")
        let result = (test-complete-result (^touch -t $stamp $path | complete))
        assert equal $result.exit_code 0 $"could not age path: ($result.stderr)"
    }
}

def sd-relative-parent [root: string, path: string] {
    let relative = (($path | path dirname) | path relative-to $root | str replace --all "\\" "/")
    if $relative == "." { "" } else { $relative }
}

def sd-state-artifacts [root: string, expected: list<record>] {
    let setup_pattern = $"^\\.nurl-state-setup-($SD_UUID)$"
    let temp_pattern = $"^\\.[^\\\\/]+\\.nurl-($SD_UUID)\\.tmp$"
    sd-entries $root | where {|path|
        let relative = ($path | path relative-to $root | str replace --all "\\" "/")
        let segments = ($relative | split row "/")
        let basename = ($path | path basename)
        let parent = (sd-relative-parent $root $path)
        let retired_dir = ($segments | any {|segment| $segment == ".nurl-state" })
        let retired_setup = ($basename =~ $setup_pattern)
        let sibling_temp = ($basename =~ $temp_pattern)
        let retired_lock = (
            $expected
            | where {|spec| ($spec.dir | str replace --all "\\" "/") == $parent }
            | any {|spec|
                $spec.basenames | any {|state_name| $basename == $".($state_name).create.lock" }
            }
        )
        $retired_dir or $retired_setup or $sibling_temp or $retired_lock
    }
}

def sd-workspace-destinations [] {
    [
        {dir: "", basenames: ["config.nuon" "variables.nuon" "secrets.nuon"]}
        {dir: "collections/coll", basenames: ["collection.nuon" "meta.nuon"]}
        {dir: "collections/coll/environments", basenames: ["env.nuon" "attempted-env.nuon"]}
        {dir: "collections/coll/requests", basenames: ["request.nuon" "attempted-request.nuon"]}
        {dir: "chains", basenames: ["chain.nuon" "attempted-chain.nuon"]}
    ]
}

def sd-function-source [source: string, name: string, next_name: string] {
    $source | split row $name | get 1 | split row $next_name | first
}

def test-sd-replacement-bytes-and-temp-cleanup [] {
    let tmp = (make-temp-dir "state-bytes")
    sd-finally {
        $env.API_ROOT = $tmp
        api init | ignore
        api config set editor "vim" | ignore
        api vars set greeting "hello" | ignore
        api auth bearer set demo "CREDENTIAL-SENTINEL" | ignore
        api collection create coll | ignore
        api collection env create coll env --activate | ignore
        api request create request GET "http://example.invalid" -c coll | ignore

        for path in [
            ($tmp | path join "config.nuon")
            ($tmp | path join "variables.nuon")
            ($tmp | path join "secrets.nuon")
            ($tmp | path join "collections" "coll" "meta.nuon")
            ($tmp | path join "collections" "coll" "environments" "env.nuon")
            ($tmp | path join "collections" "coll" "requests" "request.nuon")
        ] {
            let raw = (open $path --raw)
            assert (not ($raw | str ends-with "\n")) $"state writer added a newline to ($path)"
            let parsed = ($raw | from nuon)
            let expected = if ($path | str contains "collections") {
                $parsed | to nuon --indent 4
            } else {
                $parsed | to nuon
            }
            assert equal $raw $expected $"state bytes diverged from the caller's single serialization for ($path)"
        }
        assert equal (sd-state-artifacts $tmp (sd-workspace-destinations)) [] "normal replacement left a Nurl state artifact"
    } { cleanup $tmp }
}

def test-sd-staging-failure-preserves-bytes [] {
    let tmp = (make-temp-dir "state-stage-fail")
    sd-finally {
        $env.API_ROOT = $tmp
        api init | ignore
        let path = ($tmp | path join "config.nuon")
        let original = (open $path --raw)
        let state_module = ($env.NURL_REPO_ROOT | path join "nu_modules" "state-store.nu")
        let command = $"use ($state_module | to nuon) [save-state-replace]; let unsupported = \{|| null\}; save-state-replace $unsupported ($path | to nuon)"
        let result = (run-command-process $tmp $command)
        assert ($result.exit_code != 0) "staging failure exited zero"
        assert equal ($result.stdout | str trim) "" "staging failure wrote stdout"
        assert (sd-stderr-has $result.stderr "Could not stage state file") $"staging failure lacked stage identity: ($result.stderr)"
        assert (sd-stderr-has $result.stderr "The previous file was preserved") "pre-publication preservation claim was lost"
        assert (sd-stderr-has $result.stderr $path) "staging failure omitted destination path"
        assert (not ($result.stderr | str contains "after publication")) "staging fixture reached publication reporting"
        assert equal (open $path --raw) $original "staging failure changed prior bytes"
        assert equal (sd-state-artifacts $tmp (sd-workspace-destinations)) [] "staging failure left a temp artifact"

        let state_source = (open $state_module --raw)
        let stage_index = ($state_source | str index-of "Could not stage state file")
        let publish_index = ($state_source | str index-of "commit-state-replace $serialized $temp_path $destination_path")
        assert ($stage_index >= 0 and $publish_index > $stage_index) "stage-attributed failure is not structurally before publication"
        print $"STATE_STAGE_FAILURE=EXECUTED os=($nu.os-info.name) runtime=((version).version) route=stage-error-identity"
    } { cleanup $tmp }
}

def test-sd-partial-new-file-fails-closed [] {
    let tmp = (make-temp-dir "state-partial-create")
    sd-finally {
        $env.API_ROOT = $tmp
        api init | ignore
        let chains = ($tmp | path join "chains")
        mkdir $chains
        let path = ($chains | path join "partial.nuon")
        let new_prefix = "{name: partial, steps: ["
        let partial_destination = (
            bytes build
                ($new_prefix | into binary)
                0x[00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
                   00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
                   00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
                   00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00]
        )
        $partial_destination | save --raw -f $path
        let observed_partial = (open $path --raw | into binary)
        assert ($observed_partial == $partial_destination) "partial-destination fixture bytes drifted"
        let result = (sd-assert-clean-failure $tmp "api chain show partial" "Invalid state file" --unchanged)
        assert (sd-stderr-has $result.stderr $path) "partial-create error omitted path"
        assert (not ($result.stderr | str contains $new_prefix)) "partial-create bytes leaked into stderr"
    } { cleanup $tmp }
}

def test-sd-gate-a-main-parity-create-shape [] {
    let repo = $env.NURL_REPO_ROOT
    let state = (open ($repo | path join "nu_modules" "state-store.nu") --raw)
    assert (not ($state | str contains "no-clobber")) "state-store added a no-clobber synchronization path"
    assert (not ($state | str contains "save-state-if-absent")) "state-store moved main's conditional creates behind a helper"

    let cases = [
        {file: "chain.nu", start: 'export def "api chain create"', stop: 'export def "api chain list"', destination: "$file_path", message: "Chain '($name)' already exists"}
        {file: "mod.nu", start: 'export def "api collection create"', stop: 'export def "api collection delete"', destination: "$collection_file", message: "Collection '($name)' already exists"}
        {file: "mod.nu", start: 'export def "api collection env create"', stop: 'export def "api collection env use"', destination: "$env_path", message: "Environment '($name)' already exists"}
        {file: "http.nu", start: 'export def "api request create"', stop: 'export def "api request list"', destination: "$request_file", message: ""}
    ]
    for case in $cases {
        let source = (open ($repo | path join "nu_modules" $case.file) --raw)
        let segment = (sd-function-source $source $case.start $case.stop)
        let save_line = $"| save ($case.destination)"
        assert equal (sd-message-count $segment $save_line) 1 $"($case.start) must have exactly one direct bare save"
        assert (not ($segment | str contains $"save -f ($case.destination)")) $"($case.start) force-saves its final destination"
        if $case.message != "" {
            assert ($segment | str contains $case.message) $"($case.start) lost main's advisory duplicate message"
        }
        for forbidden in [".tmp" " mv " " cp " "lock" "marker" "sidecar" "owner-token" "retry" "^"] {
            assert (not ($segment | str contains $forbidden)) $"($case.start) contains prohibited create machinery: ($forbidden)"
        }
    }
}

def test-sd-gate-b-sequential-duplicate [] {
    let tmp = (make-temp-dir "state-duplicate")
    sd-finally {
        $env.API_ROOT = $tmp
        api init | ignore
        api chain create duplicate --description original | ignore
        let path = ($tmp | path join "chains" "duplicate.nuon")
        let original = (open $path --raw)
        let result = (run-command-process $tmp "api chain create duplicate --description replacement")
        let message = "Chain 'duplicate' already exists"
        assert ($result.exit_code != 0) "sequential duplicate exited zero"
        assert equal ($result.stdout | str trim) "" "sequential duplicate wrote stdout"
        assert equal (sd-message-count $result.stderr $message) 1 "stable duplicate message did not occur exactly once"
        assert equal $result.stderr ($result.stderr | ansi strip) "duplicate stderr contained ANSI"
        assert equal (open $path --raw) $original "sequential duplicate changed exact prior bytes"
        assert equal (sd-state-artifacts $tmp (sd-workspace-destinations)) [] "sequential duplicate left an artifact"
    } { cleanup $tmp }
}

def test-sd-gate-c-create-race-invariants [] {
    let tmp = (make-temp-dir "state-race")
    sd-finally {
        $env.API_ROOT = $tmp
        api init | ignore
        let worker = ($tmp | path join "race-worker.nu")
        let launcher = ($tmp | path join "race-launcher.py")
        let module = ($env.NURL_REPO_ROOT | path join "nu_modules" "mod.nu")
        [
            $"use ($module | to nuon) *"
            'def main [root: string, name: string, ready: string, go: string, result: string, tag: string] {
    $env.API_ROOT = $root
    "ready" | save -f $ready
    mut waited = 0
    while (not ($go | path exists)) and $waited < 30000 {
        sleep 5ms
        $waited = $waited + 5
    }
    let outcome = try {
        api chain create $name --description $tag | ignore
        {kind: success, tag: $tag, message: ""}
    } catch {|error|
        {kind: duplicate, tag: $tag, message: $error.msg}
    }
    $outcome | to nuon | save -f $result
}'
        ] | str join "\n" | save -f $worker
        'import os
import subprocess
import sys
import time

nu, worker, root, name, prefix, count = sys.argv[1:7]
count = int(count)
go = prefix + "-go"
processes = []
for index in range(count):
    ready = prefix + f"-ready-{index}"
    result = prefix + f"-result-{index}.nuon"
    process = subprocess.Popen(
        [nu, "--no-config-file", worker, root, name, ready, go, result, f"worker-{index}"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    processes.append(process)
deadline = time.time() + 45
while time.time() < deadline:
    if all(os.path.exists(prefix + f"-ready-{index}") for index in range(count)):
        break
    time.sleep(0.01)
else:
    raise SystemExit("workers did not reach barrier")
open(go, "w").close()
for process in processes:
    process.wait(timeout=60)
if any(process.returncode != 0 for process in processes):
    raise SystemExit("worker process failed")
' | save -f $launcher

        let n = 8
        let rounds = 10
        mut winner_counts = []
        for round in 1..$rounds {
            let name = $"race-($round)"
            let prefix = ($tmp | path join $"round-($round)")
            let python = (sd-python)
            let launched = (test-complete-result (^$python $launcher $nu.current-exe $worker $tmp $name $prefix $n | complete))
            assert equal $launched.exit_code 0 $"race launcher failed: ($launched.stderr)"
            let outcomes = (0..<$n | each {|index|
                open $"($prefix)-result-($index).nuon" --raw | from nuon
            })
            let successes = ($outcomes | where kind == success)
            let duplicates = ($outcomes | where kind == duplicate)
            assert (($successes | length) >= 1) $"round ($round) had no successful create"
            assert equal (($successes | length) + ($duplicates | length)) $n $"round ($round) had a third outcome"
            for duplicate in $duplicates {
                assert equal $duplicate.message $"Chain '($name)' already exists" $"round ($round) duplicate message drifted: ($duplicate.message)"
            }
            let final_path = ($tmp | path join "chains" $"($name).nuon")
            let final = (open $final_path --raw | from nuon)
            assert ($final.description in ($outcomes | get tag)) $"round ($round) final file was not one complete contender payload"
            assert equal ($final.steps | length) 2 $"round ($round) final chain was partial"
            $winner_counts = ($winner_counts | append ($successes | length))
            for path in (
                (0..<$n | each {|index| [$"($prefix)-ready-($index)" $"($prefix)-result-($index).nuon"] } | flatten)
                | append [$"($prefix)-go"]
            ) {
                try { rm -f $path } catch {}
            }
        }
        print $"Gate C winner counts \(characterization only\): ($winner_counts | to nuon)"
        assert equal (sd-state-artifacts $tmp (sd-workspace-destinations)) [] "race left a state artifact"
    } { cleanup $tmp }
}

def sd-state-targets [tmp: string] {
    $env.API_ROOT = $tmp
    api init | ignore
    api collection create coll | ignore
    api collection env create coll env --activate | ignore
    api request create request GET "http://example.invalid" -c coll | ignore
    api chain create chain | ignore
    [
        {path: ($tmp | path join "config.nuon"), command: "api config get", shape: "[]"}
        {path: ($tmp | path join "variables.nuon"), command: "api vars list", shape: "[]"}
        {path: ($tmp | path join "secrets.nuon"), command: "api auth list", shape: "[]"}
        {path: ($tmp | path join "collections" "coll" "collection.nuon"), command: "api collection show coll", shape: "[]"}
        {path: ($tmp | path join "collections" "coll" "meta.nuon"), command: "api collection show coll", shape: "[]"}
        {path: ($tmp | path join "collections" "coll" "environments" "env.nuon"), command: "api collection env show coll env", shape: "[]"}
        {path: ($tmp | path join "collections" "coll" "requests" "request.nuon"), command: "api request show request -c coll", shape: "[]"}
        {path: ($tmp | path join "chains" "chain.nuon"), command: "api chain show chain", shape: "42"}
    ]
}

def test-sd-corrupt-state-matrix [] {
    let tmp = (make-temp-dir "state-corrupt")
    sd-finally {
        let targets = (sd-state-targets $tmp)
        for target in $targets {
            sd-with-original-bytes $target.path {
                "{STATE-CONTENT-SENTINEL:" | save -f $target.path
                let result = (sd-assert-clean-failure $tmp $target.command "Invalid state file")
                assert (sd-stderr-has $result.stderr $target.path) "syntax error omitted state path"
            }
            sd-with-original-bytes $target.path {
                $target.shape | save -f $target.path
                let expected = if ($target.command | str contains "chain") { "Invalid chain state" } else { "Invalid state file" }
                sd-assert-clean-failure $tmp $target.command $expected | ignore
            }
            sd-with-original-bytes $target.path {
                (0x[00 01 FE FF 80 81]) | save -f $target.path
                let expected = if ($target.command | str contains "chain") { "Invalid chain state" } else { "Invalid state file" }
                sd-assert-clean-failure $tmp $target.command $expected | ignore
            }
        }

        let config = ($tmp | path join "config.nuon")
        sd-with-original-bytes $config {
            "STATE-CONTENT-SENTINEL [" | save -f $config
            sd-assert-clean-failure $tmp "api history clear" "Invalid state file" | ignore
        }
    } { cleanup $tmp }
}

def test-sd-reader-structure-and-default-boundary [] {
    let source = (open ($env.NURL_REPO_ROOT | path join "nu_modules" "state-store.nu") --raw)
    let strict = (sd-function-source $source "export def open-state-value" "export def open-state-record")
    let raw_index = ($strict | str index-of "open $path --raw")
    let try_index = ($strict | str index-of "let parsed = try")
    assert ($raw_index >= 0 and $try_index > $raw_index) "open --raw is not structurally outside the parse try"
    let default_reader = ($source | split row "export def open-state-record-or-default" | get 1)
    assert (not ($default_reader | str contains "try")) "present-path default reader contains try"
    assert (not ($default_reader | str contains "catch")) "present-path default reader contains catch"
    assert ($default_reader | str contains "open-state-record $path $description") "present path does not directly delegate to strict reader"

    for banned in ['$error.msg' '$e.msg' '.debug' 'FileNotFound' 'File not found' 'debug contains' 'catch { $default_value' 'catch { {} }' 'catch { [] }'] {
        assert (not ($source | str contains $banned)) $"state-store contains banned classifier/default construct: ($banned)"
    }

    let tmp = (make-temp-dir "state-defaults")
    sd-finally {
        $env.API_ROOT = $tmp
        let absent = (api config get)
        assert equal $absent.timeout_seconds 30 "absent config did not return default"
        api init | ignore
        api config set timeout_seconds 17 | ignore
        assert equal (api config get | get timeout_seconds) 17 "present readable config returned default"
    } { cleanup $tmp }
}

def sd-direct-reader-command [path: string] {
    let module = ($env.NURL_REPO_ROOT | path join "nu_modules" "state-store.nu")
    $"use ($module | to nuon) [open-state-record]; open-state-record ($path | to nuon) test | ignore"
}

def test-sd-io-propagation-posix [] {
    if $nu.os-info.name == "windows" {
        error make {msg: "SKIP: POSIX permission fixture"}
    }
    let uid = (^id -u | str trim)
    if $uid == "0" {
        print "STATE_TEST16_POSIX=SKIPPED uid=0"
        error make {msg: "SKIP: POSIX permission fixture requires non-root"}
    }
    let tmp = (make-temp-dir "state-io-posix")
    sd-finally {
        let path = ($tmp | path join "strict.nuon")
        "{value: 1}" | save -f $path
        ^chmod 000 $path
        sd-finally {
            let direct = (run-command-process $tmp $"open ($path | to nuon) --raw | ignore")
            let nurl = (run-command-process $tmp (sd-direct-reader-command $path))
            assert ($direct.exit_code != 0 and $nurl.exit_code != 0) "permission-denied direct/Nurl reads did not both fail"
            assert (not ($nurl.stderr | str contains "Invalid state file")) "genuine I/O was normalized as invalid NUON"
            assert equal ($nurl.stdout | str trim) "" "genuine I/O failure wrote stdout"
            print $"STATE_TEST16_POSIX=EXECUTED uid=($uid)"
        } { ^chmod 600 $path }
    } { cleanup $tmp }
}

def test-sd-io-propagation-windows [] {
    if $nu.os-info.name != "windows" {
        error make {msg: "SKIP: Windows exclusive-lock fixture"}
    }
    let tmp = (make-temp-dir "state-io-windows")
    sd-finally {
        let path = ($tmp | path join "strict.nuon")
        "{value: 1}" | save -f $path
        let lock = (sd-start-windows-lock $tmp $path "None")
        sd-finally {
            let direct = (run-command-process $tmp $"open ($path | to nuon) --raw | ignore")
            let nurl = (run-command-process $tmp (sd-direct-reader-command $path))
            assert ($direct.exit_code != 0 and $nurl.exit_code != 0) "locked direct/Nurl reads did not both fail"
            assert (not ($nurl.stderr | str contains "Invalid state file")) "locked I/O was normalized as invalid NUON"
            print "STATE_TEST16_WINDOWS=EXECUTED"
        } { sd-stop-windows-lock $lock }
    } { cleanup $tmp }
}

def test-sd-or-default-posix [] {
    if $nu.os-info.name == "windows" {
        error make {msg: "SKIP: POSIX permission fixture"}
    }
    let uid = (^id -u | str trim)
    if $uid == "0" {
        print "STATE_TEST17C_POSIX=SKIPPED uid=0"
        error make {msg: "SKIP: POSIX permission fixture requires non-root"}
    }
    let tmp = (make-temp-dir "state-default-posix")
    sd-finally {
        $env.API_ROOT = $tmp
        api init | ignore
        api auth bearer set demo token | ignore
        let secrets = ($tmp | path join "secrets.nuon")
        ^chmod 000 $secrets
        sd-finally {
            let listed = (run-command-process $tmp "api auth list")
            let request = (run-command-process $tmp "api get http://127.0.0.1:1 --dry-run -a {type: bearer, ref: demo}")
            for result in [$listed $request] {
                assert ($result.exit_code != 0) "unreadable present secrets defaulted instead of failing"
                assert equal ($result.stdout | str trim) "" "unreadable secrets produced success stdout"
                assert (not ($result.stderr | str contains "Invalid state file")) "unreadable secrets were normalized as invalid NUON"
            }
            print $"STATE_TEST17C_POSIX=EXECUTED uid=($uid)"
        } { ^chmod 600 $secrets }
    } { cleanup $tmp }
}

def test-sd-or-default-windows [] {
    if $nu.os-info.name != "windows" {
        error make {msg: "SKIP: Windows exclusive-lock fixture"}
    }
    let tmp = (make-temp-dir "state-default-windows")
    sd-finally {
        $env.API_ROOT = $tmp
        api init | ignore
        api auth bearer set demo token | ignore
        let secrets = ($tmp | path join "secrets.nuon")
        let lock = (sd-start-windows-lock $tmp $secrets "None")
        sd-finally {
            let listed = (run-command-process $tmp "api auth list")
            let request = (run-command-process $tmp "api get http://127.0.0.1:1 --dry-run -a {type: bearer, ref: demo}")
            for result in [$listed $request] {
                assert ($result.exit_code != 0) "locked present secrets defaulted instead of failing"
                assert equal ($result.stdout | str trim) "" "locked secrets produced success stdout"
                assert (not ($result.stderr | str contains "Invalid state file")) "locked secrets were normalized as invalid NUON"
            }
            print "STATE_TEST17C_WINDOWS=EXECUTED"
        } { sd-stop-windows-lock $lock }
    } { cleanup $tmp }
}

def test-sd-stale-sibling-policy [] {
    let tmp = (make-temp-dir "state-stale")
    sd-finally {
        $env.API_ROOT = $tmp
        api init | ignore
        api auth bearer set seed seed | ignore
        let fresh = ($tmp | path join $".secrets.nuon.nurl-(random uuid).tmp")
        "fresh" | save -f $fresh
        let unrelated = ($tmp | path join $".config.nuon.nurl-(random uuid).tmp")
        "unrelated" | save -f $unrelated
        sd-age-path $tmp $unrelated
        let malformed = ($tmp | path join ".secrets.nuon.nurl-not-a-canonical-uuid.tmp")
        "malformed" | save -f $malformed
        sd-age-path $tmp $malformed
        let first = (run-command-process $tmp "api auth bearer set fresh fresh-token")
        assert equal $first.exit_code 0 "fresh sibling blocked current write"
        assert equal ($first.stderr | str trim) "" "fresh sibling emitted warning"
        assert equal (open $fresh --raw) "fresh" "fresh sibling changed"
        assert equal (open $unrelated --raw) "unrelated" "different-destination sibling was swept"
        assert equal (open $malformed --raw) "malformed" "malformed sibling name was treated as Nurl-owned"

        let aged = ($tmp | path join $".secrets.nuon.nurl-(random uuid).tmp")
        "aged" | save -f $aged
        sd-age-path $tmp $aged
        let second = (run-command-process $tmp "api auth bearer set aged aged-token")
        assert equal $second.exit_code 0 "aged removable sibling blocked current write"
        assert (not ($aged | path exists)) "aged removable sibling survived"
        assert equal ($second.stderr | str trim) "" "aged removable sibling emitted warning"

        let blocked = ($tmp | path join $".secrets.nuon.nurl-(random uuid).tmp")
        let blocked_lock = if $nu.os-info.name == "windows" {
            "CREDENTIAL-SENTINEL" | save -f $blocked
            sd-age-path $tmp $blocked
            sd-start-windows-lock $tmp $blocked "None"
        } else {
            mkdir $blocked
            "CREDENTIAL-SENTINEL" | save -f ($blocked | path join "keep.txt")
            ^chmod 500 $blocked
            sd-age-path $tmp $blocked
            null
        }
        sd-finally {
            let secrets_path = ($tmp | path join "secrets.nuon")
            let next_secrets = (
                open $secrets_path --raw
                | from nuon
                | upsert tokens.blocked {bearer: committed-token}
                | to nuon
            )
            let state_module = ($env.NURL_REPO_ROOT | path join "nu_modules" "state-store.nu")
            let command = $"use ($state_module | to nuon) [save-state-replace]; save-state-replace ($next_secrets | to nuon) ($secrets_path | to nuon)"
            let third = (run-command-process $tmp $command)
            let warning = $"Stale state temporary file '($blocked)' could not be removed; remove it manually."
            assert equal $third.exit_code 0 "unremovable sibling blocked current write"
            assert equal ($third.stdout | str trim) "" "stale cleanup polluted stdout"
            assert ($blocked | path exists) "unremovable sibling disappeared"
            assert (sd-stderr-has $third.stderr $blocked) "stale removal diagnostic omitted orphan path"
            assert (not ($third.stderr | str contains "CREDENTIAL-SENTINEL")) "cleanup diagnostic leaked orphan content"
            assert (not ($third.stderr | str contains "committed-token")) "cleanup diagnostic leaked new state content"
            if (sd-is-nu-089) {
                assert equal (sd-message-count $third.stderr "Stale state temporary file") 0 "0.89 emitted a duplicate Nurl warning"
                assert equal (sd-message-count $third.stderr "Error:") 1 $"0.89 removal diagnostic count drifted: ($third.stderr)"
                assert (not (sd-stderr-has $third.stderr $"deleted ($blocked)")) "0.89 fallback used verbose removal"
                let ansi_present = $third.stderr != ($third.stderr | ansi strip)
                print $"STATE_STALE_RM_089=EXECUTED os=($nu.os-info.name) ansi_present=($ansi_present)"
            } else {
                assert equal ($third.stderr | str trim) $warning $"structured stale-temp warning was not exact: ($third.stderr)"
                assert equal (sd-message-count $third.stderr $warning) 1 "structured stale-temp warning was not emitted exactly once"
                assert equal $third.stderr ($third.stderr | ansi strip) "structured warning contained ANSI"
                for forbidden in ["Access is denied" "Permission denied" "Directory not empty" "os error"] {
                    assert (not ($third.stderr | str contains $forbidden)) $"structured warning leaked OS detail: ($forbidden)"
                }
                print $"STATE_STALE_STRUCTURED=EXECUTED os=($nu.os-info.name)"
            }
            let secrets = (open $secrets_path --raw | from nuon)
            assert equal ($secrets.tokens.blocked.bearer) "committed-token" "warning path did not commit requested write"
            print $"STATE_STALE_UNREMOVABLE=EXECUTED os=($nu.os-info.name)"
        } {
            if $blocked_lock != null {
                sd-stop-windows-lock $blocked_lock
            } else {
                ^chmod 700 $blocked
            }
        }
        let sentinel_path = if $nu.os-info.name == "windows" { $blocked } else { $blocked | path join "keep.txt" }
        assert equal (open $sentinel_path --raw) "CREDENTIAL-SENTINEL" "unremovable sibling bytes changed"
        api config set timeout_seconds 9 | ignore
        api vars set stale unaffected | ignore
        api collection create coll | ignore
        api collection env create coll env --activate | ignore
        api collection env set coll key value | ignore
    } { cleanup $tmp }
}

def test-sd-lifecycle-scanner-and-self-test [] {
    let tmp = (make-temp-dir "state-lifecycle")
    sd-finally {
        $env.API_ROOT = $tmp
        api init | ignore
        api config set timeout_seconds 11 | ignore
        api vars set key value | ignore
        api auth bearer set demo token | ignore
        api collection create coll | ignore
        api collection env create coll env --activate | ignore
        api request create request GET "http://example.invalid" -c coll | ignore
        api chain create chain | ignore
        assert equal (sd-state-artifacts $tmp (sd-workspace-destinations)) [] "full lifecycle created a retired/generated artifact"

        let instrument = ($tmp | path join "scanner-self-test")
        mkdir ($instrument | path join "chains")
        let exact_lock = ($instrument | path join "chains" ".attempted-chain.nuon.create.lock")
        let unrelated_lock = ($instrument | path join "chains" ".build.create.lock")
        "lock" | save -f $exact_lock
        "control" | save -f $unrelated_lock
        assert (not (($instrument | path join "chains" "attempted-chain.nuon") | path exists)) "scanner self-test destination unexpectedly exists"
        let detected = (sd-state-artifacts $instrument [{dir: "chains", basenames: ["attempted-chain.nuon"]}])
        assert ($exact_lock in $detected) "scanner missed an exact retired lock for an absent enumerated destination"
        assert ($unrelated_lock not-in $detected) "scanner flagged an unenumerated user lock"
        let omitted = (sd-state-artifacts $instrument [{dir: "chains", basenames: []}])
        assert ($exact_lock not-in $omitted) "scanner ignored source-derived basename enumeration"

        for innocent in [
            ($instrument | path join "notes.tmp")
            ($instrument | path join "data.nurl.tmp")
            ($instrument | path join ".secrets.nuon.nurl-------------------------------------.tmp")
            ($instrument | path join ".secrets.nuon.nurl-1234567890abcdef1234567890abcdef1234.tmp")
        ] {
            "innocent" | save -f $innocent
        }
        let controls = (sd-state-artifacts $instrument [{dir: "chains", basenames: []}])
        assert equal $controls [] "scanner's canonical pattern flagged innocent/malformed names"
        print "STATE_SCANNER_PHASE_S=PASS"
    } { cleanup $tmp }
}

def test-sd-collection-copy-does-not-interpret-retired-names [] {
    let tmp = (make-temp-dir "state-copy")
    sd-finally {
        $env.API_ROOT = $tmp
        api init | ignore

        api collection create file-source | ignore
        let file_source = ($tmp | path join "collections" "file-source")
        let inert_file = ($file_source | path join ".nurl-state")
        "inert-file-bytes" | save -f $inert_file
        mkdir ($file_source | path join "nested")
        (0x[00 01 FE FF 80 81]) | save -f ($file_source | path join "nested" "payload.bin")
        "arbitrary-user-bytes" | save -f ($file_source | path join "nested" ".custom")
        let source_before = (sd-snapshot $file_source)
        api collection copy file-source file-target | ignore
        let copied_file = ($tmp | path join "collections" "file-target" ".nurl-state")
        assert equal (open $copied_file --raw) "inert-file-bytes" "copy filtered or changed user-authored .nurl-state file"
        let file_target = ($tmp | path join "collections" "file-target")
        let copied_paths = (sd-snapshot $file_target)
        let unchanged_source = ($source_before | where path != "collection.nuon")
        let unchanged_target = ($copied_paths | where path != "collection.nuon")
        assert equal $unchanged_target $unchanged_source "collection copy diverged from archived main's recursive byte-for-byte copy"
        let source_meta = (open ($file_source | path join "collection.nuon") --raw | from nuon)
        let target_meta = (open ($file_target | path join "collection.nuon") --raw | from nuon)
        assert equal ($target_meta | reject name created_at) ($source_meta | reject name created_at) "collection copy changed metadata beyond main's name/timestamp rewrite"
        assert equal $target_meta.name "file-target" "collection copy did not apply main's target-name rewrite"
        api collection env create file-target env --activate | ignore
        api collection env set file-target key value | ignore
        assert equal (open $copied_file --raw) "inert-file-bytes" "ordinary write interpreted user-authored .nurl-state file"

        api collection create dir-source | ignore
        let dir_source = ($tmp | path join "collections" "dir-source")
        let inert_dir = ($dir_source | path join ".nurl-state")
        mkdir $inert_dir
        "inert-marker-bytes" | save -f ($inert_dir | path join ".secured-v1")
        api collection copy dir-source dir-target | ignore
        let copied_marker = ($tmp | path join "collections" "dir-target" ".nurl-state" ".secured-v1")
        assert equal (open $copied_marker --raw) "inert-marker-bytes" "copy filtered or changed inert .secured-v1 bytes"
        api collection env create dir-target env --activate | ignore
        api collection env set dir-target key value | ignore
        assert equal (open $copied_marker --raw) "inert-marker-bytes" "ordinary write interpreted inert marker bytes"
    } { cleanup $tmp }
}

def test-sd-concurrent-first-initialization [] {
    let tmp = (make-temp-dir "state-first-init")
    sd-finally {
        let worker = ($tmp | path join "init-worker.nu")
        let launcher = ($tmp | path join "init-launcher.py")
        let module = ($env.NURL_REPO_ROOT | path join "nu_modules" "mod.nu")
        [
            $"use ($module | to nuon) *"
            'def main [root: string, ready: string, go: string, result: string] {
    $env.API_ROOT = $root
    "ready" | save -f $ready
    mut waited = 0
    while (not ($go | path exists)) and $waited < 30000 {
        sleep 5ms
        $waited = $waited + 5
    }
    let outcome = try {
        api init | ignore
        {kind: success}
    } catch {|error|
        {kind: failure, message: $error.msg}
    }
    $outcome | to nuon | save -f $result
}'
        ] | str join "\n" | save -f $worker
        'import os
import subprocess
import sys
import time

nu, worker, root, prefix, count = sys.argv[1:6]
count = int(count)
go = prefix + "-go"
processes = []
for index in range(count):
    ready = prefix + f"-ready-{index}"
    result = prefix + f"-result-{index}.nuon"
    processes.append(subprocess.Popen(
        [nu, "--no-config-file", worker, root, ready, go, result],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ))
deadline = time.time() + 45
while time.time() < deadline:
    if all(os.path.exists(prefix + f"-ready-{index}") for index in range(count)):
        break
    time.sleep(0.01)
else:
    raise SystemExit("workers did not reach barrier")
open(go, "w").close()
for process in processes:
    process.wait(timeout=60)
if any(process.returncode != 0 for process in processes):
    raise SystemExit("worker process failed")
' | save -f $launcher

        let n = 8
        let prefix = ($tmp | path join "first-init")
        let python = (sd-python)
        let launched = (test-complete-result (^$python $launcher $nu.current-exe $worker $tmp $prefix $n | complete))
        assert equal $launched.exit_code 0 $"first-init launcher failed: ($launched.stderr)"
        let outcomes = (0..<$n | each {|index| open $"($prefix)-result-($index).nuon" --raw | from nuon })
        assert (($outcomes | where kind == success | length) >= 1) "concurrent first initialization had no success"
        for state_name in ["config.nuon" "variables.nuon" "secrets.nuon"] {
            let state = (open ($tmp | path join $state_name) --raw | from nuon)
            assert equal ($state | describe --detailed | get type) "record" $"concurrent init left partial ($state_name)"
        }
        for directory in ["collections" "history"] {
            assert equal (($tmp | path join $directory) | path type) "dir" $"concurrent init omitted ($directory)"
        }
        assert equal (sd-state-artifacts $tmp (sd-workspace-destinations)) [] "concurrent first initialization left an artifact"
        print $"STATE_CONCURRENT_INIT=PASS successes=(($outcomes | where kind == success | length))"
    } { cleanup $tmp }
}

def test-sd-path-empty-lifecycle [] {
    let tmp = (make-temp-dir "state-path-empty")
    sd-finally {
        let script = ($tmp | path join "lifecycle.nu")
        let module = ($env.NURL_REPO_ROOT | path join "nu_modules" "mod.nu")
        [
            $"use ($module | to nuon) *"
            $"$env.API_ROOT = ($tmp | to nuon)"
            "api init | ignore"
            "api config set timeout_seconds 7 | ignore"
            "api vars set key value | ignore"
            "api auth bearer set demo token | ignore"
            "api collection create coll | ignore"
            "api collection env create coll env --activate | ignore"
            "api request create request GET http://example.invalid -c coll | ignore"
            "api chain create chain | ignore"
            'print "STATE_PATH_EMPTY=PASS"'
        ] | str join "\n" | save -f $script
        let result = (with-env {PATH: "", Path: ""} {
            test-complete-result (^$nu.current-exe --no-config-file $script | complete)
        })
        assert equal $result.exit_code 0 $"PATH-empty lifecycle failed: ($result.stderr)"
        assert ($result.stdout | str contains "STATE_PATH_EMPTY=PASS") "PATH-empty lifecycle did not complete"
        assert equal ($result.stderr | str trim) "" "PATH-empty lifecycle emitted stderr"
    } { cleanup $tmp }
}

def test-sd-posix-symlinked-ancestor-and-mode [] {
    if $nu.os-info.name == "windows" {
        error make {msg: "SKIP: POSIX symlink/mode fixture"}
    }
    let tmp = (make-temp-dir "state-posix-path")
    sd-finally {
        let real_parent = ($tmp | path join "real-parent")
        let leaf = ($real_parent | path join "workspace")
        mkdir $leaf
        let alias = ($tmp | path join "alias-parent")
        let linked = (test-complete-result (^ln -s $real_parent $alias | complete))
        assert equal $linked.exit_code 0 $"could not create ancestor symlink: ($linked.stderr)"
        let via_alias = ($alias | path join "workspace")
        assert equal ($leaf | path type) "dir" "real workspace leaf is not a non-link directory"
        $env.API_ROOT = $via_alias
        api init | ignore
        let config = ($leaf | path join "config.nuon")
        ^chmod 640 $config
        api config set timeout_seconds 41 | ignore
        assert equal (open $config --raw | from nuon | get timeout_seconds) 41 "write through symlinked ancestor missed real leaf"
        let mode = (^stat -c "%a" $config | str trim)
        assert equal $mode "640" "replacement did not preserve POSIX mode bits"
        let live_temp = ($leaf | path join $".config.nuon.nurl-(random uuid).tmp")
        cp $config $live_temp
        "{timeout_seconds: 42}" | save -f $live_temp
        let temp_mode = (^stat -c "%a" $live_temp | str trim)
        assert equal $temp_mode $mode "live sibling temp mode diverged from destination mode"
        rm -f $live_temp
        print $"STATE_POSIX_MODE=($mode) live_temp_mode=($temp_mode)"
    } { cleanup $tmp }
}

def test-sd-windows-inherited-state-acl [] {
    if $nu.os-info.name != "windows" {
        error make {msg: "SKIP: Windows inherited ACL fixture"}
    }
    let tmp = (make-temp-dir "state-windows-acl")
    sd-finally {
        $env.API_ROOT = $tmp
        api init | ignore
        api config set timeout_seconds 51 | ignore
        let destination = ($tmp | path join "config.nuon")
        let live_temp = ($tmp | path join $".config.nuon.nurl-(random uuid).tmp")
        "{timeout_seconds: 52}" | save -f $live_temp
        let script = ($tmp | path join "acl-evidence.ps1")
        'param($Destination, $LiveTemp)
$ErrorActionPreference = "Stop"
$env:PSModulePath = "$env:ProgramFiles\WindowsPowerShell\Modules;$PSHOME\Modules"
Import-Module Microsoft.PowerShell.Security -ErrorAction Stop
function AccessSet($Path) {
    @((Get-Acl -LiteralPath $Path -ErrorAction Stop).Access | ForEach-Object {
        "$($_.IdentityReference.Value)|$([int]$_.FileSystemRights)|$($_.AccessControlType)|$($_.IsInherited)"
    } | Sort-Object)
}
$destinationSet = @(AccessSet $Destination)
$liveTempSet = @(AccessSet $LiveTemp)
[pscustomobject]@{
    destination = $destinationSet
    live_temp = $liveTempSet
} | ConvertTo-Json -Compress
' | save -f $script
        let result = (test-complete-result (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script $destination $live_temp | complete))
        assert equal $result.exit_code 0 $"ACL evidence failed: ($result.stderr)"
        assert equal ($result.stderr | str trim) "" $"ACL evidence emitted stderr: ($result.stderr)"
        let evidence = ($result.stdout | from json)
        assert equal $evidence.live_temp $evidence.destination "live sibling temp and published state effective ACE sets diverged"
        assert (($evidence.destination | length) > 0) "ACL evidence returned no effective ACEs"
        assert ($evidence.destination | all {|ace| $ace | str ends-with "|True" }) "published state retained an explicit per-file ACE"
        rm -f $script $live_temp
        print $"STATE_WINDOWS_ACL=EXECUTED ace_count=(($evidence.destination | length))"
    } { cleanup $tmp }
}

def test-sd-windows-alias-paths [] {
    if $nu.os-info.name != "windows" {
        error make {msg: "SKIP: Windows case/8.3 alias fixture"}
    }
    let tmp = (make-temp-dir "state-win-alias")
    sd-finally {
        let long_name = "a-reasonably-long-workspace-directory-name"
        let workspace = ($tmp | path join $long_name)
        mkdir $workspace
        $env.API_ROOT = ($workspace | ascii-upcase)
        api init | ignore
        api config set timeout_seconds 31 | ignore
        assert equal (open ($workspace | path join "config.nuon") --raw | from nuon | get timeout_seconds) 31 "case alias did not resolve to destination"

        let script = ($tmp | path join "short-name.ps1")
        'param($Parent, $Name)
$line = cmd.exe /d /c "dir /x `"$Parent`"" | Where-Object { $_ -match "<DIR>" -and $_.TrimEnd().EndsWith($Name) } | Select-Object -First 1
if ($line) {
    $tokens = $line -split "\s+" | Where-Object { $_ }
    $index = [Array]::IndexOf($tokens, "<DIR>")
    if ($index -ge 0 -and $index + 1 -lt $tokens.Length) { [Console]::Out.Write($tokens[$index + 1]) }
}
' | save -f $script
        let found = (test-complete-result (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script $tmp $long_name | complete))
        rm -f $script
        assert equal $found.exit_code 0 $"8.3 lookup failed: ($found.stderr)"
        let short = ($found.stdout | str trim)
        if ($short | str contains "~") {
            $env.API_ROOT = ($tmp | path join $short)
            api config set timeout_seconds 32 | ignore
            assert equal (open ($workspace | path join "config.nuon") --raw | from nuon | get timeout_seconds) 32 "8.3 alias did not resolve to destination"
            print $"STATE_WINDOWS_8DOT3=EXECUTED alias=($short)"
        } else {
            print "STATE_WINDOWS_8DOT3=SKIPPED unavailable"
        }
    } { cleanup $tmp }
}

def test-sd-chain-list-table-compatibility [] {
    let tmp = (make-temp-dir "state-chain-shapes")
    sd-finally {
        $env.API_ROOT = $tmp
        api init | ignore
        api config set timeout_seconds 1 | ignore
        let chains = ($tmp | path join "chains")
        mkdir $chains
        let homogeneous = [{method: GET, url: "http://127.0.0.1:1"} {method: GET, url: "http://127.0.0.1:1"}]
        let heterogeneous = [{method: GET, url: "http://127.0.0.1:1"} {method: GET, url: "http://127.0.0.1:1", headers: {X: y}}]
        $homogeneous | to nuon | save -f ($chains | path join "homogeneous.nuon")
        $heterogeneous | to nuon | save -f ($chains | path join "heterogeneous.nuon")
        [] | to nuon | save -f ($chains | path join "empty.nuon")
        {name: record, steps: []} | to nuon | save -f ($chains | path join "record.nuon")

        assert equal (api chain show homogeneous | length) 2 "homogeneous list show failed"
        assert equal (api chain show heterogeneous | length) 2 "heterogeneous list show failed"
        assert equal (api chain show empty | length) 0 "empty list show failed"
        assert equal (api chain show record | get name) "record" "record show failed"
        let listed = (api chain list)
        assert equal ($listed | where name == homogeneous | first | get steps) 2 "homogeneous step count failed"
        assert equal ($listed | where name == heterogeneous | first | get steps) 2 "heterogeneous step count failed"
        assert equal ($listed | where name == empty | first | get steps) 0 "empty step count failed"
        assert equal ($listed | where name == record | first | get steps) 0 "record step count failed"

        let named = (run-command-process $tmp "api chain exec homogeneous --quiet | ignore")
        assert equal $named.exit_code 0 $"named populated-list exec rejected chain shape: ($named.stderr)"
        let explicit = (($chains | path join "heterogeneous.nuon") | str replace --all "\\" "/")
        let explicit_result = (run-command-process $tmp $"api chain exec ($explicit | to nuon) --quiet | ignore")
        assert equal $explicit_result.exit_code 0 $"explicit-path populated-list exec rejected chain shape: ($explicit_result.stderr)"
        let show_path = (run-command-process $tmp $"api chain show ($explicit | to nuon)")
        assert ($show_path.exit_code != 0) "api chain show unexpectedly accepted explicit path"
    } { cleanup $tmp }
}

def test-sd-family-a-contract-and-inventory [] {
    let state_path = ($env.NURL_REPO_ROOT | path join "nu_modules" "state-store.nu")
    let state = (open $state_path --raw)
    let contract_source = (sd-function-source $state "export def state-persistence-contract" "export def verify-state-publication")
    for os in ["windows" "linux"] {
        for runtime in ["0.89.0" "0.114.1"] {
            assert equal (state-persistence-contract) "best-effort" $"contract drifted for ($os)/($runtime)"
        }
    }
    assert (not ($contract_source | str contains "if ")) "persistence contract contains an OS/runtime branch"
    assert (not (($contract_source | ascii-upcase) | str contains "ATOMIC")) "persistence contract advertises atomicity"
    assert (not (($contract_source | ascii-upcase) | str contains "DURABLE REPLACEMENT")) "persistence contract advertises durable replacement"

    let modules = (
        ls ($env.NURL_REPO_ROOT | path join "nu_modules")
        | where {|entry| $entry.type == "file" and ($entry.name | str ends-with ".nu") }
        | get name
    )
    let publication_sites = (
        $modules
        | each {|file|
            open $file --raw
            | lines
            | enumerate
            | where {|row|
                (($row.item | str contains "save -f ") or ($row.item | str contains "mv -f ") or ($row.item | str contains ".nurl-"))
            }
            | each {|row|
                {
                    file: ($file | path basename)
                    line: ($row.index + 1)
                    text: ($row.item | str trim)
                }
            }
        }
        | flatten
    )
    let allowed_sites = [
        {file: "state-store.nu", text: '$serialized | save -f $temp_path', class: "shared replacement staging", rationale: "shared contract"}
        {file: "state-store.nu", text: 'do -i { mv -f $temp_path $destination }', class: "shared replacement publication", rationale: "shared contract"}
        {file: "state-store.nu", text: 'try { mv -f $temp_path $destination } catch {}', class: "shared replacement publication", rationale: "shared contract"}
        {file: "state-store.nu", text: ('let prefix = ' + (char --integer 36) + '".($destination | path basename).nurl-"'), class: "shared stale-temp cleanup", rationale: "shared contract"}
        {file: "state-store.nu", text: ('| path join ' + (char --integer 36) + '".($destination_path | path basename).nurl-(random uuid).tmp"'), class: "shared replacement staging", rationale: "shared contract"}
        {file: "http.nu", text: '$body_value | save -f $path', class: "downloaded response bodies", rationale: "declared exclusion: caller-selected decoded output remains outside the state replacement batch"}
        {file: "http.nu", text: '$result._raw_body | save -f $path', class: "downloaded response bodies", rationale: "declared exclusion: caller-selected decoded output remains outside the state replacement batch"}
        {file: "history.nu", text: '$updated | to nuon | save -f $path', class: "history/index", rationale: "declared exclusion: history entry/index persistence remains outside this batch"}
        {file: "history.nu", text: '$entries | to nuon | save -f $path', class: "history/index", rationale: "declared exclusion: history entry/index persistence remains outside this batch"}
        {file: "history.nu", text: '$remaining | to nuon | save -f (get-history-index-path)', class: "history/index", rationale: "declared exclusion: history entry/index persistence remains outside this batch"}
        {file: "history.nu", text: '$snapshot.raw | save -f $snapshot.path', class: "history/index", rationale: "declared exclusion: history recovery remains outside this batch"}
    ]
    for site in $publication_sites {
        assert (
            $allowed_sites | any {|allowed| $allowed.file == $site.file and $allowed.text == $site.text }
        ) $"unlisted persistence publication site: ($site.file):($site.line): ($site.text)"
    }
    for allowed in $allowed_sites {
        assert (
            $publication_sites | any {|site| $site.file == $allowed.file and $site.text == $allowed.text }
        ) $"declared persistence site disappeared without inventory update: ($allowed.file): ($allowed.text)"
        assert (not ($allowed.rationale | is-empty)) $"inventory rationale missing for ($allowed.class)"
    }

    let classes = [
        {class: "configuration", file: "mod.nu", token: 'save-state-replace ($config | to nuon)'}
        {class: "variables", file: "vars.nu", token: "save-state-replace"}
        {class: "secrets", file: "auth.nu", token: "save-state-replace"}
        {class: "collections", file: "mod.nu", token: 'save-state-replace ($meta | to nuon --indent 4)'}
        {class: "requests", file: "http.nu", token: 'save-state-replace ($req | to nuon --indent 4)'}
        {class: "environments", file: "mod.nu", token: 'save-state-replace ($env_data | to nuon --indent 4)'}
        {class: "chains", file: "chain.nu", token: '$serialized | save $file_path'}
        {class: "history/index", file: "history.nu", token: "declared exclusion"}
        {class: "downloaded response bodies", file: "http.nu", token: "commit-state-replace $intended $attempt_path $destination_path"}
    ]
    for class in $classes {
        if $class.token == "declared exclusion" {
            assert ($allowed_sites | any {|site| $site.class == "history/index" and ($site.rationale | str starts-with "declared exclusion:") }) "history/index exclusion is not declared with rationale"
        } else {
            let source = (open ($env.NURL_REPO_ROOT | path join "nu_modules" $class.file) --raw)
            assert ($source | str contains $class.token) $"persistence class inventory missing ($class.class)"
        }
    }
    let binary_commit = (open ($env.NURL_REPO_ROOT | path join "nu_modules" "http.nu") --raw)
    assert ($binary_commit | str contains "state-replacement-temp-path $expanded") "binary response staging bypasses shared stale-temp preparation"
    assert ($binary_commit | str contains "commit-state-replace $intended $attempt_path $destination_path") "binary response publication bypasses shared contract"
    assert (not ($binary_commit | str contains "mv -f $attempt_path $destination_path")) "binary response retains a direct publication bypass"
    print "STATE_FAMILY_A_CONTRACT=best-effort"
    print "STATE_PERSISTENCE_INVENTORY=PASS classes=9"
}

def test-sd-final-state-detector-outcomes [] {
    let tmp = (make-temp-dir "state-detector")
    sd-finally {
        let absent_destination = ($tmp | path join "absent.nuon")
        let absent_temp = ($tmp | path join ".absent.nuon.nurl-00000000-0000-0000-0000-000000000001.tmp")
        let absent_intended = "{value: intended}"
        $absent_intended | save $absent_temp
        let absent = (run-command-process $tmp (sd-state-commit-command $absent_temp $absent_destination))
        assert equal $absent.exit_code 0 "A5 absent-destination publication failed"
        assert equal ($absent.stdout | str trim) "" "A5 wrote stdout"
        assert equal ($absent.stderr | str trim) "" $"A5 wrote stderr: ($absent.stderr)"
        assert (not ($absent_temp | path exists)) "A5 source temp was retained"
        assert equal (open $absent_destination --raw) $absent_intended "A5 destination bytes differ from intended"

        let partial_destination = ($tmp | path join "partial.nuon")
        let partial_temp = ($tmp | path join ".partial.nuon.nurl-00000000-0000-0000-0000-000000000002.tmp")
        let partial_intended = (0x[41 42 43 44 45 46 47 48])
        $partial_intended | save --raw $partial_temp
        (0x[41 42 43 44 00 00 00 00]) | save --raw $partial_destination
        let partial = (run-command-process $tmp (sd-state-verify-command $partial_intended $partial_temp $partial_destination))
        assert ($partial.exit_code != 0) "A3 pre-sized mismatch exited zero"
        assert equal ($partial.stdout | str trim) "" "A3 mismatch wrote stdout"
        assert (sd-stderr-has $partial.stderr "does not match the intended bytes after publication") $"A3 mismatch message drifted: ($partial.stderr)"
        assert (sd-stderr-has $partial.stderr $"Temporary file retained at '($partial_temp)'") "A3 omitted retained-temp cleanup state"
        assert ($partial_temp | path exists) "A3 removed the retained temp"
        assert ((open $partial_destination --raw | into binary) == 0x[41 42 43 44 00 00 00 00]) "A3 destination observation drifted"
        sd-assert-no-publication-claim $partial.stderr

        let raced_destination = ($tmp | path join "external-writer.nuon")
        let raced_temp = ($tmp | path join ".external-writer.nuon.nurl-00000000-0000-0000-0000-000000000003.tmp")
        "intended" | save $raced_temp
        "external-writer" | save $raced_destination
        let raced = (run-command-process $tmp (sd-state-verify-command "intended" $raced_temp $raced_destination))
        assert ($raced.exit_code != 0) "A7 external-writer mismatch exited zero"
        assert equal ($raced.stdout | str trim) "" "A7 wrote stdout"
        assert (sd-stderr-has $raced.stderr "does not match the intended bytes after publication") "A7 mismatch was not reported"
        assert ($raced_temp | path exists) "A7 removed the retained temp"
        assert equal (open $raced_destination --raw) "external-writer" "A7 destination observation drifted"
        sd-assert-no-publication-claim $raced.stderr

        let io_destination = ($tmp | path join "verification-io.nuon")
        let io_temp = ($tmp | path join ".verification-io.nuon.nurl-00000000-0000-0000-0000-000000000004.tmp")
        "intended" | save $io_temp
        "intended" | save $io_destination
        let io_result = if $nu.os-info.name == "windows" {
            let lock = (sd-start-windows-lock $tmp $io_destination "None")
            let result = (run-command-process $tmp (sd-state-verify-command "intended" $io_temp $io_destination))
            sd-stop-windows-lock $lock
            $result
        } else {
            ^chmod 000 $io_destination
            let result = (run-command-process $tmp (sd-state-verify-command "intended" $io_temp $io_destination))
            ^chmod 600 $io_destination
            $result
        }
        assert ($io_result.exit_code != 0) "A6 verification-read I/O failure exited zero"
        assert equal ($io_result.stdout | str trim) "" "A6 verification-read I/O failure wrote stdout"
        assert (not ($io_result.stderr | str trim | is-empty)) "A6 verification-read I/O failure omitted stderr"
        if (sd-is-nu-089) {
            assert (sd-stderr-has $io_result.stderr "Permission denied") $"A6 Nu 0.89 verification-read I/O status drifted: ($io_result.stderr)"
            let os_status = if $nu.os-info.name == "windows" { "os error 32" } else { "os error 13" }
            assert (sd-stderr-has $io_result.stderr $os_status) $"A6 Nu 0.89 OS status drifted: ($io_result.stderr)"
        } else {
            assert ($io_result.stderr | str contains ($io_destination | path basename)) "A6 verification-read I/O failure omitted the destination path"
        }
        assert (not ($io_result.stderr | str contains "does not match the intended bytes")) "A6 I/O failure was relabeled as a mismatch"
        assert (not (($io_result.stderr | ascii-upcase) | str contains "CORRUPT")) "A6 I/O failure was relabeled as corruption"
        assert ($io_temp | path exists) "A6 removed the source temp"
        assert equal (open $io_destination --raw) "intended" "A6 destination observation drifted after unlock"
        sd-assert-no-publication-claim $io_result.stderr
        print $"STATE_FINAL_DETECTOR=EXECUTED os=($nu.os-info.name) runtime=((version).version)"
    } { cleanup $tmp }
}

def test-sd-windows-native-fallback-characterization [] {
    if $nu.os-info.name != "windows" {
        error make {msg: "SKIP: Windows native fallback fixtures"}
    }
    let tmp = (make-temp-dir "state-windows-fallback")
    sd-finally {
        let legacy = (sd-is-nu-089)
        let large_size = (8 * 1024 * 1024)
        let intended_large = ("" | fill --character "N" --width $large_size)
        let old_large = ("" | fill --character "O" --width $large_size)

        # A1: source delete-share denial.
        let a1_destination = ($tmp | path join "a1.nuon")
        let a1_temp = ($tmp | path join ".a1.nuon.nurl-00000000-0000-0000-0000-000000000101.tmp")
        let a1_intended = "A1-NEW-BYTES"
        let a1_old = "A1-OLD-BYTES"
        $a1_intended | save $a1_temp
        $a1_old | save $a1_destination
        let a1_holder = (sd-start-windows-file-holder $tmp $a1_temp "Read" "ReadWrite")
        let a1 = (run-command-process $tmp (sd-state-commit-caught-command $a1_temp $a1_destination))
        sd-stop-windows-lock $a1_holder
        assert equal ($a1.stdout | str trim) "" "A1 wrote stdout"
        if $legacy {
            assert equal $a1.exit_code 0 "A1 Nu 0.89 process exit drifted"
            assert (sd-stderr-has $a1.stderr "os error 32") $"A1 Nu 0.89 omitted native sharing status: ($a1.stderr)"
            assert (not ($a1.stderr | str contains "STATE_PUBLICATION_CAUGHT:")) "A1 Nu 0.89 reported Nurl failure despite matching final bytes"
            assert ($a1_temp | path exists) "A1 Nu 0.89 source temp was not retained"
            assert equal (open $a1_destination --raw) $a1_intended "A1 Nu 0.89 destination observation drifted"
        } else {
            assert ($a1.exit_code != 0) "A1 current runtime exited zero"
            assert (sd-stderr-has $a1.stderr "STATE_PUBLICATION_CAUGHT: State file") $"A1 current runtime error was not caught from Nushell: ($a1.stderr)"
            assert (sd-stderr-has $a1.stderr "does not match the intended bytes after publication") "A1 current runtime omitted the final-byte mismatch"
            assert ($a1_temp | path exists) "A1 current runtime source temp was not retained"
            assert equal (open $a1_destination --raw) $a1_old "A1 current runtime destination observation drifted"
        }
        sd-assert-no-publication-claim $a1.stderr

        # A2/A2b: destination delete-share denial plus an observational reader.
        let a2_destination = ($tmp | path join "a2.nuon")
        let a2_temp = ($tmp | path join ".a2.nuon.nurl-00000000-0000-0000-0000-000000000102.tmp")
        $intended_large | save $a2_temp
        $old_large | save $a2_destination
        let a2_holder = (sd-start-windows-file-holder $tmp $a2_destination "Read" "ReadWrite")
        let a2_monitor = (sd-start-windows-reader-monitor $tmp $a2_destination 79 78)
        let a2 = (run-command-process $tmp (sd-state-commit-caught-command $a2_temp $a2_destination))
        let a2_observation = (sd-stop-windows-reader-monitor $a2_monitor)
        sd-stop-windows-lock $a2_holder
        assert ($a2_observation in ["torn-observed" "not-observed"]) "A2b reader returned an invalid observation"
        assert equal ($a2.stdout | str trim) "" "A2 wrote stdout"
        if $legacy {
            assert equal $a2.exit_code 0 "A2 Nu 0.89 process exit drifted"
            assert equal ($a2.stderr | str trim) "" $"A2 Nu 0.89 stderr was not empty: ($a2.stderr)"
            assert (not ($a2_temp | path exists)) "A2 Nu 0.89 source temp was retained"
            assert equal (open $a2_destination --raw) $intended_large "A2 Nu 0.89 destination observation drifted"
        } else {
            assert ($a2.exit_code != 0) "A2 current runtime exited zero"
            assert (sd-stderr-has $a2.stderr "STATE_PUBLICATION_CAUGHT: State file") $"A2 current runtime error was not caught from Nushell: ($a2.stderr)"
            assert (sd-stderr-has $a2.stderr "does not match the intended bytes after publication") "A2 current runtime omitted the final-byte mismatch"
            assert ($a2_temp | path exists) "A2 current runtime source temp was not retained"
            assert equal (open $a2_destination --raw) $old_large "A2 current runtime destination observation drifted"
        }
        sd-assert-no-publication-claim $a2.stderr
        print $"STATE_FB_WINDOWS_A2B=OBSERVED result=($a2_observation) runtime=((version).version)"

        # A3-source: destination delete denial reaches fallback while the source range is locked.
        let a3s_destination = ($tmp | path join "a3-source.nuon")
        let a3s_temp = ($tmp | path join ".a3-source.nuon.nurl-00000000-0000-0000-0000-000000000103.tmp")
        if $legacy {
            let a3s_size = (512 * 1024 * 1024)
            let a3s_lock_offset = (128 * 1024 * 1024)
            sd-write-windows-byte-file $tmp $a3s_temp 165 $a3s_size
            sd-write-windows-byte-file $tmp $a3s_destination 80 (4 * 1024 * 1024)
            let a3s_source_holder = (sd-start-windows-file-holder $tmp $a3s_temp "ReadWrite" "ReadWrite,Delete" $a3s_lock_offset 1)
            let a3s_destination_holder = (sd-start-windows-file-holder $tmp $a3s_destination "Read" "ReadWrite")
            let a3s_native = (run-command-process $tmp $"mv -f ($a3s_temp | to nuon) ($a3s_destination | to nuon)")
            sd-stop-windows-lock $a3s_destination_holder
            sd-stop-windows-lock $a3s_source_holder
            let a3s_detector = (run-command-process $tmp (sd-state-verify-from-file-command $a3s_temp $a3s_temp $a3s_destination))
            assert equal $a3s_native.exit_code 0 "A3-source Nu 0.89 native process exit drifted"
            assert equal ($a3s_native.stdout | str trim) "" "A3-source Nu 0.89 native command wrote stdout"
            assert (sd-stderr-has $a3s_native.stderr "os error 33") $"A3-source Nu 0.89 omitted the byte-lock status: ($a3s_native.stderr)"
            assert ($a3s_detector.exit_code != 0) "A3-source Nu 0.89 detector exited zero"
            assert equal ($a3s_detector.stdout | str trim) "" "A3-source Nu 0.89 detector wrote stdout"
            assert (sd-stderr-has $a3s_detector.stderr "does not match the intended bytes after publication") "A3-source Nu 0.89 detector omitted the final-byte mismatch"
            assert ($a3s_temp | path exists) "A3-source Nu 0.89 source temp was not retained"
            let a3s_samples = (sd-sample-windows-file $tmp $a3s_destination [0 ($a3s_lock_offset - 1) $a3s_lock_offset (256 * 1024 * 1024) ($a3s_size - 1)])
            assert equal $a3s_samples.length $a3s_size "A3-source Nu 0.89 destination length drifted"
            assert equal $a3s_samples.samples [165 165 0 0 0] $"A3-source Nu 0.89 partial destination observation drifted: ($a3s_samples | to nuon)"
            sd-assert-no-publication-claim $"($a3s_native.stderr)\n($a3s_detector.stderr)"
        } else {
            let a3s_old = ("" | fill --character "O" --width (1024 * 1024))
            let a3s_lock_offset = (4 * 1024 * 1024)
            let a3s_expected = ($tmp | path join "a3-source-expected.nuon")
            $intended_large | save $a3s_temp
            $intended_large | save $a3s_expected
            $a3s_old | save $a3s_destination
            let a3s_source_holder = (sd-start-windows-file-holder $tmp $a3s_temp "ReadWrite" "ReadWrite,Delete" $a3s_lock_offset 1)
            let a3s_destination_holder = (sd-start-windows-file-holder $tmp $a3s_destination "Read" "ReadWrite")
            let a3s = (run-command-process $tmp (sd-state-commit-caught-command $a3s_temp $a3s_destination $a3s_expected))
            sd-stop-windows-lock $a3s_destination_holder
            sd-stop-windows-lock $a3s_source_holder
            assert ($a3s.exit_code != 0) "A3-source current runtime exited zero"
            assert equal ($a3s.stdout | str trim) "" "A3-source current runtime wrote stdout"
            assert (sd-stderr-has $a3s.stderr "STATE_PUBLICATION_CAUGHT: State file") $"A3-source current runtime error was not caught from Nushell: ($a3s.stderr)"
            assert (sd-stderr-has $a3s.stderr "does not match the intended bytes after publication") "A3-source current runtime omitted the final-byte mismatch"
            assert ($a3s_temp | path exists) "A3-source current runtime source temp was not retained"
            assert equal (open $a3s_destination --raw) $a3s_old "A3-source current runtime destination observation drifted"
            sd-assert-no-publication-claim $a3s.stderr
        }

        # A3-destination: a locked destination range independently exercises the second R3 lock.
        let a3d_destination = ($tmp | path join "a3-destination.nuon")
        let a3d_temp = ($tmp | path join ".a3-destination.nuon.nurl-00000000-0000-0000-0000-000000000104.tmp")
        let lock_offset = (4 * 1024 * 1024)
        $intended_large | save $a3d_temp
        $old_large | save $a3d_destination
        let a3d_holder = (sd-start-windows-file-holder $tmp $a3d_destination "ReadWrite" "ReadWrite" $lock_offset 1)
        let a3d = (run-command-process $tmp (sd-state-commit-caught-command $a3d_temp $a3d_destination))
        sd-stop-windows-lock $a3d_holder
        assert ($a3d.exit_code != 0) "A3-destination exited zero"
        assert equal ($a3d.stdout | str trim) "" "A3-destination wrote stdout"
        assert (sd-stderr-has $a3d.stderr "STATE_PUBLICATION_CAUGHT: I/O error") $"A3-destination verification I/O error was not caught from Nushell: ($a3d.stderr)"
        assert (not ($a3d.stderr | str contains "does not match the intended bytes after publication")) "A3-destination relabeled verification I/O as a mismatch"
        assert ($a3d_temp | path exists) "A3-destination source temp was not retained"
        let a3d_observed = (open $a3d_destination --raw)
        if $legacy {
            assert (sd-stderr-has $a3d.stderr "os error 33") $"A3-destination Nu 0.89 omitted the byte-lock status: ($a3d.stderr)"
            let a3d_samples = (sd-sample-windows-file $tmp $a3d_destination [0 ($lock_offset - 1) $lock_offset ($large_size - 1)])
            assert equal $a3d_samples.length $large_size "A3-destination Nu 0.89 destination length drifted"
            assert equal $a3d_samples.samples [78 78 0 0] $"A3-destination Nu 0.89 partial destination observation drifted: ($a3d_samples | to nuon)"
        } else {
            assert equal $a3d_observed $old_large "A3-destination current runtime destination observation drifted"
        }
        sd-assert-no-publication-claim $a3d.stderr

        # A4 is fixture-specific and paired with the destructive A4-POSIX counterexample.
        let a4_destination = ($tmp | path join "a4.nuon")
        let a4_temp = ($tmp | path join ".a4.nuon.nurl-00000000-0000-0000-0000-000000000105.tmp")
        let a4_intended = "A4-NEW-BYTES"
        let a4_old = "A4-OLD-BYTES"
        $a4_intended | save $a4_temp
        $a4_old | save $a4_destination
        let a4_holder = (sd-start-windows-file-holder $tmp $a4_destination "Read" "Read")
        let a4 = (run-command-process $tmp (sd-state-commit-caught-command $a4_temp $a4_destination))
        sd-stop-windows-lock $a4_holder
        assert ($a4.exit_code != 0) "A4 Windows fixture exited zero"
        assert equal ($a4.stdout | str trim) "" "A4 Windows fixture wrote stdout"
        assert (sd-stderr-has $a4.stderr "STATE_PUBLICATION_CAUGHT: State file") $"A4 Windows fixture error was not caught from Nushell: ($a4.stderr)"
        assert (sd-stderr-has $a4.stderr "does not match the intended bytes after publication") "A4 Windows fixture omitted the final-byte mismatch"
        if $legacy {
            assert (sd-stderr-has $a4.stderr "os error 32") $"A4 Nu 0.89 omitted native sharing status: ($a4.stderr)"
        }
        assert ($a4_temp | path exists) "A4 Windows fixture source temp was not retained"
        assert equal (open $a4_destination --raw) $a4_old "A4 fixture-specific Windows destination observation drifted"
        sd-assert-no-publication-claim $a4.stderr

        assert equal (state-persistence-contract) "best-effort" "Windows fallback risk contract is inactive"
        print $"STATE_FB_WINDOWS=EXECUTED runtime=((version).version) fixtures=A1,A2,A2b,A3-source,A3-destination,A4 paired=A4-POSIX-destructive-counterexample"
    } { cleanup $tmp }
}

def test-sd-posix-native-fallback-counterfixtures [] {
    if $nu.os-info.name == "windows" {
        error make {msg: "SKIP: POSIX native fallback fixtures"}
    }
    if not (sd-is-nu-089) {
        error make {msg: "SKIP: POSIX destructive counterfixture is pinned to Nu 0.89"}
    }
    let uid = (^id -u | str trim)
    let gid = (^id -g | str trim)
    if $uid == "0" {
        error make {msg: "SKIP: POSIX destructive counterfixture requires non-root"}
    }
    let sudo_check = (test-complete-result (^sudo -n true | complete))
    if $sudo_check.exit_code != 0 {
        error make {msg: "SKIP: POSIX destructive counterfixture requires passwordless sudo setup"}
    }
    let tmp = (make-temp-dir "state-posix-fallback")
    sd-finally {
        let sticky = ($tmp | path join "sticky")
        mkdir $sticky
        ^sudo -n chown root:root $sticky
        ^sudo -n chmod 1777 $sticky
        let source = ($sticky | path join "source.nuon")
        let destination = ($sticky | path join "destination.nuon")
        "NEW-BYTES" | save $source
        "OLD-BYTES" | save $destination
        ^chmod 0644 $source
        ^sudo -n chown root:root $destination
        ^sudo -n chmod 0666 $destination
        assert equal (^stat -c "%a:%u:%g" $sticky | str trim) "1777:0:0" "A4-POSIX/R4 fixture is not a root-owned sticky directory"
        assert equal (^stat -c "%a:%u:%g" $source | str trim) $"644:($uid):($gid)" "A4-POSIX/R4 source ownership or mode drifted"
        assert equal (^stat -c "%a:%u:%g" $destination | str trim) "666:0:0" "A4-POSIX/R4 destination ownership or mode drifted"
        let result = (run-command-process $tmp $"mv -f ($source | to nuon) ($destination | to nuon)")
        assert equal $result.exit_code 0 "A4-POSIX/R4 Nu 0.89 exit drifted"
        assert equal ($result.stdout | str trim) "" "A4-POSIX/R4 wrote stdout"
        assert ($result.stderr | str contains "Operation not permitted") $"A4-POSIX/R4 omitted native failure: ($result.stderr)"
        assert (sd-stderr-has $result.stderr "os error 1") $"A4-POSIX/R4 omitted native OS status: ($result.stderr)"
        assert ($source | path exists) "A4-POSIX/R4 source was not retained"
        assert equal (open $source --raw) "NEW-BYTES" "A4-POSIX/R4 source bytes changed"
        assert equal (open $destination --raw) "" "A4-POSIX/R4 destination was not truncated to zero"
        assert equal (state-persistence-contract) "best-effort" "A4-POSIX/R4 risk contract is inactive"
        sd-assert-no-publication-claim $result.stderr

        let f1 = ($tmp | path join "f1")
        mkdir $f1
        let f1_source = ($f1 | path join "source.nuon")
        let f1_destination = ($f1 | path join "destination.nuon")
        "F1-NEW" | save $f1_source
        "F1-OLD" | save $f1_destination
        ^chmod 0644 $f1_source $f1_destination
        ^chmod 0555 $f1
        let f1_result = (run-command-process $tmp $"mv -f ($f1_source | to nuon) ($f1_destination | to nuon)")
        ^chmod 0755 $f1
        assert equal $f1_result.exit_code 0 "A9 Nu 0.89 exit drifted"
        assert equal ($f1_result.stdout | str trim) "" "A9 wrote stdout"
        assert ($f1_result.stderr | str contains "Permission denied") $"A9 omitted native failure: ($f1_result.stderr)"
        assert ($f1_source | path exists) "A9 source was not retained"
        assert equal (open $f1_source --raw) "F1-NEW" "A9 source bytes changed"
        assert equal (open $f1_destination --raw) "F1-NEW" "A9 did not record complete fallback-copy bytes"
        sd-assert-no-publication-claim $f1_result.stderr
        print $"STATE_FB_POSIX_089=EXECUTED uid=($uid) destination=empty source=retained"
        print $"STATE_FB_POSIX_F1_089=EXECUTED uid=($uid) destination=intended source=retained"
    } {
        if ($tmp | path exists) {
            ^sudo -n rm -rf $tmp
        }
    }
}

def test-sd-cleanup-runtime-gate-and-emitters [] {
    let state = (open ($env.NURL_REPO_ROOT | path join "nu_modules" "state-store.nu") --raw)
    let upper = ($state | ascii-upcase)
    for forbidden in ["LOG WARN" "LOG INFO" "LOG DEBUG" "LOG SUCCESS" "LOG ERROR"] {
        assert (not ($upper | str contains $forbidden)) $"cleanup source contains forbidden emitter: ($forbidden)"
    }
    let print_lines = (
        $state
        | lines
        | each {|line| $line | str trim }
        | where {|line| $line | str starts-with "print " }
    )
    assert (($print_lines | length) > 0) "cleanup emitter test was vacuous"
    assert ($print_lines | all {|line| $line | str starts-with "print --stderr " }) "cleanup source contains a bare/non-stderr print"
    assert ($state | str contains "could not be removed; remove it manually.") "cleanup warning omits the manual remedy"
    assert ($state | str contains "def state-rm-reports-structured") "cleanup source omits the positive version gate"
    assert ($state | str contains "let raw = try { (version).version } catch { null }") "version parse failure does not visibly fall back"
    assert ($state | str contains 'if $raw == null { return false }') "unknown version does not fall back"
    assert ($state | str contains 'if not $parsed.ok { return false }') "malformed version does not fall back"
    assert ($state | str contains "rm --force --verbose $path") "structured removal does not request rows"
    assert ($state | str contains "rm --force $path") "fallback removal is missing"
    assert (not ($state | str contains "probe")) "cleanup gate contains a behavioral capability probe"
    assert ($state | str contains "cleanup-state-paths [$path] $destination") "immediate failure cleanup does not share removal semantics"
    assert ($state | str contains "cleanup-state-paths ($aged | get name) $destination --stale") "stale sweep bypasses shared removal semantics"
}

def test-sd-source-packaging-and-tree-cleanliness [] {
    let repo = $env.NURL_REPO_ROOT
    let state = (open ($repo | path join "nu_modules" "state-store.nu") --raw | ascii-upcase)
    for forbidden in [".nurl-state" ".secured-v1" "create.lock" "initialize-state-store" "powershell" "pwsh" "icacls" "^chmod" "^stat" "^ln" "^mv" "owner-token" "sidecar"] {
        assert (not ($state | str contains ($forbidden | ascii-upcase))) $"state-store contains rejected production mechanism: ($forbidden)"
    }
    for installer in ["install.ps1" "install.sh"] {
        assert ((open ($repo | path join $installer) --raw) | str contains '"state-store.nu"') $"($installer) omits state-store.nu"
    }
    let before = (^git -C $repo status --porcelain | complete)
    $env.API_ROOT = $repo
    api config get | ignore
    api status | ignore
    api collection list | ignore
    api chain list | ignore
    let after = (^git -C $repo status --porcelain | complete)
    assert equal $after.exit_code 0 "git status failed after read-only lifecycle"
    assert equal $after.stdout $before.stdout "read-only lifecycle changed tracked tree status"
    assert equal (sd-state-artifacts $repo (sd-workspace-destinations)) [] "direct repository scan found a state artifact"
}

export def run-suite-state-durability []: nothing -> list<record> {
    print $"\n(ansi cyan)── Durable native state persistence ──(ansi reset)"
    let saved_root = ($env.API_ROOT? | default null)
    let results = [
        (run-test "SD01 replacement bytes and temp cleanup" { test-sd-replacement-bytes-and-temp-cleanup })
        (run-test "SD02 failed staging preserves prior bytes" { test-sd-staging-failure-preserves-bytes })
        (run-test "SD03 partial new file fails closed" { test-sd-partial-new-file-fails-closed })
        (run-test "SD04 Gate A main-parity create shape" { test-sd-gate-a-main-parity-create-shape })
        (run-test "SD05 Gate B sequential duplicate" { test-sd-gate-b-sequential-duplicate })
        (run-test "SD06 Gate C create race invariants" { test-sd-gate-c-create-race-invariants })
        (run-test "SD07 corrupt state matrix" { test-sd-corrupt-state-matrix })
        (run-test "SD08 strict/default reader structure" { test-sd-reader-structure-and-default-boundary })
        (run-test "SD16 POSIX I/O propagation" { test-sd-io-propagation-posix })
        (run-test "SD16 Windows I/O propagation" { test-sd-io-propagation-windows })
        (run-test "SD17 POSIX present unreadable never defaults" { test-sd-or-default-posix })
        (run-test "SD17 Windows present unreadable never defaults" { test-sd-or-default-windows })
        (run-test "SD09 stale sibling cleanup policies" { test-sd-stale-sibling-policy })
        (run-test "SD10 lifecycle scanner and Phase S" { test-sd-lifecycle-scanner-and-self-test })
        (run-test "SD11 collection copy parity and noninterpretation" { test-sd-collection-copy-does-not-interpret-retired-names })
        (run-test "SD12 PATH-empty lifecycle" { test-sd-path-empty-lifecycle })
        (run-test "SD13 POSIX symlink ancestor and mode" { test-sd-posix-symlinked-ancestor-and-mode })
        (run-test "SD14 Windows alias paths" { test-sd-windows-alias-paths })
        (run-test "SD20 Windows inherited state ACL" { test-sd-windows-inherited-state-acl })
        (run-test "SD15 chain list/table compatibility" { test-sd-chain-list-table-compatibility })
        (run-test "SD19 concurrent first initialization" { test-sd-concurrent-first-initialization })
        (run-test "SD22 Family A contract and persistence inventory" { test-sd-family-a-contract-and-inventory })
        (run-test "SD23 final-state detector outcomes" { test-sd-final-state-detector-outcomes })
        (run-test "SD25 Windows native fallback characterization" { test-sd-windows-native-fallback-characterization })
        (run-test "SD24 POSIX native fallback counterfixtures" { test-sd-posix-native-fallback-counterfixtures })
        (run-test "SD21 cleanup runtime gate and emitters" { test-sd-cleanup-runtime-gate-and-emitters })
        (run-test "SD18 packaging and tree cleanliness" { test-sd-source-packaging-and-tree-cleanliness })
    ]
    if $saved_root == null { hide-env API_ROOT } else { $env.API_ROOT = $saved_root }
    $results
}
