# Atomic replacement and fail-closed workspace state regressions.

use ../nu_modules/state-store.nu [open-state-record save-state-bytes]

def state-entries [root: string] {
    if not ($root | path exists) { return [] }
    ls -a $root | each {|entry|
        if $entry.type == "dir" {
            [$entry.name] | append (state-entries $entry.name)
        } else {
            [$entry.name]
        }
    } | flatten
}

def state-snapshot [root: string] {
    state-entries $root
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
    state-entries $root | where {|path|
        let name = ($path | path basename)
        $name =~ '^\..+\.nurl-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.tmp$'
    }
}

def assert-no-state-artifacts [root: string] {
    assert equal (state-temp-files $root) [] "workspace retained a state sibling temp"
    let forbidden = (
        state-entries $root
        | where {|path|
            let name = ($path | path basename)
            let entry_type = ($path | path type)
            (
                (($entry_type == "dir") and (
                    ($name == ".nurl-state")
                    or ($name =~ '^\.nurl-state-setup-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
                ))
                or (($entry_type == "file") and (
                    ($name =~ '^\.secured-v[0-9]+$')
                    or ($name =~ '^\..+\.create\.lock$')
                    or ($name =~ '^\..+\.nurl-create\.lock$')
                ))
            )
        }
    )
    assert equal $forbidden [] "workspace retained removed state architecture artifacts"
}

def setup-state-workspace [root: string] {
    $env.API_ROOT = $root
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
        {category: config, path: ($root | path join "config.nuon"), command: "api config get | ignore"}
        {category: variables, path: ($root | path join "variables.nuon"), command: "api vars list | ignore"}
        {category: credentials, path: ($root | path join "secrets.nuon"), command: "api auth list | ignore"}
        {category: collection, path: ($root | path join "collections" "durable" "collection.nuon"), command: "api collection show durable | ignore"}
        {category: metadata, path: ($root | path join "collections" "durable" "meta.nuon"), command: "api collection env list durable | ignore"}
        {category: environment, path: ($root | path join "collections" "durable" "environments" "dev.nuon"), command: "api collection env show durable dev | ignore"}
        {category: request, path: ($root | path join "collections" "durable" "requests" "ping.nuon"), command: "api request show ping --collection durable | ignore"}
        {category: chain, path: ($root | path join "chains" "durable.nuon"), command: "api chain show durable | ignore"}
    ]
}

def write-state-corruption [path: string, kind: string, category: string] {
    match $kind {
        syntax => { "{token: CREDENTIAL-SENTINEL" | save -f $path }
        shape => {
            if $category == "chain" { "42" | save -f $path } else { "[CREDENTIAL-SENTINEL]" | save -f $path }
        }
        binary => { 0x[ff fe 00 43 52 45 44] | save -f $path }
    }
}

def assert-state-read-failure [result: record, path: string, label: string] {
    assert ($result.exit_code != 0) $"($label) unexpectedly exited zero"
    assert equal ($result.stdout | str trim) "" $"($label) wrote stdout"
    assert equal $result.stderr ($result.stderr | ansi strip) $"($label) emitted ANSI stderr"
    assert ($result.stderr | str contains ($path | path basename)) $"($label) did not name the state path"
    assert ($result.stderr | str contains "recreate") $"($label) omitted recovery guidance"
    for leaked in ["CREDENTIAL-SENTINEL" "Unexpected end of code" "nu::parser" "nu::shell::outsidespan"] {
        assert (not ($result.stderr | str contains $leaked)) $"($label) leaked parser/content text: ($leaked)"
    }
}

def age-state-entry [path: string] {
    if $nu.os-info.name == "windows" {
        let script = if ($path | path type) == "dir" {
            "[System.IO.Directory]::SetLastWriteTimeUtc($env:NURL_AGE_PATH, [DateTime]::UtcNow.AddHours(-2))"
        } else {
            "[System.IO.File]::SetLastWriteTimeUtc($env:NURL_AGE_PATH, [DateTime]::UtcNow.AddHours(-2))"
        }
        let result = (test-complete-result (
            do { with-env {NURL_AGE_PATH: $path} { ^powershell.exe -NoProfile -NonInteractive -Command $script } }
            | complete
        ))
        assert equal $result.exit_code 0 $"could not age state fixture: ($result.stderr)"
    } else {
        let result = (test-complete-result (^touch -m -d "2 hours ago" $path | complete))
        assert equal $result.exit_code 0 $"could not age state fixture: ($result.stderr)"
    }
}

def test-state-atomic-bytes-and-symlink [] {
    let root = (make-temp-dir "state-bytes")
    let failure = try {
        for case in [
            {name: compact, serialized: ({alpha: 1 beta: two} | to nuon)}
            {name: indented, serialized: ({alpha: 1 nested: {beta: two}} | to nuon --indent 4)}
            {name: binary, serialized: 0x[00 ff 10 20 0a]}
        ] {
            let expected = ($root | path join $"expected-($case.name)")
            let actual = ($root | path join $"actual-($case.name)")
            $case.serialized | save $expected
            save-state-bytes $actual $case.serialized
            assert equal (open $actual --raw) (open $expected --raw) $"($case.name) serialized bytes changed"
        }

        if $nu.os-info.name != "windows" {
            let target = ($root | path join "target.nuon")
            let link = ($root | path join "link.nuon")
            {before: true} | to nuon | save $target
            ^ln -s $target $link
            save-state-bytes $link ({after: true} | to nuon)
            assert equal (open $target) {after: true} "symlink destination target was not replaced"
            assert equal (^test -L $link | complete | get exit_code) 0 "destination symlink was destroyed"
        }
        assert-no-state-artifacts $root
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null { error make {msg: $failure.msg} }
}

def test-state-stale-temp-cleanup [] {
    let root = (make-temp-dir "state-stale-temp")
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let aged = ($root | path join ".config.nuon.nurl-11111111-1111-1111-1111-111111111111.tmp")
        let fresh = ($root | path join ".config.nuon.nurl-22222222-2222-2222-2222-222222222222.tmp")
        let unrelated = ($root | path join ".variables.nuon.nurl-33333333-3333-3333-3333-333333333333.tmp")
        let near_temp = ($root | path join ".config.nuon.nurl-backup.tmp")
        "AGED-TEMP-SENTINEL" | save $aged
        "FRESH-TEMP-SENTINEL" | save $fresh
        "UNRELATED-TEMP-SENTINEL" | save $unrelated
        "NEAR-TEMP-SENTINEL" | save $near_temp
        age-state-entry $aged
        age-state-entry $unrelated
        age-state-entry $near_temp

        let removable_result = (run-command-process $root "api config set stale_cleanup one | ignore")
        assert equal $removable_result.exit_code 0 $"removable stale temp blocked config write: ($removable_result.stderr)"
        assert equal ($removable_result.stderr | str trim) "" "fresh/removable stale temps emitted a warning"
        assert ($removable_result.stdout | str contains "Config updated: stale_cleanup = one") "normal config success stdout changed"
        assert (not ($aged | path exists)) "aged exact-prefix sibling temp was not removed"
        assert equal (open $fresh --raw) "FRESH-TEMP-SENTINEL" "fresh exact-prefix sibling temp was removed"
        assert equal (open $unrelated --raw) "UNRELATED-TEMP-SENTINEL" "other-destination sibling temp was removed"
        assert equal (open $near_temp --raw) "NEAR-TEMP-SENTINEL" "non-UUID temp near-match was removed"

        let clean_root = ($root | path join "clean-reference")
        let clean_init = (run-command-process $clean_root "api init | ignore")
        assert equal $clean_init.exit_code 0 $"clean reference init failed: ($clean_init.stderr)"
        let clean_result = (run-command-process $clean_root "api auth bearer set blocked BLOCKED-WRITE-CREDENTIAL")
        assert equal $clean_result.exit_code 0 $"clean reference credential write failed: ($clean_result.stderr)"
        assert equal ($clean_result.stderr | str trim) "" "clean credential write emitted a warning"
        let expected_secrets = (open ($clean_root | path join "secrets.nuon") --raw)

        let blocked = ($root | path join ".secrets.nuon.nurl-44444444-4444-4444-4444-444444444444.tmp")
        let secrets = ($root | path join "secrets.nuon")
        let secrets_before = (open $secrets --raw)
        let lock = if $nu.os-info.name == "windows" {
            "BLOCKED-TEMP-CONTENT-SENTINEL" | save $blocked
            age-state-entry $blocked
            start-state-read-lock $root $blocked
        } else {
            mkdir $blocked
            "BLOCKED-TEMP-CONTENT-SENTINEL" | save ($blocked | path join "content")
            age-state-entry $blocked
            null
        }
        let blocked_result = (run-command-process $root "api auth bearer set blocked BLOCKED-WRITE-CREDENTIAL")
        let repeated_result = (run-command-process $root "api auth bearer set blocked BLOCKED-WRITE-CREDENTIAL")
        let config_result = (run-command-process $root "api config set stale_cleanup two | ignore")
        let vars_result = (run-command-process $root "api vars set unrelated exact | ignore")
        if $lock != null {
            stop-state-read-lock $lock
        }
        let warning = $"Warning: Could not remove stale state temp '($blocked)'; remove it manually."
        assert equal $blocked_result.exit_code 0 $"unremovable same-destination stale temp blocked the write: ($blocked_result.stderr)"
        assert equal $blocked_result.stdout $clean_result.stdout "stale temp changed successful write stdout"
        assert equal ($blocked_result.stderr | str trim) $warning $"stale temp warning changed: ($blocked_result.stderr | to nuon)"
        assert equal $repeated_result.exit_code 0 $"repeated stale warning write failed: ($repeated_result.stderr)"
        assert equal $repeated_result.stdout $clean_result.stdout "repeated stale warning changed success stdout"
        assert equal $repeated_result.stderr $blocked_result.stderr "stale warning wording changed across repeats"
        assert equal $blocked_result.stderr ($blocked_result.stderr | ansi strip) "stale temp warning emitted ANSI"
        for leaked in ["BLOCKED-TEMP-CONTENT-SENTINEL" "BLOCKED-WRITE-CREDENTIAL" "os error" "nu::" "originates from here"] {
            assert (not ($blocked_result.stderr | str contains $leaked)) $"stale temp warning leaked forbidden text: ($leaked)"
        }
        assert ((open $secrets --raw) != $secrets_before) "same-path credential rotation did not commit new bytes"
        assert equal (open $secrets --raw) $expected_secrets "stale temp changed committed credential bytes"
        assert equal (api auth bearer get blocked) BLOCKED-WRITE-CREDENTIAL "same-path credential rotation did not commit new content"
        assert equal $config_result.exit_code 0 $"secrets temp blocked config mutation: ($config_result.stderr)"
        assert equal $vars_result.exit_code 0 $"secrets temp blocked variables mutation: ($vars_result.stderr)"
        assert equal (open ($root | path join "config.nuon") | get stale_cleanup) two "unrelated config write did not complete"
        assert equal (open ($root | path join "variables.nuon") | get unrelated) exact "unrelated variables mutation did not complete"
        assert (not ($unrelated | path exists)) "variables mutation did not clean its own aged temp"
        let blocked_content = if $nu.os-info.name == "windows" {
            open $blocked --raw
        } else {
            open ($blocked | path join "content") --raw
        }
        assert equal $blocked_content "BLOCKED-TEMP-CONTENT-SENTINEL" "unremovable stale temp changed"
        if $nu.os-info.name == "windows" { rm -f $blocked } else { rm -rf $blocked }
        rm -f $fresh $near_temp
        cleanup $clean_root
        assert-no-state-artifacts $root
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null { error make {msg: $failure.msg} }
}

def start-state-read-lock [root: string, target: string] {
    let holder = ($root | path join "lock-holder.ps1")
    let launcher = ($root | path join "lock-launcher.ps1")
    let ready = ($root | path join "lock-ready.txt")
    "param($Target, $Ready)
$stream = [System.IO.File]::Open($Target, 'Open', 'Read', 'None')
try {
    [System.IO.File]::WriteAllText($Ready, 'ready')
    [System.Threading.ManualResetEvent]::new($false).WaitOne() | Out-Null
} finally { $stream.Dispose() }" | save $holder
    "param($Holder, $Target, $Ready)
$args = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('\"{0}\"' -f $Holder),('\"{0}\"' -f $Target),('\"{0}\"' -f $Ready))
$process = Start-Process powershell.exe -ArgumentList $args -PassThru -WindowStyle Hidden
if (-not [System.Threading.SpinWait]::SpinUntil({ Test-Path -LiteralPath $Ready }, 10000)) {
    Stop-Process -Id $process.Id -Force
    throw 'lock barrier failed'
}
$process.Id" | save $launcher
    let result = (test-complete-result (
        ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcher $holder $target $ready
        | complete
    ))
    assert equal $result.exit_code 0 $"file lock failed: ($result.stderr)"
    {pid: ($result.stdout | str trim | into int)}
}

def stop-state-read-lock [lock: record] {
    let result = (test-complete-result (
        ^powershell.exe -NoProfile -NonInteractive -Command (
            "Stop-Process -Id " + ($lock.pid | into string) + " -Force -ErrorAction SilentlyContinue"
        )
        | complete
    ))
    assert equal $result.exit_code 0 $"file lock release failed: ($result.stderr)"
}

def test-state-failed-replacement-preserves-original [] {
    let root = (make-temp-dir "state-failure")
    let failure = try {
        $env.API_ROOT = $root
        setup-state-workspace $root
        let path = ($root | path join "secrets.nuon")
        let before = (open $path --raw)
        if $nu.os-info.name == "windows" {
            let lock = (start-state-read-lock $root $path)
            let result = (run-command-process $root "api auth bearer set interrupted NEW-CREDENTIAL-SENTINEL")
            stop-state-read-lock $lock
            assert ($result.exit_code != 0) "locked replacement exited zero"
            assert equal ($result.stdout | str trim) "" "locked replacement wrote stdout"
            assert (not ($result.stderr | str contains "NEW-CREDENTIAL-SENTINEL")) "locked replacement leaked credential"
        } else {
            ^chmod 500 $root
            let result = (run-command-process $root "api auth bearer set interrupted NEW-CREDENTIAL-SENTINEL")
            ^chmod 700 $root
            assert ($result.exit_code != 0) "read-only parent replacement exited zero"
            assert equal ($result.stdout | str trim) "" "read-only parent replacement wrote stdout"
        }
        assert equal (open $path --raw) $before "failed replacement changed original bytes"
        assert equal (api auth bearer get durable) "CREDENTIAL-SENTINEL"
        assert-no-state-artifacts $root
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null { error make {msg: $failure.msg} }
}

def test-state-corruption-contracts [] {
    let root = (make-temp-dir "state-corruption")
    let failure = try {
        $env.API_ROOT = $root
        setup-state-workspace $root
        for category in (state-category-cases $root) {
            let valid = (open $category.path --raw)
            for kind in [syntax shape binary] {
                write-state-corruption $category.path $kind $category.category
                assert-state-read-failure (run-command-process $root $category.command) $category.path $"($category.category)/($kind)"
                $valid | save -f $category.path
            }
        }
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null { error make {msg: $failure.msg} }
}

def test-state-partial-new-file-recovery [] {
    let root = (make-temp-dir "state-partial-create")
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let chains_dir = ($root | path join "chains")
        mkdir $chains_dir
        let path = ($chains_dir | path join "interrupted.nuon")
        if $nu.os-info.name == "windows" {
            save-state-bytes $path "{name: PARTIAL-PUBLIC-SENTINEL, steps: [" --no-clobber
        } else {
            let payload = ($root | path join "partial-payload.txt")
            let child = ($root | path join "partial-child.nu")
            let launcher = ($root | path join "partial-launcher.sh")
            let observed_size = ($root | path join "partial-size.txt")
            let stdout = ($root | path join "partial.stdout")
            let stderr = ($root | path join "partial.stderr")
            let module = ($env.NURL_REPO_ROOT | path join "nu_modules" "mod.nu")
            let payload_size = 16777216
            let generator = ($root | path join "partial-payload.sh")
            ("#!/usr/bin/env bash\nset -e\nprintf 'PARTIAL-PUBLIC-SENTINEL-' > \"$1\"\nhead -c "
                + ($payload_size | into string)
                + " /dev/zero | tr '\\000' 'P' >> \"$1\""
            ) | save $generator
            let generated = (test-complete-result (^bash $generator $payload | complete))
            assert equal $generated.exit_code 0 $"large partial-create payload failed: ($generated.stderr)"
            [
                $"use ($module | to nuon) *"
                $"$env.API_ROOT = ($root | to nuon)"
                ("let description = (open " + ($payload | to nuon) + " --raw)")
                "api chain create interrupted --description $description | ignore"
            ] | str join "\n" | save $child
            ("#!/usr/bin/env bash\nset -e\nset +e\n(ulimit -f 2048; exec \""
                + $nu.current-exe
                + "\" --no-config-file \""
                + $child
                + "\" >\""
                + $stdout
                + "\" 2>\""
                + $stderr
                + "\")\nstatus=$?\nset -e\n"
                + "if [ \"$status\" -eq 0 ]; then echo 'public create unexpectedly completed' >&2; exit 1; fi\n"
                + "if [ ! -f \""
                + $path
                + "\" ]; then echo 'public create left no destination' >&2; exit 1; fi\n"
                + "size=$(stat -c %s \""
                + $path
                + "\")\n"
                + "if [ \"$size\" -le 0 ] || [ \"$size\" -ge "
                + ($payload_size | into string)
                + " ]; then echo \"unexpected partial size: $size\" >&2; exit 1; fi\n"
                + "printf '%s' \"$size\" > \""
                + $observed_size
                + "\""
            ) | save $launcher
            let interrupted = (test-complete-result (^bash $launcher | complete))
            assert equal $interrupted.exit_code 0 $"public create interruption failed: ($interrupted.stderr)"
            let child_stderr = (open $stderr --raw)
            assert (not ($child_stderr | str contains "already exists")) "interrupted create I/O failure was mislabeled as a duplicate"
            let barrier_size = (open $observed_size --raw | into int)
            let partial_size = (ls $path | get size | first | into int)
            assert ($barrier_size > 0) "public create was terminated before writing bytes"
            assert equal $partial_size $barrier_size "partial destination changed after termination"
            assert ($partial_size < $payload_size) "public create completed instead of leaving a partial new file"
        }

        let result = (run-command-process $root "api chain show interrupted | ignore")
        assert-state-read-failure $result $path "interrupted public new-file create"
        assert (not ($result.stderr | str contains "PARTIAL-PUBLIC-SENTINEL")) "interrupted public create leaked payload"
        assert-no-state-artifacts $root
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null { error make {msg: $failure.msg} }
}

def test-history-config-corruption-contracts [] {
    let root = (make-temp-dir "state-history-config")
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let path = ($root | path join "config.nuon")
        "{credential: HISTORY-CONFIG-SENTINEL" | save -f $path
        for command in [
            "api history save {method: GET, url: 'https://example.invalid', headers: {}, body: null} {status: 200, status_text: OK, headers: {}, body: null, time_ms: 1, size_bytes: 0} | ignore"
            "api history clear --force"
        ] {
            let result = (run-command-process $root $command)
            assert-state-read-failure $result $path $command
            assert (not ($result.stderr | str contains "HISTORY-CONFIG-SENTINEL")) "history config leaked bytes"
        }
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null { error make {msg: $failure.msg} }
}

def test-state-no-clobber-and-io [] {
    let root = (make-temp-dir "state-no-clobber")
    let failure = try {
        $env.API_ROOT = $root
        setup-state-workspace $root
        let config_path = ($root | path join "config.nuon")
        if $nu.os-info.name == "windows" {
            let lock = (start-state-read-lock $root $config_path)
            let unreadable = (run-command-process $root "api config get | ignore")
            stop-state-read-lock $lock
            assert ($unreadable.exit_code != 0) "unreadable config exited zero"
            assert (not ($unreadable.stderr | str contains "invalid or does not contain")) "I/O error mislabeled as NUON"
        }

        let cases = [
            {command: "api chain create durable", expected: "Chain 'durable' already exists"}
            {command: "api request create ping GET 'https://example.invalid' --collection durable", expected: "Destination file already exists"}
            {command: "api collection env create durable dev", expected: "Environment 'dev' already exists in collection 'durable'"}
        ]
        let before = (state-snapshot $root)
        for case in $cases {
            let result = (run-command-process $root $case.command)
            assert ($result.exit_code != 0) $"duplicate exited zero: ($case.command)"
            assert equal ($result.stdout | str trim) ""
            assert ($result.stderr | str contains $case.expected) $"duplicate message changed: ($result.stderr)"
        }
        assert equal (state-snapshot $root) $before "duplicate create changed state"

        # Removed lock/marker artifacts are irrelevant and never mutated.
        let legacy = ($root | path join "chains" ".blocked.nuon.nurl-create.lock")
        "FOREIGN-OWNER-TOKEN" | save $legacy
        let legacy_before = (open $legacy --raw)
        api chain create artifact-irrelevant | ignore
        assert equal (open $legacy --raw) $legacy_before "Nurl touched irrelevant legacy artifact"
        assert (($root | path join "chains" "artifact-irrelevant.nuon") | path exists)
        rm -f $legacy
        assert-no-state-artifacts $root
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null { error make {msg: $failure.msg} }
}

def test-state-read-only-and-credentials [] {
    let root = (make-temp-dir "state-read-only")
    let failure = try {
        $env.API_ROOT = $root
        setup-state-workspace $root
        api auth basic set retained retained-user PASSWORD-SENTINEL | ignore
        api auth bearer set second SECOND-CREDENTIAL-SENTINEL | ignore
        let secrets = ($root | path join "secrets.nuon")
        let mode_policy = if $nu.os-info.name == "windows" {
            null
        } else {
            ^chmod 600 $secrets
            let old_mode = (^stat -c "%a" $secrets | str trim)
            let control = ($root | path join "posix-policy-control.tmp")
            "control" | save $control
            let control_mode = (^stat -c "%a" $control | str trim)
            assert ($old_mode != $control_mode) "custom POSIX mode fixture did not differ from directory policy"
            {control: $control, expected: $control_mode}
        }
        api auth bearer set mode-check MODE-CHECK-SENTINEL | ignore
        if $mode_policy != null {
            assert equal (^stat -c "%a" $secrets | str trim) $mode_policy.expected "published replacement did not inherit POSIX directory policy"
            rm -f $mode_policy.control
        }
        let before = (state-snapshot $root)
        for command in [
            "api status | ignore"
            "api config get | ignore"
            "api vars list | ignore"
            "api collection show durable | ignore"
            "api collection env show durable dev | ignore"
            "api request list --collection durable | ignore"
            "api auth list | ignore"
            "api chain list | ignore"
        ] {
            let result = (run-command-process $root $command)
            assert equal $result.exit_code 0 $"read-only command failed: ($command): ($result.stderr)"
        }
        assert equal (state-snapshot $root) $before "read-only commands changed bytes"
        rm $secrets
        api auth bearer set recreated RECREATED-CREDENTIAL-SENTINEL | ignore
        assert equal (open-state-record $secrets | columns) [tokens saml_tokens oauth api_keys basic_auth]
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null { error make {msg: $failure.msg} }
}

def test-state-fresh-pathless-lifecycle [] {
    let root = (make-temp-dir "state-pathless")
    let failure = try {
        $env.API_ROOT = $root
        let command = [
            "with-env {PATH: ''} {"
            "api init | ignore"
            "api config set pathless true | ignore"
            "api auth bearer set pathless PATHLESS-SENTINEL | ignore"
            "api collection create pathless | ignore"
            "api collection env create pathless active --activate | ignore"
            "api collection env set pathless value exact --target active | ignore"
            "api request create ping GET 'https://example.invalid' --collection pathless | ignore"
            "api chain create pathless | ignore"
            "}"
        ] | str join "\n"
        let result = (run-command-process $root $command)
        assert equal $result.exit_code 0 $"fresh PATH-empty lifecycle failed: ($result.stderr)"
        assert equal ($result.stderr | str trim) "" $"fresh PATH-empty lifecycle emitted a raw frame: ($result.stderr)"
        assert equal (api auth bearer get pathless) PATHLESS-SENTINEL
        assert equal (api collection env show pathless active | get variables | first | get value) exact
        assert-no-state-artifacts $root
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null { error make {msg: $failure.msg} }
}

def test-state-production-architecture-removed [] {
    let modules = ($env.NURL_REPO_ROOT | path join "nu_modules")
    let state_source = (open ($modules | path join "state-store.nu") --raw)
    for forbidden in [
        "powershell"
        "pwsh"
        "icacls"
        "STATE_LOCK"
        "NURL_TEST_STATE_STORE"
        "path expand --no-symlink"
        ".nurl-state"
        ".secured-v"
        "create-lock"
        "^stat"
        "^chmod"
        "^ln"
        "^mv"
    ] {
        assert (not ($state_source | str contains $forbidden)) $"production state store retained forbidden external pattern '($forbidden)'"
    }

    let production_source = (
        ["state-store.nu" "mod.nu" "auth.nu" "vars.nu" "http.nu" "chain.nu"]
        | each {|name| open ($modules | path join $name) --raw }
        | str join "\n"
    )
    for retired in [
        "initialize-state-store"
        "state-store-ready"
        "state-temp-dir"
        "create-lock"
        "release-create-lock"
    ] {
        assert (not ($production_source | str contains $retired)) $"production modules retained removed architecture symbol '($retired)'"
    }
}

def windows-short-path [path: string] {
    let script = "Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
using System.Text;
public static class NurlShortPath {
  [DllImport(\"kernel32.dll\", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern uint GetShortPathName(string path, StringBuilder output, int length);
  public static string Get(string path) {
    var output = new StringBuilder(32768);
    if (GetShortPathName(path, output, output.Capacity) == 0) throw new System.ComponentModel.Win32Exception();
    return output.ToString();
  }
}
'@
[NurlShortPath]::Get($env:NURL_LONG_PATH)"
    let result = (test-complete-result (
        do { with-env {NURL_LONG_PATH: $path} { ^powershell.exe -NoProfile -NonInteractive -Command $script } }
        | complete
    ))
    assert equal $result.exit_code 0 $"short path resolution failed: ($result.stderr)"
    $result.stdout | str trim
}

def test-windows-short-path-lifecycle [] {
    if $nu.os-info.name != "windows" { return }
    let root = (make-temp-dir "state short alias")
    let failure = try {
        let short_root = (windows-short-path $root | str replace -r '^C:' 'c:')
        $env.API_ROOT = $short_root
        api init | ignore
        api config set short_alias true | ignore
        api auth bearer set short-alias SHORT-ALIAS-SENTINEL | ignore
        api collection create short-alias | ignore
        api collection env create short-alias active --activate | ignore
        api collection env set short-alias value exact --target active | ignore
        api request create ping GET "https://example.invalid" --collection short-alias | ignore
        api chain create short-alias | ignore
        assert equal (open ($root | path join "config.nuon") | get short_alias) true
        assert equal (api auth bearer get short-alias) SHORT-ALIAS-SENTINEL
        assert (($root | path join "collections" "short-alias" "requests" "ping.nuon") | path exists)
        assert (($root | path join "chains" "short-alias.nuon") | path exists)
        assert-no-state-artifacts $root
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null { error make {msg: $failure.msg} }
}

def test-posix-symlinked-ancestor-lifecycle [] {
    if $nu.os-info.name == "windows" { return }
    let target_parent = (make-temp-dir "state-link-target")
    let parent = (make-temp-dir "state-link-parent")
    let target = ($target_parent | path join "workspace")
    let link = ($parent | path join "alias")
    let workspace = ($link | path join "workspace")
    let failure = try {
        mkdir $target
        ^ln -s $target_parent $link
        $env.API_ROOT = $workspace
        api init | ignore
        api config set linked true | ignore
        api vars set linked exact | ignore
        api auth bearer set linked LINKED-SENTINEL | ignore
        api collection create linked | ignore
        api collection env create linked active --activate | ignore
        api request create ping GET "https://example.invalid" --collection linked | ignore
        api chain create linked | ignore
        assert equal (open ($target | path join "config.nuon") | get linked) true
        assert equal (api auth bearer get linked) LINKED-SENTINEL
        assert (($target | path join "collections" "linked" "requests" "ping.nuon") | path exists)
        assert (($target | path join "chains" "linked.nuon") | path exists)
        assert equal (do { ^test -L $link } | complete | get exit_code) 0 "workspace ancestor symlink was replaced"
        assert ((do { ^test -L $workspace } | complete | get exit_code) != 0) "workspace leaf unexpectedly became a symlink"
        assert-no-state-artifacts $target
        null
    } catch {|error| $error}
    cleanup $parent
    cleanup $target_parent
    if $failure != null { error make {msg: $failure.msg} }
}

def test-state-concurrent-no-clobber [] {
    let root = (make-temp-dir "state-race")
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let module = ($env.NURL_REPO_ROOT | path join "nu_modules" "mod.nu")
        for iteration in 1..20 {
            let release = ($root | path join $"release-($iteration).txt")
            let launcher = if $nu.os-info.name == "windows" {
                $root | path join $"launcher-($iteration).ps1"
            } else {
                $root | path join $"launcher-($iteration).sh"
            }
            mut children = []
            for index in 1..8 {
                let script = ($root | path join $"child-($iteration)-($index).nu")
                let result = ($root | path join $"result-($iteration)-($index).nuon")
                let stdout = ($root | path join $"child-($iteration)-($index).stdout")
                let stderr = ($root | path join $"child-($iteration)-($index).stderr")
                let description = $"winner-($iteration)-($index)"
                [
                    $"use ($module | to nuon) *"
                    $"$env.API_ROOT = ($root | to nuon)"
                    $"let release = ($release | to nuon)"
                    "while not ($release | path exists) {}"
                    ("let outcome = try { api chain create "
                        + $"race-($iteration)"
                        + " --description "
                        + ($description | to nuon)
                        + "; {status: success, error: ''} } catch {|error| {status: failure, error: $error.msg}}")
                    $"$outcome | to nuon | save ($result | to nuon)"
                ] | str join "\n" | save $script
                $children = ($children | append {
                    script: $script
                    result: $result
                    stdout: $stdout
                    stderr: $stderr
                    description: $description
                })
            }
            let launched = if $nu.os-info.name == "windows" {
                mut start_lines = []
                for child in $children {
                    $start_lines = ($start_lines | append (
                        "$processes += Start-Process -FilePath $Nu -ArgumentList @('--no-config-file', "
                        + ($child.script | to nuon)
                        + ") -PassThru -RedirectStandardOutput "
                        + ($child.stdout | to nuon)
                        + " -RedirectStandardError "
                        + ($child.stderr | to nuon)
                    ))
                }
                let starts = ($start_lines | str join "\n")
                ("param($Nu, $Release)\n$processes = @()\n"
                    + $starts
                    + "\n[System.IO.File]::WriteAllText($Release, 'release')\n"
                    + "$deadline=[DateTime]::UtcNow.AddSeconds(120)\n"
                    + "try {\n"
                    + "  foreach($process in $processes){\n"
                    + "    $remaining=[Math]::Max(0,[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds)\n"
                    + "    if($remaining -eq 0 -or -not $process.WaitForExit($remaining)){throw \"race child $($process.Id) timed out\"}\n"
                    + "    $process.WaitForExit()\n"
                    + "  }\n"
                    + "} finally {\n"
                    + "  $processes | Where-Object {-not $_.HasExited} | ForEach-Object {Stop-Process -Id $_.Id -Force}\n"
                    + "}"
                ) | save $launcher
                test-complete-result (
                    ^powershell.exe -NoProfile -NonInteractive -File $launcher $nu.current-exe $release
                    | complete
                )
            } else {
                mut start_lines = []
                for child in $children {
                    $start_lines = ($start_lines | append (
                        "timeout 120s \""
                        + $nu.current-exe
                        + "\" --no-config-file \""
                        + $child.script
                        + "\" >\""
                        + $child.stdout
                        + "\" 2>\""
                        + $child.stderr
                        + "\" &\npids+=(\"$!\")"
                    ))
                }
                let starts = ($start_lines | str join "\n")
                ("#!/usr/bin/env bash\nset -e\npids=()\n"
                    + $starts
                    + "\nprintf 'release' > \""
                    + $release
                    + "\"\nstatus=0\nfor pid in \"${pids[@]}\"; do wait \"$pid\" || status=1; done\nexit $status"
                ) | save $launcher
                test-complete-result (^bash $launcher | complete)
            }
            assert equal $launched.exit_code 0 $"race launcher failed: ($launched.stderr)"
            mut outcomes = []
            for child in $children {
                let outcome = (open $child.result --raw | from nuon)
                $outcomes = ($outcomes | append ($outcome | insert description $child.description))
            }
            mut winner_count = 0
            mut loser_count = 0
            mut winner_description = ""
            for outcome in $outcomes {
                if $outcome.status == "success" {
                    $winner_count = $winner_count + 1
                    $winner_description = $outcome.description
                } else if $outcome.status == "failure" {
                    $loser_count = $loser_count + 1
                    assert ($outcome.error | str contains $"Chain 'race-($iteration)' already exists") $"race duplicate message changed: ($outcome.error)"
                }
            }
            assert equal $winner_count 1 $"race winner count changed: ($outcomes)"
            assert equal $loser_count 7 $"race loser count changed: ($outcomes)"
            let persisted = (open-state-record ($root | path join "chains" $"race-($iteration).nuon"))
            assert equal $persisted.description $winner_description "race final bytes did not belong to sole winner"
            assert-no-state-artifacts $root
        }
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null { error make {msg: $failure.msg} }
}

def test-state-concurrent-first-init [] {
    let root = (make-temp-dir "state-first-init")
    let failure = try {
        let module = ($env.NURL_REPO_ROOT | path join "nu_modules" "mod.nu")
        let release = ($root | path join "release.txt")
        let launcher = if $nu.os-info.name == "windows" {
            $root | path join "launcher.ps1"
        } else {
            $root | path join "launcher.sh"
        }
        mut children = []
        for index in 1..8 {
            let script = ($root | path join $"child-($index).nu")
            let result = ($root | path join $"result-($index).nuon")
            let stdout = ($root | path join $"child-($index).stdout")
            let stderr = ($root | path join $"child-($index).stderr")
            [
                $"use ($module | to nuon) *"
                $"$env.API_ROOT = ($root | to nuon)"
                $"let release = ($release | to nuon)"
                "while not ($release | path exists) {}"
                "let outcome = try { api init | ignore; {status: success, error: ''} } catch {|error| {status: failure, error: $error.msg}}"
                $"$outcome | to nuon | save ($result | to nuon)"
            ] | str join "\n" | save $script
            $children = ($children | append {
                script: $script
                result: $result
                stdout: $stdout
                stderr: $stderr
            })
        }

        let launched = if $nu.os-info.name == "windows" {
            mut starts = []
            for child in $children {
                $starts = ($starts | append (
                    "$processes += Start-Process -FilePath $Nu -ArgumentList @('--no-config-file', "
                    + ($child.script | to nuon)
                    + ") -PassThru -RedirectStandardOutput "
                    + ($child.stdout | to nuon)
                    + " -RedirectStandardError "
                    + ($child.stderr | to nuon)
                ))
            }
            ("param($Nu,$Release)\n$processes=@()\n"
                + ($starts | str join "\n")
                + "\n[System.IO.File]::WriteAllText($Release,'release')\n"
                + "$deadline=[DateTime]::UtcNow.AddSeconds(120)\n"
                + "try { foreach($process in $processes){ $remaining=[Math]::Max(0,[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds); if($remaining -eq 0 -or -not $process.WaitForExit($remaining)){throw \"init child $($process.Id) timed out\"}; $process.WaitForExit() } }\n"
                + "finally { $processes | Where-Object {-not $_.HasExited} | ForEach-Object {Stop-Process -Id $_.Id -Force} }"
            ) | save $launcher
            test-complete-result (
                ^powershell.exe -NoProfile -NonInteractive -File $launcher $nu.current-exe $release
                | complete
            )
        } else {
            mut starts = []
            for child in $children {
                $starts = ($starts | append (
                    "timeout 120s \""
                    + $nu.current-exe
                    + "\" --no-config-file \""
                    + $child.script
                    + "\" >\""
                    + $child.stdout
                    + "\" 2>\""
                    + $child.stderr
                    + "\" &\npids+=(\"$!\")"
                ))
            }
            ("#!/usr/bin/env bash\nset -e\npids=()\n"
                + ($starts | str join "\n")
                + "\nprintf release > \""
                + $release
                + "\"\nstatus=0\nfor pid in \"${pids[@]}\"; do wait \"$pid\" || status=1; done\nexit $status"
            ) | save $launcher
            test-complete-result (^bash $launcher | complete)
        }
        assert equal $launched.exit_code 0 $"concurrent init launcher failed: ($launched.stderr)"
        mut successes = 0
        for child in $children {
            let outcome = (open $child.result --raw | from nuon)
            if $outcome.status == success {
                $successes = $successes + 1
            } else {
                assert ($outcome.error | str contains "Destination file") $"concurrent first init returned the wrong failure: ($outcome.error)"
                assert ($outcome.error | str contains "already exists") $"concurrent first init duplicate message changed: ($outcome.error)"
            }
        }
        assert ($successes >= 1) "concurrent first init had no successful initializer"
        open-state-record ($root | path join "config.nuon") | ignore
        open-state-record ($root | path join "variables.nuon") | ignore
        open-state-record ($root | path join "secrets.nuon") | ignore
        assert-no-state-artifacts $root
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null { error make {msg: $failure.msg} }
}

def normalize-windows-dacl [sddl: string] {
    $sddl
    | parse --regex '\((?<ace>[^)]+)\)'
    | get ace
    | each {|ace| $ace | str replace ";ID;" ";;" }
    | sort
}

def windows-file-sddl [path: string] {
    let script = "$acl = [System.IO.File]::GetAccessControl($env:NURL_DACL_PATH)
$acl.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All)"
    let result = (test-complete-result (
        do { with-env {NURL_DACL_PATH: $path} { ^powershell.exe -NoProfile -NonInteractive -Command $script } }
        | complete
    ))
    assert equal $result.exit_code 0 $"DACL inspection failed: ($result.stderr)"
    $result.stdout | str trim
}

def test-windows-sibling-and-final-dacl [] {
    if $nu.os-info.name != "windows" { return }
    let root = (make-temp-dir "state-dacl")
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let secrets = ($root | path join "secrets.nuon")
        let old_harden = "$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = [System.Security.AccessControl.FileSecurity]::new()
$acl.SetOwner($sid)
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
$system = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($system, 'Read', 'Allow'))
[System.IO.File]::SetAccessControl($env:NURL_DACL_PATH, $acl)"
        let hardened = (test-complete-result (
            do { with-env {NURL_DACL_PATH: $secrets} { ^powershell.exe -NoProfile -NonInteractive -Command $old_harden } }
            | complete
        ))
        assert equal $hardened.exit_code 0 $"custom DACL fixture failed: ($hardened.stderr)"
        let old_sddl = (windows-file-sddl $secrets)

        let child = ($root | path join "dacl-child.nu")
        let watcher = ($root | path join "dacl-watcher.ps1")
        let token_file = ($root | path join "large-token.txt")
        let result_file = ($root | path join "dacl-result.json")
        let stdout = ($root | path join "child.stdout")
        let stderr = ($root | path join "child.stderr")
        let module = ($env.NURL_REPO_ROOT | path join "nu_modules" "mod.nu")
        [
            $"use ($module | to nuon) *"
            $"$env.API_ROOT = ($root | to nuon)"
            ("let token = (open " + ($token_file | to nuon) + " --raw)")
            "api auth bearer set dacl-live $token | ignore"
        ] | str join "\n" | save $child
        "param($Root,$Nu,$Child,$Token,$Result,$Stdout,$Stderr)
$ErrorActionPreference='Stop'
$filter='.secrets.nuon.nurl-*.tmp'
$watcher=[System.IO.FileSystemWatcher]::new($Root,$filter)
$watcher.NotifyFilter=[System.IO.NotifyFilters]::FileName
$watcher.EnableRaisingEvents=$true
[System.IO.File]::WriteAllText($Token,('X'*134217728))
$process=Start-Process $Nu -ArgumentList @('--no-config-file',$Child) -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
$change=$watcher.WaitForChanged([System.IO.WatcherChangeTypes]::Created,60000)
if($change.TimedOut){$watcher.Dispose(); if(-not $process.HasExited){Stop-Process -Id $process.Id -Force}; throw 'temp event timed out'}
$temp=Join-Path $Root $change.Name
$deadline=[DateTime]::UtcNow.AddSeconds(30)
$tempSddl=$null
while($null -eq $tempSddl -and [DateTime]::UtcNow -lt $deadline){
  try{$tempSddl=[System.IO.File]::GetAccessControl($temp).GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All)}
  catch{Start-Sleep -Milliseconds 2}
}
$watcher.Dispose()
if($null -eq $tempSddl){if(-not $process.HasExited){Stop-Process -Id $process.Id -Force}; throw 'temp ACL unavailable'}
$control=Join-Path $Root 'directory-policy-control.tmp'
[System.IO.File]::WriteAllText($control,'')
$controlSddl=[System.IO.File]::GetAccessControl($control).GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All)
$process.WaitForExit()
[System.IO.File]::WriteAllText($Result,(@{temp=$tempSddl;control=$controlSddl}|ConvertTo-Json -Compress))" | save $watcher
        let watched = (test-complete-result (
            ^powershell.exe -NoProfile -NonInteractive -File $watcher $root $nu.current-exe $child $token_file $result_file $stdout $stderr
            | complete
        ))
        assert equal $watched.exit_code 0 $"DACL watcher failed: ($watched.stderr)"
        let result = (open $result_file)
        let control_path = ($root | path join "directory-policy-control.tmp")
        let inherited_control_sddl = (windows-file-sddl $control_path)
        assert equal (normalize-windows-dacl $result.temp) (normalize-windows-dacl $inherited_control_sddl) "live sibling temp did not inherit destination-directory DACL"
        let final_sddl = (windows-file-sddl $secrets)
        assert ((normalize-windows-dacl $old_sddl) != (normalize-windows-dacl $inherited_control_sddl)) "custom file DACL fixture did not differ"
        assert equal (normalize-windows-dacl $final_sddl) (normalize-windows-dacl $inherited_control_sddl) "published replacement did not inherit directory DACL"
        rm -f $control_path
        assert-no-state-artifacts $root
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null { error make {msg: $failure.msg} }
}

def test-collection-copy-has-no-state-artifacts [] {
    let root = (make-temp-dir "state-copy")
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        api config set lifecycle true | ignore
        api vars set lifecycle exact | ignore
        api auth bearer set lifecycle LIFECYCLE-SENTINEL | ignore
        api collection create source | ignore
        api collection env create source active --activate | ignore
        api request create ping GET "https://example.invalid" --collection source | ignore
        api request update ping --method POST --collection source | ignore
        api chain create lifecycle | ignore
        let source = ($root | path join "collections" "source")
        let retired_dir = ($source | path join ".nurl-state")
        let setup_dir = ($source | path join ".nurl-state-setup-11111111-1111-1111-1111-111111111111")
        let request_lock = ($source | path join "requests" ".ping.nuon.create.lock")
        let legacy_lock = ($source | path join ".source.nuon.nurl-create.lock")
        let sibling_temp = ($source | path join "requests" ".ping.nuon.nurl-22222222-2222-2222-2222-222222222222.tmp")
        let hidden_user_file = ($source | path join ".user-metadata")
        let near_marker = ($source | path join ".secured-video")
        let near_lock = ($source | path join "database.create.lock")
        let near_temp = ($source | path join ".notes.nurl-backup.tmp")
        let near_lock_dir = ($source | path join ".cache.create.lock")
        mkdir $retired_dir $setup_dir
        "FORGED-MARKER-SENTINEL" | save ($retired_dir | path join ".secured-v1")
        "SETUP-SENTINEL" | save ($setup_dir | path join "owner")
        "REQUEST-LOCK-SENTINEL" | save $request_lock
        "LEGACY-LOCK-SENTINEL" | save $legacy_lock
        "ORPHAN-TEMP-SENTINEL" | save $sibling_temp
        "USER-HIDDEN-SENTINEL" | save $hidden_user_file
        "NEAR-MARKER-SENTINEL" | save $near_marker
        "NEAR-LOCK-SENTINEL" | save $near_lock
        "NEAR-TEMP-SENTINEL" | save $near_temp
        mkdir $near_lock_dir
        "NEAR-LOCK-DIR-SENTINEL" | save ($near_lock_dir | path join "content")
        let source_env = ($source | path join "environments" "active.nuon")
        let source_request = ($source | path join "requests" "ping.nuon")
        let source_meta = ($source | path join "meta.nuon")
        let source_env_bytes = (open $source_env --raw)
        let source_request_bytes = (open $source_request --raw)
        let source_meta_bytes = (open $source_meta --raw)
        let source_artifacts = (
            [$retired_dir $setup_dir $request_lock $legacy_lock $sibling_temp]
            | each {|path|
                if ($path | path type) == "dir" {
                    state-entries $path | each {|child| {path: $child, bytes: (open $child --raw)}}
                } else {
                    [{path: $path, bytes: (open $path --raw)}]
                }
            }
            | flatten
        )
        api collection copy source copied | ignore
        let copied = ($root | path join "collections" "copied")
        for artifact in $source_artifacts {
            assert ($artifact.path | path exists) $"collection copy deleted source artifact: ($artifact.path)"
            assert equal (open $artifact.path --raw) $artifact.bytes $"collection copy changed source artifact: ($artifact.path)"
        }
        assert-no-state-artifacts $copied
        assert equal (open ($copied | path join "environments" "active.nuon") --raw) $source_env_bytes "collection copy changed environment bytes"
        assert equal (open ($copied | path join "requests" "ping.nuon") --raw) $source_request_bytes "collection copy changed nested request bytes"
        assert equal (open ($copied | path join "meta.nuon") --raw) $source_meta_bytes "collection copy changed meta bytes"
        assert equal (open ($copied | path join ".user-metadata") --raw) "USER-HIDDEN-SENTINEL" "collection copy dropped unrelated hidden user data"
        assert equal (open ($copied | path join ".secured-video") --raw) "NEAR-MARKER-SENTINEL" "collection copy removed a marker near-match"
        assert equal (open ($copied | path join "database.create.lock") --raw) "NEAR-LOCK-SENTINEL" "collection copy removed a lock near-match"
        assert equal (open ($copied | path join ".notes.nurl-backup.tmp") --raw) "NEAR-TEMP-SENTINEL" "collection copy removed a temp near-match"
        assert equal (open ($copied | path join ".cache.create.lock" "content") --raw) "NEAR-LOCK-DIR-SENTINEL" "collection copy removed a lock-shaped directory"
        assert equal (api request show ping --collection copied | get method) POST "copied nested request is not readable"
        rm -rf $retired_dir $setup_dir
        rm -f $request_lock $legacy_lock $sibling_temp $hidden_user_file $near_marker $near_lock $near_temp
        rm -rf $near_lock_dir
        assert-no-state-artifacts $root

        let bundled = ($env.NURL_REPO_ROOT | path join "collections" "jsonplaceholder")
        let bundled_before = (state-snapshot $bundled)
        let bundled_copy = ($root | path join "collections" "jsonplaceholder")
        cp -r $bundled $bundled_copy
        api collection copy jsonplaceholder jsonplaceholder-copy | ignore
        assert equal (state-snapshot $bundled) $bundled_before "using bundled jsonplaceholder changed tracked source bytes"
        assert-no-state-artifacts ($root | path join "collections" "jsonplaceholder-copy")
        null
    } catch {|error| $error}
    cleanup $root
    if $failure != null { error make {msg: $failure.msg} }
}

export def run-suite-state-durability []: nothing -> list<record> {
    print "\nState durability"
    [
        (run-test "replacement preserves exact serialized bytes and symlink targets" { test-state-atomic-bytes-and-symlink })
        (run-test "later same-path writes clean only aged sibling temps" { test-state-stale-temp-cleanup })
        (run-test "genuine replacement failures preserve original bytes and clean temps" { test-state-failed-replacement-preserves-original })
        (run-test "all state categories reject syntax, shape, and binary corruption cleanly" { test-state-corruption-contracts })
        (run-test "partial new files fail closed through public readers" { test-state-partial-new-file-recovery })
        (run-test "history config readers use fail-closed state errors" { test-history-config-corruption-contracts })
        (run-test "I/O and duplicate-create contracts remain stable" { test-state-no-clobber-and-io })
        (run-test "read-only state is byte-stable and credentials preserve order/mode" { test-state-read-only-and-credentials })
        (run-test "fresh PATH-empty lifecycle uses no external state commands" { test-state-fresh-pathless-lifecycle })
        (run-test "production marker, lock, validator, and external paths are removed" { test-state-production-architecture-removed })
        (run-test "Windows 8.3 alias lifecycle remains valid" { test-windows-short-path-lifecycle })
        (run-test "POSIX symlinked workspace ancestors remain valid" { test-posix-symlinked-ancestor-lifecycle })
        (run-test "concurrent first initialization remains valid" { test-state-concurrent-first-init })
        (run-test "concurrent direct creates publish exactly one winner" { test-state-concurrent-no-clobber })
        (run-test "Windows sibling temp and published file inherit directory DACL" { test-windows-sibling-and-final-dacl })
        (run-test "collection copy cannot propagate removed state artifacts" { test-collection-copy-has-no-state-artifacts })
    ]
}
