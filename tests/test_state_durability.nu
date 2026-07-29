# Atomic workspace state persistence and fail-closed read regressions.

use ../nu_modules/state-store.nu [open-state-record save-state-bytes]

def state-durability-entries [root: string] {
    if not ($root | path exists) {
        return []
    }
    ls -a $root | each {|entry|
        if $entry.type == "dir" {
            state-durability-entries $entry.name
        } else {
            [$entry.name]
        }
    } | flatten
}

def state-durability-snapshot [root: string] {
    state-durability-entries $root
    | where {|path| $path | str ends-with ".nuon" }
    | each {|path|
        {
            path: ($path | path relative-to $root | str replace --all "\\" "/")
            content: (open $path --raw)
        }
    }
    | sort-by path
}

def state-temp-files [root: string] {
    state-durability-entries $root
    | where {|path|
        let name = ($path | path basename)
        ($name | str starts-with ".") and ($name | str contains ".nurl-") and ($name | str ends-with ".tmp")
    }
}

def assert-no-state-temps [root: string] {
    assert equal (state-temp-files $root) [] "workspace retained a state-store temporary file"
}

def setup-state-workspace [root: string] {
    api init | ignore
    api vars set base_url "https://example.invalid" | ignore
    api auth bearer set durable "CREDENTIAL-SENTINEL" | ignore
    api collection create durable | ignore
    api collection env create durable dev --activate | ignore
    api collection env set durable base_url "https://example.invalid" --target dev | ignore
    api request create ping GET "{{base_url}}/ping" --collection durable | ignore
    api chain create durable | ignore
}

def state-category-cases [root: string] {
    [
        {
            category: "config"
            path: ($root | path join "config.nuon")
            command: "api config get | ignore"
        }
        {
            category: "variables"
            path: ($root | path join "variables.nuon")
            command: "api vars list | ignore"
        }
        {
            category: "credentials"
            path: ($root | path join "secrets.nuon")
            command: "api auth list | ignore"
        }
        {
            category: "collection"
            path: ($root | path join "collections" "durable" "collection.nuon")
            command: "api collection show durable | ignore"
        }
        {
            category: "collection metadata"
            path: ($root | path join "collections" "durable" "meta.nuon")
            command: "api collection env list durable | ignore"
        }
        {
            category: "environment"
            path: ($root | path join "collections" "durable" "environments" "dev.nuon")
            command: "api collection env show durable dev | ignore"
        }
        {
            category: "request"
            path: ($root | path join "collections" "durable" "requests" "ping.nuon")
            command: "api request show ping --collection durable | ignore"
        }
        {
            category: "chain"
            path: ($root | path join "chains" "durable.nuon")
            command: "api chain show durable | ignore"
        }
    ]
}

def write-state-corruption [path: string, kind: string] {
    match $kind {
        "syntax" => { "{token: CREDENTIAL-SENTINEL" | save -f $path }
        "shape" => { "[CREDENTIAL-SENTINEL]" | save -f $path }
        "binary" => { 0x[ff fe 00 43 52 45 44] | save -f $path }
    }
}

def assert-state-read-failure [result: record, path: string, label: string] {
    assert ($result.exit_code != 0) $"($label) unexpectedly exited zero"
    assert equal ($result.stdout | str trim) "" $"($label) wrote stdout"
    assert equal $result.stderr ($result.stderr | ansi strip) $"($label) emitted ANSI stderr"
    assert ($result.stderr | str contains ($path | path basename)) $"($label) did not name the state path"
    assert ($result.stderr | str contains "recreate") $"($label) omitted the recovery step"
    for leaked in [
        "CREDENTIAL-SENTINEL"
        "Unexpected end of code"
        "error when parsing nuon text"
        "nu::shell::outsidespan"
    ] {
        assert (not ($result.stderr | str contains $leaked)) $"($label) leaked forbidden parser/content text: ($leaked)"
    }
}

def test-state-atomic-bytes [] {
    let root = (make-temp-dir "state-bytes")
    let failure = try {
        let cases = [
            {
                name: "compact"
                serialized: ({alpha: 1 beta: "two"} | to nuon)
            }
            {
                name: "indented"
                serialized: ({alpha: 1 nested: {beta: "two"}} | to nuon --indent 4)
            }
            {
                name: "binary"
                serialized: 0x[00 ff 10 20 0a]
            }
        ]
        for case in $cases {
            let legacy_path = ($root | path join $"legacy-($case.name)")
            let atomic_path = ($root | path join $"atomic-($case.name)")
            $case.serialized | save $legacy_path
            save-state-bytes $atomic_path $case.serialized
            assert equal (open $atomic_path --raw) (open $legacy_path --raw) $"($case.name) bytes changed through the state helper"
        }

        let init_root = ($root | path join "workspace")
        mkdir $init_root
        $env.API_ROOT = $init_root
        api init | ignore
        let expected_config = ({
            default_headers: {
                "Content-Type": "application/json"
                "Accept": "application/json"
            }
            timeout_seconds: 30
            history_retention_days: 30
            editor: "code"
            colors: {
                success: "green"
                error: "red"
                warning: "yellow"
                info: "blue"
            }
        } | to nuon)
        let expected_path = ($root | path join "expected-config.nuon")
        $expected_config | save $expected_path
        assert equal (open ($init_root | path join "config.nuon") --raw) (open $expected_path --raw) "api init changed config serialization"

        if $nu.os-info.name != "windows" {
            let target = ($root | path join "symlink-target.nuon")
            let link = ($root | path join "symlink-state.nuon")
            {before: true} | to nuon | save $target
            ^ln -s $target $link
            save-state-bytes $link ({after: true} | to nuon)
            assert equal (open $target) {after: true} "symlink-backed state did not update its target"
            let link_check = (do { ^test -L $link } | complete)
            assert equal $link_check.exit_code 0 "state replacement destroyed the destination symlink"
        }
        assert-no-state-temps $root
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def test-state-failed-commit-preserves-original [] {
    let root = (make-temp-dir "state-commit")
    let failure = try {
        $env.API_ROOT = $root
        setup-state-workspace $root
        let path = ($root | path join "secrets.nuon")
        let before = (open $path --raw)
        if $nu.os-info.name == "windows" {
            let lock = (start-state-read-lock $root $path)
            let result = (run-command-process $root "api auth bearer set interrupted NEW-CREDENTIAL-SENTINEL")
            stop-state-read-lock $lock
            assert ($result.exit_code != 0) "locked commit failure exited zero"
            assert equal ($result.stdout | str trim) "" "locked credential commit wrote stdout"
            assert (not ($result.stderr | str contains "NEW-CREDENTIAL-SENTINEL")) "locked credential commit leaked the new credential"
        } else {
            let temp_dir = ($root | path join ".nurl-state")
            ^chmod 500 $temp_dir
            let result = (run-command-process $root "api auth bearer set interrupted NEW-CREDENTIAL-SENTINEL")
            ^chmod 700 $temp_dir
            assert ($result.exit_code != 0) "read-only-directory write failure exited zero"
            assert equal ($result.stdout | str trim) "" "read-only-directory credential write wrote stdout"
            assert (not ($result.stderr | str contains "NEW-CREDENTIAL-SENTINEL")) "failed credential write leaked the new credential"
        }
        assert equal (open $path --raw) $before "failed credential write changed the original bytes"
        assert equal (api auth bearer get durable) "CREDENTIAL-SENTINEL" "failed write damaged the original credential store"
        assert equal (api auth bearer get interrupted) null "failed write persisted the interrupted credential"
        assert-no-state-temps $root
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def test-state-corruption-contracts [] {
    let root = (make-temp-dir "state-corruption")
    let failure = try {
        $env.API_ROOT = $root
        setup-state-workspace $root
        for category in (state-category-cases $root) {
            let valid = (open $category.path --raw)
            for corruption in ["syntax" "shape" "binary"] {
                if $category.category == "chain" and $corruption == "shape" {
                    "42" | save -f $category.path
                } else {
                    write-state-corruption $category.path $corruption
                }
                let result = (run-command-process $root $category.command)
                assert-state-read-failure $result $category.path $"($category.category)/($corruption)"
                $valid | save -f $category.path
            }
        }
        assert-no-state-temps $root
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def start-state-read-lock [root: string, target: string] {
    if $nu.os-info.name != "windows" {
        let raw = (open $target --raw)
        rm $target
        mkdir $target
        return {mode: "directory", target: $target, raw: $raw}
    }

    let holder = ($root | path join "state-read-lock-holder.ps1")
    let launcher = ($root | path join "state-read-lock-launcher.ps1")
    let ready = ($root | path join "state-read-lock-ready.txt")
    "param($Target, $Ready)
$stream = [System.IO.File]::Open($Target, 'Open', 'Read', 'None')
try {
    [System.IO.File]::WriteAllText($Ready, 'ready')
    [System.Threading.ManualResetEvent]::new($false).WaitOne() | Out-Null
} finally {
    $stream.Dispose()
}" | save -f $holder
    "param($Holder, $Target, $Ready)
$arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('\"{0}\"' -f $Holder), ('\"{0}\"' -f $Target), ('\"{0}\"' -f $Ready))
$process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -PassThru -WindowStyle Hidden
if (-not [System.Threading.SpinWait]::SpinUntil({ Test-Path -LiteralPath $Ready }, 10000)) {
    Stop-Process -Id $process.Id -Force
    throw 'State read lock did not reach the ready barrier'
}
$process.Id" | save -f $launcher
    let result = (test-complete-result (
        ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcher $holder $target $ready
        | complete
    ))
    assert equal $result.exit_code 0 $"state read lock failed: ($result.stderr)"
    {mode: "lock", pid: ($result.stdout | str trim | into int)}
}

def stop-state-read-lock [lock: record] {
    if $lock.mode == "directory" {
        rm -rf $lock.target
        $lock.raw | save $lock.target
        return
    }
    let result = (test-complete-result (
        ^powershell.exe -NoProfile -NonInteractive -Command (
            "Stop-Process -Id " + ($lock.pid | into string) + " -Force -ErrorAction SilentlyContinue"
        )
        | complete
    ))
    assert equal $result.exit_code 0 $"state read lock release failed: ($result.stderr)"
}

def test-state-io-errors-and-no-clobber [] {
    let root = (make-temp-dir "state-io")
    let failure = try {
        $env.API_ROOT = $root
        setup-state-workspace $root
        let config_path = ($root | path join "config.nuon")
        let lock = (start-state-read-lock $root $config_path)
        let unreadable = (run-command-process $root "api config get | ignore")
        stop-state-read-lock $lock

        assert ($unreadable.exit_code != 0) "unreadable config exited zero"
        assert equal ($unreadable.stdout | str trim) "" "unreadable config wrote stdout"
        assert ($unreadable.stderr | str contains "config.nuon") "unreadable config did not name its path"
        assert (not ($unreadable.stderr | str contains "invalid or does not contain a NUON record")) "I/O failure was mislabeled as invalid NUON"

        let chain_path = ($root | path join "chains" "durable.nuon")
        let request_path = ($root | path join "collections" "durable" "requests" "ping.nuon")
        let environment_path = ($root | path join "collections" "durable" "environments" "dev.nuon")
        let before = {
            chain: (open $chain_path --raw)
            request: (open $request_path --raw)
            environment: (open $environment_path --raw)
        }
        let duplicates = [
            {
                result: (run-command-process $root "api chain create durable")
                expected: "Chain 'durable' already exists"
            }
            {
                result: (run-command-process $root "api request create ping GET 'https://example.invalid' --collection durable")
                expected: "Destination file already exists"
            }
            {
                result: (run-command-process $root "api collection env create durable dev")
                expected: "Environment 'dev' already exists in collection 'durable'"
            }
        ]
        for duplicate in $duplicates {
            assert ($duplicate.result.exit_code != 0) $"duplicate create exited zero: ($duplicate.expected)"
            assert equal ($duplicate.result.stdout | str trim) "" $"duplicate create wrote stdout: ($duplicate.expected)"
            assert ($duplicate.result.stderr | str contains $duplicate.expected) $"duplicate create changed its message: ($duplicate.expected)"
        }
        assert equal (open $chain_path --raw) $before.chain "duplicate chain create changed bytes"
        assert equal (open $request_path --raw) $before.request "duplicate request create changed bytes"
        assert equal (open $environment_path --raw) $before.environment "duplicate environment create changed bytes"
        assert-no-state-temps $root
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def test-state-read-only-and-credentials [] {
    let root = (make-temp-dir "state-read-only")
    let failure = try {
        $env.API_ROOT = $root
        setup-state-workspace $root
        api auth basic set retained retained-user PASSWORD-SENTINEL | ignore
        api auth bearer set second SECOND-CREDENTIAL-SENTINEL | ignore
        let secrets_path = ($root | path join "secrets.nuon")
        let mode_before = if $nu.os-info.name == "windows" {
            null
        } else {
            ^chmod 600 $secrets_path
            (^stat -c "%a" $secrets_path | str trim)
        }
        api auth bearer set mode-check MODE-CHECK-SENTINEL | ignore
        if $mode_before != null {
            assert equal (^stat -c "%a" $secrets_path | str trim) $mode_before "credential update changed POSIX mode bits"
        }
        let before = (state-durability-snapshot $root)

        let commands = [
            "api status | ignore"
            "api config get | ignore"
            "api vars list | ignore"
            "api collection list | ignore"
            "api collection show durable | ignore"
            "api collection env list durable | ignore"
            "api collection env show durable dev | ignore"
            "api request list --collection durable | ignore"
            "api request show ping --collection durable | ignore"
            "api auth list | ignore"
            "api chain list | ignore"
            "api chain show durable | ignore"
        ]
        for command in $commands {
            let result = (run-command-process $root $command)
            assert equal $result.exit_code 0 $"read-only command failed: ($command); ($result.stderr)"
            assert equal ($result.stderr | str trim) "" $"read-only command wrote stderr: ($command)"
        }
        assert equal (state-durability-snapshot $root) $before "read-only command sweep changed state bytes"

        assert equal (api auth bearer get durable) "CREDENTIAL-SENTINEL"
        assert equal (api auth bearer get second) "SECOND-CREDENTIAL-SENTINEL"
        let secrets = (open-state-record $secrets_path)
        assert equal $secrets.basic_auth.retained.username "retained-user"
        assert equal $secrets.basic_auth.retained.password "PASSWORD-SENTINEL"
        let expected_path = ($root | path join "expected-secrets")
        $secrets | to nuon | save $expected_path
        assert equal (open $secrets_path --raw) (open $expected_path --raw) "credential store serialization changed"

        rm $secrets_path
        api auth bearer set recreated RECREATED-CREDENTIAL-SENTINEL | ignore
        let recreated = (open-state-record $secrets_path)
        assert equal ($recreated | columns) [tokens saml_tokens oauth api_keys basic_auth] "recreated credential store changed default key order"
        assert-no-state-temps $root
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def set-state-path-stale [path: string] {
    if $nu.os-info.name == "windows" {
        let setter = if (($path | path type) == "dir") {
            "[System.IO.Directory]::SetLastWriteTimeUtc("
        } else {
            "[System.IO.File]::SetLastWriteTimeUtc("
        }
        let result = (test-complete-result (
            ^powershell.exe -NoProfile -NonInteractive -Command (
                $setter
                + ($path | to nuon)
                + ", [DateTime]::UtcNow.AddHours(-2))"
            )
            | complete
        ))
        assert equal $result.exit_code 0 $"could not age state temp: ($result.stderr)"
    } else {
        let result = (test-complete-result (^touch -t "200001010000" $path | complete))
        assert equal $result.exit_code 0 $"could not age state temp: ($result.stderr)"
    }
}

    def windows-dacl-info [path: string] {
    let script = "$acl = [System.IO.Directory]::GetAccessControl($env:NURL_DACL_PATH)
    $sddl = $acl.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All)
$raw = [System.Security.AccessControl.RawSecurityDescriptor]::new($sddl)
    @{ ace_count = $raw.DiscretionaryAcl.Count; owner = $raw.Owner.Value } | ConvertTo-Json -Compress"
    let result = (test-complete-result (
        do {
            with-env {NURL_DACL_PATH: $path} {
                ^powershell.exe -NoProfile -NonInteractive -Command $script
            }
        }
        | complete
    ))
    assert equal $result.exit_code 0 $"could not inspect Windows DACL: ($result.stderr)"
    $result.stdout | from json
}

def normalize-windows-dacl [sddl: string] {
    $sddl
    | parse --regex '\((?<ace>[^)]+)\)'
    | get ace
    | each {|ace| $ace | str replace ";ID;" ";;" }
    | sort
}

def test-state-native-write-and-stale-cleanup [] {
    let root = (make-temp-dir "state-native")
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let source = (open ($env.NURL_REPO_ROOT | path join "nu_modules" "state-store.nu") --raw)
        for forbidden in ["powershell" "pwsh" "NURL_TEST_STATE_STORE_FAIL_COMMIT"] {
            assert (not ($source | str contains $forbidden)) $"production state writes use forbidden external path '($forbidden)'"
        }
        if $nu.os-info.name == "windows" {
            let no_external_root = (make-temp-dir "state-no-powershell")
            $env.API_ROOT = $no_external_root
            with-env {PATH: ""} {
                api init | ignore
                api config set no_external_runtime true | ignore
                api auth bearer set no-external-runtime NO-EXTERNAL-SENTINEL | ignore
                api collection create no-external | ignore
                api collection env create no-external active --activate | ignore
                api collection env set no-external value exact --target active | ignore
            }
            assert equal (api auth bearer get no-external-runtime) "NO-EXTERNAL-SENTINEL" "state writes acquired an external runtime dependency"
            assert equal (api collection env show no-external active | get variables | first | get value) exact "collection environment write acquired a PowerShell/PATH dependency"
            cleanup $no_external_root
            $env.API_ROOT = $root

            let precreated_root = (make-temp-dir "state-precreated-temp")
            mkdir ($precreated_root | path join ".nurl-state")
            let explicit_grant = (test-complete-result (
                ^icacls.exe ($precreated_root | path join ".nurl-state") "/grant" "*S-1-1-0:(OI)(CI)R" "/Q"
                | complete
            ))
            assert equal $explicit_grant.exit_code 0 $"could not add explicit broad DACL fixture: ($explicit_grant.stderr)"
            $env.API_ROOT = $precreated_root
            api init | ignore
            let dacl = (windows-dacl-info ($precreated_root | path join ".nurl-state"))
            let current_sid = (
                ^powershell.exe -NoProfile -NonInteractive -Command "[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value"
                | str trim
            )
            assert equal $dacl.ace_count 1 "pre-created state temp directory was not resecured"
            assert equal $dacl.owner $current_sid "pre-created state temp directory owner was not transferred"
            cleanup $precreated_root
            $env.API_ROOT = $root
        } else {
            with-env {PATH: ""} {
                api config set no_external_runtime true | ignore
                api auth bearer set no-external-runtime NO-EXTERNAL-SENTINEL | ignore
            }
            assert equal (api auth bearer get no-external-runtime) "NO-EXTERNAL-SENTINEL" "state writes acquired an external runtime dependency"
        }

        let link_root = (make-temp-dir "state-temp-link")
        let link_target = (make-temp-dir "state-temp-link-target")
        let link_path = ($link_root | path join ".nurl-state")
        if $nu.os-info.name == "windows" {
            let linked = (test-complete-result (
                ^powershell.exe -NoProfile -NonInteractive -Command (
                    "New-Item -ItemType Junction -Path "
                    + ($link_path | to nuon)
                    + " -Target "
                    + ($link_target | to nuon)
                    + " | Out-Null"
                )
                | complete
            ))
            assert equal $linked.exit_code 0 $"could not create state junction fixture: ($linked.stderr)"
        } else {
            ^ln -s $link_target $link_path
        }
        let linked_result = (run-command-process $link_root "api init")
        assert ($linked_result.exit_code != 0) "linked state temp directory unexpectedly initialized"
        assert (
            ($linked_result.stderr | str contains "State temp")
                and (
                    ($linked_result.stderr | str contains "link")
                        or ($linked_result.stderr | str contains "directory")
                )
        ) $"linked state temp error was not actionable: ($linked_result.stderr)"
        cleanup $link_root
        cleanup $link_target
        $env.API_ROOT = $root

        api chain create warm-chain | ignore
        let chain_state_dir = ($root | path join "chains" ".nurl-state")
        let warm_lock = ($chain_state_dir | path join ".warm-chain.nuon.create.lock")
        assert (not ($warm_lock | path exists)) "owner did not release successful create lock"

        let foreign_lock = ($chain_state_dir | path join ".foreign.nuon.create.lock")
        "FOREIGN-LOCK-TOKEN" | save $foreign_lock
        let foreign_before = (open $foreign_lock --raw)
        let foreign_result = (run-command-process $root "api chain create foreign")
        assert ($foreign_result.exit_code != 0) "fresh foreign create lock did not block contender"
        assert equal (open $foreign_lock --raw) $foreign_before "nonowner changed or deleted a fresh create lock"
        assert (not (($root | path join "chains" "foreign.nuon") | path exists)) "foreign-lock contender published state"
        rm -f $foreign_lock

        let legacy_sibling_lock = ($root | path join "chains" ".blocked.nuon.nurl-create.lock")
        "LEGACY-FOREIGN-LOCK-TOKEN" | save $legacy_sibling_lock
        let legacy_sibling_before = (open $legacy_sibling_lock --raw)
        let legacy_blocked = (run-command-process $root "api chain create blocked")
        assert ($legacy_blocked.exit_code != 0) "fresh legacy sibling lock did not block contender"
        assert equal ($legacy_blocked.stdout | str trim) "" "legacy-lock contender wrote success output"
        assert equal $legacy_blocked.stderr ($legacy_blocked.stderr | ansi strip) "legacy-lock contender wrote ANSI stderr"
        assert ($legacy_blocked.stderr | str contains "legacy lock is still active") $"legacy-lock error was not actionable: ($legacy_blocked.stderr)"
        assert equal (open $legacy_sibling_lock --raw) $legacy_sibling_before "legacy-lock contender changed or deleted foreign lock bytes"
        assert (not (($root | path join "chains" "blocked.nuon") | path exists)) "legacy-lock contender published destination"
        assert-no-state-temps $root
        rm -f $legacy_sibling_lock

        let stale_lock = ($chain_state_dir | path join ".stale-chain.nuon.create.lock")
        "STALE-LOCK-TOKEN" | save $stale_lock
        set-state-path-stale $stale_lock
        api chain create stale-chain | ignore
        assert (not ($stale_lock | path exists)) "next no-clobber mutation did not remove stale create lock"
        let legacy_lock = ($chain_state_dir | path join ".legacy-chain.nuon.create.lock")
        mkdir $legacy_lock
        set-state-path-stale $legacy_lock
        api chain create legacy-chain | ignore
        assert (not ($legacy_lock | path exists)) "next no-clobber mutation did not remove stale legacy directory lock"
        let stale_sibling_lock = ($root | path join "chains" ".stale-sibling.nuon.nurl-create.lock")
        "STALE-SIBLING-LOCK" | save $stale_sibling_lock
        set-state-path-stale $stale_sibling_lock
        api chain create stale-sibling | ignore
        assert (not ($stale_sibling_lock | path exists)) "next no-clobber mutation did not remove stale legacy sibling lock"
        assert-no-state-temps $root
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def test-state-concurrent-no-clobber [] {
    let root = (make-temp-dir "state-concurrent-create")
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        api chain create warm | ignore
        let lock_path = ($root | path join "chains" ".nurl-state" ".race.nuon.create.lock")
        "STALE-CONCURRENT-LOCK" | save $lock_path
        set-state-path-stale $lock_path
        let module_path = ($env.NURL_REPO_ROOT | path join "nu_modules" "mod.nu")
        let release_path = ($root | path join "release.txt")
        let child_one = ($root | path join "create-one.nu")
        let child_two = ($root | path join "create-two.nu")
        let result_one = ($root | path join "result-one.txt")
        let result_two = ($root | path join "result-two.txt")
        let launcher = ($root | path join "launch-creates.ps1")
        for child in [
            {script: $child_one, result: $result_one, description: "winner-one"}
            {script: $child_two, result: $result_two, description: "winner-two"}
        ] {
            [
                $"use ($module_path | to nuon) *"
                $"$env.API_ROOT = ($root | to nuon)"
                $"let release = ($release_path | to nuon)"
                "while not ($release | path exists) {}"
                ("let outcome = try { api chain create race --description "
                    + ($child.description | to nuon)
                    + "; {status: 'success', error: ''} } catch {|error| {status: 'failure', error: $error.msg}}")
                $"$outcome | to nuon | save ($child.result | to nuon)"
            ] | str join "\n" | save $child.script
        }
        "param($Nu, $One, $Two, $Release)
$first = Start-Process -FilePath $Nu -ArgumentList @('--no-config-file', $One) -PassThru
$second = Start-Process -FilePath $Nu -ArgumentList @('--no-config-file', $Two) -PassThru
[System.IO.File]::WriteAllText($Release, 'release')
$first.WaitForExit()
$second.WaitForExit()" | save $launcher

        let shell = if $nu.os-info.name == "windows" { "powershell.exe" } else { "pwsh" }
        let launched = (test-complete-result (
            ^$shell -NoProfile -NonInteractive -File $launcher $nu.current-exe $child_one $child_two $release_path
            | complete
        ))
        assert equal $launched.exit_code 0 $"concurrent create launcher failed: ($launched.stderr)"
        let outcomes = [
            (open $result_one --raw | from nuon)
            (open $result_two --raw | from nuon)
        ]
        let statuses = ($outcomes | get status | sort)
        assert ($statuses == ["failure" "success"]) $"concurrent create expected one winner and loser: ($outcomes)"
        let winner = (open-state-record ($root | path join "chains" "race.nuon"))
        assert equal $winner.name "race" "concurrent create winner bytes were invalid"
        assert ($winner.description in ["winner-one" "winner-two"]) "concurrent stale recovery did not preserve winner bytes"
        assert (not ($lock_path | path exists)) "concurrent create left a lock sentinel"
        assert-no-state-temps $root
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def test-windows-constrained-language-writes [] {
    if $nu.os-info.name != "windows" {
        return
    }

    let root = (make-temp-dir "state-constrained-language")
    let failure = try {
        $env.API_ROOT = $root
        let child_script = ($root | path join "constrained-child.nu")
        let launcher_script = ($root | path join "constrained-launcher.ps1")
        let module_path = ($env.NURL_REPO_ROOT | path join "nu_modules" "mod.nu")
        [
            $"use ($module_path | to nuon) *"
            $"$env.API_ROOT = ($root | to nuon)"
            "api init | ignore"
            "api config set constrained true | ignore"
            "api auth bearer set constrained CONSTRAINED-SENTINEL | ignore"
            "api collection create constrained | ignore"
            "api collection env create constrained active --activate | ignore"
            "api collection env set constrained value exact --target active | ignore"
        ] | str join "\n" | save $child_script
        "param($Nu, $Child)
$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'
& $Nu --no-config-file $Child
exit $LASTEXITCODE" | save $launcher_script

        let result = (test-complete-result (
            ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcher_script $nu.current-exe $child_script
            | complete
        ))
        assert equal $result.exit_code 0 $"state writes failed under PowerShell Constrained Language Mode: ($result.stderr)"
        assert equal (open-state-record ($root | path join "config.nuon") | get constrained) true
        assert equal (api auth bearer get constrained) "CONSTRAINED-SENTINEL"
        assert equal (api collection env show constrained active | get variables | first | get value) exact
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def test-windows-state-temp-dacl [] {
    if $nu.os-info.name != "windows" {
        return
    }

    let root = (make-temp-dir "state-temp-dacl")
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let child_script = ($root | path join "dacl-child.nu")
        let watcher_script = ($root | path join "dacl-watcher.ps1")
        let token_path = ($root | path join "large-token.txt")
        let result_path = ($root | path join "dacl-result.json")
        let stdout_path = ($root | path join "dacl-child.stdout")
        let stderr_path = ($root | path join "dacl-child.stderr")
        let module_path = ($env.NURL_REPO_ROOT | path join "nu_modules" "mod.nu")
        let original_secrets = (open ($root | path join "secrets.nuon") --raw)
        let state_dir = ($root | path join ".nurl-state")
        [
            $"use ($module_path | to nuon) *"
            $"$env.API_ROOT = ($root | to nuon)"
            ("let token = (open " + ($token_path | to nuon) + " --raw)")
            "api auth bearer set temp-dacl $token | ignore"
        ] | str join "\n" | save $child_script

        "param($Root, $Nu, $Child, $Token, $Result, $Stdout, $Stderr)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public static class NurlTempAcl {
    [DllImport(\"advapi32.dll\", SetLastError = true)]
    private static extern uint GetSecurityInfo(
        IntPtr handle,
        int objectType,
        uint securityInfo,
        out IntPtr owner,
        out IntPtr group,
        out IntPtr dacl,
        out IntPtr sacl,
        out IntPtr descriptor);

    [DllImport(\"advapi32.dll\", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ConvertSecurityDescriptorToStringSecurityDescriptor(
        IntPtr descriptor,
        uint revision,
        uint securityInfo,
        out IntPtr text,
        out uint length);

    [DllImport(\"kernel32.dll\")]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static string GetSddl(FileStream stream) {
        IntPtr owner;
        IntPtr group;
        IntPtr dacl;
        IntPtr sacl;
        IntPtr descriptor;
        uint result = GetSecurityInfo(
            stream.SafeFileHandle.DangerousGetHandle(),
            1,
            7,
            out owner,
            out group,
            out dacl,
            out sacl,
            out descriptor);
        if (result != 0) {
            throw new Win32Exception((int)result);
        }
        try {
            IntPtr text;
            uint length;
            if (!ConvertSecurityDescriptorToStringSecurityDescriptor(descriptor, 1, 7, out text, out length)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            try {
                return Marshal.PtrToStringUni(text);
            } finally {
                LocalFree(text);
            }
        } finally {
            LocalFree(descriptor);
        }
    }
}

public sealed class NurlTempCapture : IDisposable {
    private readonly FileSystemWatcher watcher;
    private readonly ManualResetEvent ready = new ManualResetEvent(false);
    private int captured;

    public NurlTempCapture(string root, string filter) {
        watcher = new FileSystemWatcher(root, filter);
        watcher.NotifyFilter = NotifyFilters.FileName;
        watcher.Created += OnCreated;
        watcher.EnableRaisingEvents = true;
    }

    private void OnCreated(object sender, FileSystemEventArgs args) {
        if (Interlocked.CompareExchange(ref captured, 1, 0) != 0) {
            return;
        }
        DateTime deadline = DateTime.UtcNow.AddSeconds(30);
        while (DateTime.UtcNow < deadline) {
            try {
                using (FileStream candidate = new FileStream(
                        args.FullPath,
                        FileMode.Open,
                        FileAccess.Read,
                        FileShare.ReadWrite)) {
                    Name = args.Name;
                    Sddl = NurlTempAcl.GetSddl(candidate);
                }
                ready.Set();
                return;
            } catch (IOException) {
                Thread.Sleep(2);
            }
        }
        Interlocked.Exchange(ref captured, 0);
    }

    public string Name { get; private set; }
    public string Sddl { get; private set; }
    public bool Wait(int milliseconds) { return ready.WaitOne(milliseconds); }

    public void Dispose() {
        watcher.EnableRaisingEvents = false;
        watcher.Dispose();
        ready.Dispose();
    }
}
'@
$destination = Join-Path (Split-Path -Parent $Root) 'secrets.nuon'
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$destinationAcl = [System.Security.AccessControl.FileSecurity]::new()
$destinationAcl.SetOwner($sid)
$destinationAcl.SetAccessRuleProtection($true, $false)
$destinationRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
    $sid,
    [System.Security.AccessControl.FileSystemRights]::FullControl,
    [System.Security.AccessControl.AccessControlType]::Allow)
$destinationAcl.AddAccessRule($destinationRule)
[System.IO.File]::SetAccessControl($destination, $destinationAcl)
$destinationSddl = $destinationAcl.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All)
$broadControl = Join-Path (Split-Path -Parent $Root) 'dacl-broad-control.tmp'
[System.IO.File]::WriteAllText($broadControl, '')
$broadAcl = [System.IO.File]::GetAccessControl($broadControl)
$broadSddl = $broadAcl.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All)
$filter = '.secrets.nuon.nurl-*.tmp'
$capture = [NurlTempCapture]::new($Root, $filter)
[System.IO.File]::WriteAllText($Token, ('X' * 134217728))
$process = Start-Process -FilePath $Nu -ArgumentList @('--no-config-file', $Child) -PassThru -WindowStyle Hidden -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
if (-not $capture.Wait(60000)) {
    $capture.Dispose()
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
    }
    throw 'State temp DACL capture did not become ready'
}
$tempSddl = $capture.Sddl
$tempName = $capture.Name
$capture.Dispose()
$process.WaitForExit()
$process.Refresh()
$payload = @{
    temp_sddl = $tempSddl
    destination_sddl = $destinationSddl
    broad_sddl = $broadSddl
    temp_name = $tempName
}
[System.IO.File]::WriteAllText($Result, ($payload | ConvertTo-Json -Compress))" | save $watcher_script

        let watched = (test-complete-result (
            ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $watcher_script $state_dir $nu.current-exe $child_script $token_path $result_path $stdout_path $stderr_path
            | complete
        ))
        assert equal $watched.exit_code 0 $"state temp DACL watcher failed: ($watched.stderr)"
        assert ($result_path | path exists) $"state temp DACL watcher produced no result: stdout=($watched.stdout) stderr=($watched.stderr)"
        let result = (open $result_path --raw | from json)
        let child_stderr = try { open $stderr_path --raw } catch { "" }
        assert ($result.temp_name | str starts-with ".secrets.nuon.nurl-") "watcher observed the wrong temp file"
        let destination_aces = (normalize-windows-dacl $result.destination_sddl)
        assert ((normalize-windows-dacl $result.broad_sddl) != $destination_aces) "DACL mutation control did not differ from the protected destination"
        assert equal (normalize-windows-dacl $result.temp_sddl) $destination_aces "credential temp effective DACL differed from the protected single-ACE destination"
        if ($child_stderr | str trim | is-empty) {
            assert equal (api auth bearer get temp-dacl | str length) 134217728 "observed credential mutation did not complete"
        } else {
            assert ($child_stderr | str contains "process cannot access") $"observed commit failed for an unexpected reason: ($child_stderr)"
            assert equal (open ($root | path join "secrets.nuon") --raw) $original_secrets "observed commit failure changed credential bytes"
            let orphan = ($state_dir | path join $result.temp_name)
            rm -f $orphan
        }
        assert-no-state-temps $root
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def windows-file-sddl [path: string] {
    let script = "$acl = [System.IO.File]::GetAccessControl($env:NURL_DACL_PATH)
$acl.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All)"
    let result = (test-complete-result (
        do {
            with-env {NURL_DACL_PATH: $path} {
                ^powershell.exe -NoProfile -NonInteractive -Command $script
            }
        }
        | complete
    ))
    assert equal $result.exit_code 0 $"could not inspect Windows file DACL: ($result.stderr)"
    $result.stdout | str trim
}

def test-windows-final-dacl-policy [] {
    if $nu.os-info.name != "windows" {
        return
    }

    let root = (make-temp-dir "state-final-dacl")
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let secrets_path = ($root | path join "secrets.nuon")
        let state_dir = ($root | path join ".nurl-state")
        let harden = "$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = [System.Security.AccessControl.FileSecurity]::new()
$acl.SetOwner($sid)
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
$system = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($system, 'Read', 'Allow'))
[System.IO.File]::SetAccessControl($env:NURL_DACL_PATH, $acl)"
        let hardened = (test-complete-result (
            do {
                with-env {NURL_DACL_PATH: $secrets_path} {
                    ^powershell.exe -NoProfile -NonInteractive -Command $harden
                }
            }
            | complete
        ))
        assert equal $hardened.exit_code 0 $"could not harden destination DACL fixture: ($hardened.stderr)"
        let old_sddl = (windows-file-sddl $secrets_path)

        api auth bearer set final-dacl FINAL-DACL-SENTINEL | ignore

        let final_sddl = (windows-file-sddl $secrets_path)
        let control_path = ($state_dir | path join "final-dacl-control.tmp")
        "" | save $control_path
        let control_sddl = (windows-file-sddl $control_path)
        assert ((normalize-windows-dacl $old_sddl) != (normalize-windows-dacl $control_sddl)) "custom per-file DACL fixture did not differ from temp policy"
        assert equal (normalize-windows-dacl $final_sddl) (normalize-windows-dacl $control_sddl) "final destination did not adopt the protected temp-directory DACL"
        assert equal (api auth bearer get final-dacl) "FINAL-DACL-SENTINEL"
        rm -f $control_path
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def test-history-config-corruption-contracts [] {
    let root = (make-temp-dir "state-history-config")
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let config_path = ($root | path join "config.nuon")
        "{credential: HISTORY-CONFIG-SENTINEL" | save -f $config_path
        let commands = [
            "api history save {method: GET, url: 'https://example.invalid', headers: {}, body: null} {status: 200, status_text: OK, headers: {}, body: null, time_ms: 1, size_bytes: 0} | ignore"
            "api history clear --force"
        ]
        for command in $commands {
            let result = (run-command-process $root $command)
            assert-state-read-failure $result $config_path $command
            assert (not ($result.stderr | str contains "HISTORY-CONFIG-SENTINEL")) $"history config error leaked content: ($command)"
        }
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

export def run-suite-state-durability []: nothing -> list<record> {
    print "\nState durability"
    [
        (run-test "atomic state commits preserve exact serialized bytes" { test-state-atomic-bytes })
        (run-test "failed public credential commits preserve original bytes and clean temps" { test-state-failed-commit-preserves-original })
        (run-test "all state categories reject syntax, shape, and binary corruption cleanly" { test-state-corruption-contracts })
        (run-test "state I/O errors propagate and no-clobber messages stay stable" { test-state-io-errors-and-no-clobber })
        (run-test "read-only state commands are byte-stable and credentials survive mutations" { test-state-read-only-and-credentials })
        (run-test "state writes avoid PowerShell and clean stale create locks" { test-state-native-write-and-stale-cleanup })
        (run-test "concurrent no-clobber creates publish exactly one winner" { test-state-concurrent-no-clobber })
        (run-test "Windows writes work under PowerShell Constrained Language Mode" { test-windows-constrained-language-writes })
        (run-test "Windows credential temps match a protected single-ACE DACL" { test-windows-state-temp-dacl })
        (run-test "Windows replacements adopt the protected temp-directory DACL" { test-windows-final-dacl-policy })
        (run-test "history config readers use fail-closed state errors" { test-history-config-corruption-contracts })
    ]
}
