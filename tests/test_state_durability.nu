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

def state-file-access [path: string] {
    if $nu.os-info.name == "windows" {
        let script = "try { [System.IO.File]::GetAccessControl($env:NURL_STATE_ACCESS_PATH).Sddl } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }"
        let result = (test-complete-result (
            do {
                with-env {NURL_STATE_ACCESS_PATH: $path} {
                    ^powershell.exe -NoProfile -NonInteractive -Command $script
                }
            }
            | complete
        ))
        assert equal $result.exit_code 0 $"could not read state ACL: ($result.stderr)"
        return ($result.stdout | str trim)
    }
    let result = if $nu.os-info.name == "macos" {
        do { ^stat -f "%Lp" $path } | complete
    } else {
        do { ^stat -c "%a" $path } | complete
    }
    assert equal $result.exit_code 0 $"could not read state mode: ($result.stderr)"
    $result.stdout | str trim
}

def restrict-state-file-access [path: string] {
    if $nu.os-info.name == "windows" {
        let script = "try { $acl = [System.IO.File]::GetAccessControl($env:NURL_STATE_ACCESS_PATH); $acl.SetAccessRuleProtection($true, $true); [System.IO.File]::SetAccessControl($env:NURL_STATE_ACCESS_PATH, $acl) } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }"
        let result = (test-complete-result (
            do {
                with-env {NURL_STATE_ACCESS_PATH: $path} {
                    ^powershell.exe -NoProfile -NonInteractive -Command $script
                }
            }
            | complete
        ))
        assert equal $result.exit_code 0 $"could not restrict state ACL: ($result.stderr)"
        return
    }
    let result = (do { ^chmod 600 $path } | complete)
    assert equal $result.exit_code 0 $"could not restrict state mode: ($result.stderr)"
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
    assert ($result.stderr | str contains "Restore or recreate") $"($label) omitted the recovery step"
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
        let result = (with-env {NURL_TEST_STATE_STORE_FAIL_COMMIT: $path} {
            run-command-process $root "api auth bearer set interrupted NEW-CREDENTIAL-SENTINEL"
        })

        assert ($result.exit_code != 0) "injected commit failure exited zero"
        assert equal ($result.stdout | str trim) "" "failed credential commit wrote stdout"
        assert ($result.stderr | str contains "Injected state commit failure") "failed credential commit omitted its cause"
        assert (not ($result.stderr | str contains "NEW-CREDENTIAL-SENTINEL")) "failed credential commit leaked the new credential"
        assert equal (open $path --raw) $before "failed credential commit changed the original bytes"
        assert equal (api auth bearer get durable) "CREDENTIAL-SENTINEL" "failed commit damaged the original credential store"
        assert equal (api auth bearer get interrupted) null "failed commit persisted the interrupted credential"
        assert-no-state-temps $root

        if $nu.os-info.name == "windows" {
            let lock = (start-state-read-lock $root $path)
            let actual_error = try {
                save-state-bytes $path ({replacement: true} | to nuon)
                null
            } catch {|error| $error}
            stop-state-read-lock $lock
            assert ($actual_error != null) "locked destination did not fail at the real commit boundary"
            assert equal (open $path --raw) $before "real commit failure changed the original bytes"
            assert-no-state-temps $root
        }
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
                write-state-corruption $category.path $corruption
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
        restrict-state-file-access ($root | path join "secrets.nuon")
        let access_before = (state-file-access ($root | path join "secrets.nuon"))
        api auth bearer set access-check ACCESS-CREDENTIAL-SENTINEL | ignore
        assert equal (state-file-access ($root | path join "secrets.nuon")) $access_before "credential update changed file permissions"
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
        let secrets_path = ($root | path join "secrets.nuon")
        let secrets = (open-state-record $secrets_path)
        assert equal $secrets.basic_auth.retained.username "retained-user"
        assert equal $secrets.basic_auth.retained.password "PASSWORD-SENTINEL"
        let expected_path = ($root | path join "expected-secrets")
        $secrets | to nuon | save $expected_path
        assert equal (open $secrets_path --raw) (open $expected_path --raw) "credential store serialization changed"

        rm $secrets_path
        api auth bearer set recreated RECREATED-CREDENTIAL-SENTINEL | ignore
        let recreated = (open-state-record $secrets_path)
        assert ("saml_tokens" in ($recreated | columns)) "recreated credential store lost the current default shape"
        assert-no-state-temps $root
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
    ]
}
