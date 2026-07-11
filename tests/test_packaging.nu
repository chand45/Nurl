# Fresh-install payload and command-discovery regressions.

def installer-modules [path: string, prefix: string] {
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

def transitive-module-imports [repo: string] {
    mut required = ["mod.nu"]
    mut index = 0
    while $index < ($required | length) {
        let module = ($required | get $index)
        let path = ($repo | path join "nu_modules" $module)
        assert ($path | path exists) $"transitive module import is missing: ($module)"
        let imports = (
            open $path --raw
            | lines
            | each {|line|
                $line
                | parse --regex '^\s*(?:export\s+)?use\s+(?:nu_modules[\\/])?(?<module>[A-Za-z0-9_-]+\.nu)\b'
            }
            | flatten
            | get module?
            | default []
        )
        for imported in $imports {
            if $imported not-in $required {
                $required = ($required | append $imported)
            }
        }
        $index = $index + 1
    }
    $required | sort
}

def make-install-payload [repo: string, modules: list<string>, destination: string] {
    mkdir ($destination | path join "nu_modules")
    cp ($repo | path join "api.nu") ($destination | path join "api.nu")
    for module in $modules {
        cp ($repo | path join "nu_modules" $module) ($destination | path join "nu_modules" $module)
    }
}

def source-install-payload [install_root: string, runner_root: string] {
    let script = ($runner_root | path join $"source-install-(random uuid).nu")
    let workspace = ($runner_root | path join $"workspace-(random uuid)")
    mkdir $workspace
    [
        $"source (($install_root | path join 'api.nu') | to nuon)"
        "api status | ignore"
    ] | str join "\n" | save -f $script

    let result = (do {
        cd $runner_root
        with-env {NU_LIB_DIRS: ""} {
            ^$nu.current-exe --no-config-file $script | complete
        }
    })
    rm -f $script
    cleanup $workspace
    $result
}

def test-installer-module-payloads [] {
    let repo = $env.NURL_REPO_ROOT
    let tmp = (make-temp-dir "installer-payload")
    let failure = try {
        let ps_modules = (installer-modules ($repo | path join "install.ps1") '$Modules = @(')
        let sh_modules = (installer-modules ($repo | path join "install.sh") "MODULES=(")
        let required = (transitive-module-imports $repo)
        let all_shipped = (
            ls ($repo | path join "nu_modules")
            | where type == file
            | get name
            | path basename
            | where {|name| $name | str ends-with ".nu" }
            | sort
        )

        assert equal ($ps_modules | sort) $required "PowerShell installer must contain every transitive module import"
        assert equal ($sh_modules | sort) $required "shell installer must contain every transitive module import"
        assert equal ($ps_modules | sort) ($sh_modules | sort) "installer module payloads must remain equivalent"
        assert equal $required $all_shipped "every shipped module should be reachable from api.nu"
        assert equal ($ps_modules | uniq | length) ($ps_modules | length) "PowerShell installer payload must not contain duplicates"
        assert equal ($sh_modules | uniq | length) ($sh_modules | length) "shell installer payload must not contain duplicates"
        assert ("resource-path.nu" in $required)
        assert ("command-error.nu" in $required)
        assert ("windows-private-capture.nu" not-in $required) "obsolete filesystem capture helper remains in the module closure"
        assert (not (($repo | path join "nu_modules" "windows-private-capture.nu") | path exists)) "obsolete filesystem capture helper remains shipped"
        for installer in ["install.ps1" "install.sh"] {
            let source = (open ($repo | path join $installer) --raw)
            assert ($source | str contains "7.83.0") $"($installer) does not enforce the documented curl feature floor"
            assert (not ($source | str contains "windows-private-capture.nu")) $"($installer) still packages the obsolete capture helper"
        }

        for payload in [
            {name: "powershell", modules: $ps_modules}
            {name: "shell", modules: $sh_modules}
        ] {
            let install_root = ($tmp | path join $payload.name)
            let runner_root = ($tmp | path join $"runner-($payload.name)")
            mkdir $runner_root
            make-install-payload $repo $payload.modules $install_root

            let sourced = (source-install-payload $install_root $runner_root)
            assert equal $sourced.exit_code 0 $"isolated ($payload.name) installer payload did not source successfully"
            assert equal ($sourced.stderr | str trim) "" $"isolated ($payload.name) source wrote stderr"

            for required_module in ["resource-path.nu" "command-error.nu"] {
                let module_path = ($install_root | path join "nu_modules" $required_module)
                let backup_path = ($tmp | path join $"($payload.name)-($required_module)")
                mv $module_path $backup_path
                let omitted = (source-install-payload $install_root $runner_root)
                assert ($omitted.exit_code != 0) $"installer fixture sourced without required module ($required_module)"
                assert (($omitted.stderr | ansi strip) | str contains $required_module) $"missing-module diagnostic did not identify ($required_module)"
                mv $backup_path $module_path
            }
        }
        null
    } catch {|error| $error }

    cleanup $tmp
    assert (not ($tmp | path exists)) "installer payload test leaked its temporary directory"
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def test-installer-script-syntax [] {
    let repo = $env.NURL_REPO_ROOT
    let ps_path = ($repo | path join "install.ps1")
    let ps_command = '& { param($path) $tokens = $null; $errors = $null; [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null; if ($errors.Count -gt 0) { $errors | ForEach-Object { [Console]::Error.WriteLine($_.Message) }; exit 1 } }'
    let powershell = if (which pwsh | is-not-empty) {
        "pwsh"
    } else if (which powershell.exe | is-not-empty) {
        "powershell.exe"
    } else {
        null
    }
    if $powershell != null {
        let ps_parse = (^$powershell -NoProfile -NonInteractive -Command $ps_command $ps_path | complete)
        assert equal $ps_parse.exit_code 0 $"PowerShell installer syntax failed: ($ps_parse.stderr)"
    } else {
        let modules = (installer-modules $ps_path '$Modules = @(')
        assert (($modules | length) > 0) "PowerShell module declaration must remain parseable without PowerShell"
    }

    if (which bash | is-not-empty) {
        let sh_parse = (
            open ($repo | path join "install.sh") --raw
            | str replace --all "\r" ""
            | ^bash -n
            | complete
        )
        assert equal $sh_parse.exit_code 0 $"shell installer syntax failed: ($sh_parse.stderr)"
    } else {
        let modules = (installer-modules ($repo | path join "install.sh") "MODULES=(")
        assert (($modules | length) > 0) "shell module declaration must remain parseable without Bash"
    }
}

def test-command-discovery-source-duplicates [] {
    let repo = $env.NURL_REPO_ROOT
    let discover = ($repo | path join ".github" "skills" "validate-nurl-api" "scripts" "discover-commands.nu")
    let current = (^$nu.current-exe --no-config-file $discover --root $repo --check-help --json | complete)
    assert equal $current.exit_code 0 $"current command discovery failed: ($current.stderr)"
    let current_data = ($current.stdout | from json)
    assert equal $current_data.defined_count 82
    assert equal $current_data.defined_export_count 82
    assert equal $current_data.covered_count 82
    assert equal ($current_data.source_duplicates | length) 0
    assert $current_data.ok

    let fixture = (make-temp-dir "duplicate-source")
    let failure = try {
        mkdir ($fixture | path join "nu_modules")
        [
            'export def "api help" [] { "first" }'
            'export def "api help" [] { "second" }'
        ] | str join "\n" | save -f ($fixture | path join "nu_modules" "mod.nu")

        let duplicate = (^$nu.current-exe --no-config-file $discover --root $fixture --json | complete)
        assert ($duplicate.exit_code != 0) "duplicate source exports must fail discovery"
        let duplicate_data = ($duplicate.stdout | from json)
        assert equal $duplicate_data.defined_count 1
        assert equal $duplicate_data.defined_export_count 2
        assert equal ($duplicate_data.source_duplicates | length) 1
        assert equal ($duplicate_data.source_duplicates | first | get command) "api help"
        assert equal ($duplicate_data.source_duplicates | first | get count) 2
        assert (not $duplicate_data.ok)
        null
    } catch {|error| $error }
    cleanup $fixture
    assert (not ($fixture | path exists)) "duplicate-source test leaked its fixture"
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def test-command-discovery-exact-help [] {
    let repo = $env.NURL_REPO_ROOT
    let discover = ($repo | path join ".github" "skills" "validate-nurl-api" "scripts" "discover-commands.nu")
    let fixture = (make-temp-dir "help-drift")
    let manifest = ($fixture | path join "coverage.nuon")
    let modfile = ($fixture | path join "nu_modules" "mod.nu")
    let exports = [
        'export def "api request" [] {}'
        'export def "api request create" [] {}'
        'export def "api request recreate" [] {}'
        'export def "api tui" [] {}'
    ]
    let coverage = [
        {command: "api help", kind: command, group: setup, test: "api help"}
        {command: "api request", kind: command, group: requests, test: "api request"}
        {command: "api request create", kind: command, group: requests, test: "api request create"}
        {command: "api request recreate", kind: command, group: requests, test: "api request recreate"}
        {command: "api tui", kind: tui, group: tui, test: "api tui"}
    ]

    let failure = try {
        mkdir ($fixture | path join "nu_modules")
        $coverage | save -f $manifest
        [
            ...$exports
            'export def "api help" [] {'
            '  print $"'
            '(ansi yellow)Setup:(ansi reset)'
            '  api help                         Show help'
            '(ansi yellow)Requests:(ansi reset)'
            '  api request -m <method> <url>    Generic request'
            '    api request   create <n>          Create request'
            '  api request recreate             Similar valid sibling'
            '(ansi yellow)TUI:(ansi reset)'
            '  * api tui                        Launch TUI'
            '(ansi yellow)Requests:(ansi reset)'
            '  api request frobnicate <n>       Nonexistent child'
            '  api request create-extra <n>     Nonexistent prefix sibling'
            '(ansi yellow)Scripting:(ansi reset)'
            '  api request -m GET <url>          # example, not a command row'
            '  api send create-post -c jsonplaceholder  Lowercase example request'
            '  ```text'
            '  api request fenced-example       This fenced example is ignored'
            '  ```'
            '  "'
            '}'
        ] | str join "\n" | save -f $modfile

        let drift = (^$nu.current-exe --no-config-file $discover --root $fixture --manifest $manifest --check-help --json | complete)
        assert ($drift.exit_code != 0) "nonexistent help children must fail discovery"
        let drift_data = ($drift.stdout | from json)
        assert equal $drift_data.help_drift ["api request create-extra" "api request frobnicate"]
        assert ("api request -m GET <url>" in $drift_data.help_examples) "request example was not classified separately"
        assert ("api send create-post -c jsonplaceholder" in $drift_data.help_examples) "lowercase scripting example was not classified separately"
        assert ("api send create-post" not-in $drift_data.help_commands) "lowercase scripting example was parsed as a command"
        assert ("api request create" in $drift_data.help_commands) "valid exact child was not parsed"
        assert ("api request recreate" in $drift_data.help_commands) "similar valid sibling was not parsed"
        assert ("api tui" in $drift_data.help_commands) "list-marked help entry was not parsed"
        assert equal ($drift_data.source_duplicates | length) 0
        assert equal ($drift_data.duplicates | length) 0

        [
            ...$exports
            'export def "api help" [] {'
            '  print $"'
            '(ansi yellow)Setup:(ansi reset)'
            '  api help                         Show help'
            '(ansi yellow)Requests:(ansi reset)'
            '  api request -m <method> <url>    Generic request'
            '    api request   create <n>          Create request'
            '  api request recreate             Similar valid sibling'
            '(ansi yellow)TUI:(ansi reset)'
            '  - api tui                        Launch TUI'
            '(ansi yellow)Scripting:(ansi reset)'
            '  api request -m GET <url>          # example, not a command row'
            '  api send create-post -c jsonplaceholder  Lowercase example request'
            '  ```text'
            '  api request fenced-example       This fenced example is ignored'
            '  ```'
            '  "'
            '}'
        ] | str join "\n" | save -f $modfile

        let valid = (^$nu.current-exe --no-config-file $discover --root $fixture --manifest $manifest --check-help --json | complete)
        assert equal $valid.exit_code 0 $"valid exact help fixture failed: ($valid.stderr)"
        let valid_data = ($valid.stdout | from json)
        assert equal $valid_data.help_drift []
        assert $valid_data.ok
        assert equal $valid_data.defined_count 5
        assert equal $valid_data.covered_count 5
        null
    } catch {|error| $error }
    cleanup $fixture
    assert (not ($fixture | path exists)) "help-drift fixture leaked its temporary directory"
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def run-suite-packaging []: nothing -> list<record> {
    print $"\n(ansi yellow)── Installer packaging and discovery ──(ansi reset)"
    [
        (run-test "fresh installer payloads include and source every transitive module" { test-installer-module-payloads })
        (run-test "installer scripts remain syntactically valid" { test-installer-script-syntax })
        (run-test "command discovery rejects duplicate source exports before deduplication" { test-command-discovery-source-duplicates })
        (run-test "command discovery exact-matches curated help entries" { test-command-discovery-exact-help })
    ]
}
