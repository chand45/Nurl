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

def installer-version-cases [] {
    [
        {
            name: "below-floor"
            version_line: "curl 7.74.0 (x86_64-pc-linux-gnu) libcurl/7.74.0"
            probe_exit: 0
            probe_stderr: ""
            accepted: false
            diagnostic: "curl 7.75.0 or newer is required"
        }
        {
            name: "minimum-vendor"
            version_line: "curl 7.75.0-acme1 (x86_64-pc-linux-gnu) libcurl/7.75.0\nignored second line"
            probe_exit: 0
            probe_stderr: ""
            accepted: true
            diagnostic: ""
        }
        {
            name: "windows-vendor"
            version_line: "curl.exe 7.82.5 Windows libcurl/7.82.5 Schannel"
            probe_exit: 0
            probe_stderr: ""
            accepted: true
            diagnostic: ""
        }
        {
            name: "current"
            version_line: "curl 8.13.0 (x86_64-pc-linux-gnu) libcurl/8.13.0"
            probe_exit: 0
            probe_stderr: ""
            accepted: true
            diagnostic: ""
        }
        {
            name: "numeric-tail"
            version_line: "curl 7.75.0.1 libcurl/7.75.0"
            probe_exit: 0
            probe_stderr: ""
            accepted: false
            diagnostic: "Could not determine the installed curl version"
        }
        {
            name: "missing-patch"
            version_line: "curl 7.75 libcurl/7.75"
            probe_exit: 0
            probe_stderr: ""
            accepted: false
            diagnostic: "Could not determine the installed curl version"
        }
        {
            name: "malformed"
            version_line: "curl release-seven-seventy-five"
            probe_exit: 0
            probe_stderr: ""
            accepted: false
            diagnostic: "Could not determine the installed curl version"
        }
        {
            name: "empty"
            version_line: ""
            probe_exit: 0
            probe_stderr: ""
            accepted: false
            diagnostic: "Could not determine the installed curl version"
        }
        {
            name: "nonzero-valid-stdout"
            version_line: "curl 8.13.0 (x86_64-pc-linux-gnu) libcurl/8.13.0"
            probe_exit: 9
            probe_stderr: ""
            accepted: false
            diagnostic: "Could not determine the installed curl version"
        }
        {
            name: "nonzero-stderr"
            version_line: ""
            probe_exit: 7
            probe_stderr: "PROBE-STDERR-SENTINEL"
            accepted: false
            diagnostic: "Could not determine the installed curl version"
        }
    ]
}

def compile-powershell-installer-curl [tools: string] {
    let fake = ($tools | path join "curl.exe")
    let compile_script = '
$ErrorActionPreference = "Stop"
$source = @"
using System;
using System.IO;

public static class InstallerCurl
{
    public static int Main(string[] args)
    {
        string log = Environment.GetEnvironmentVariable("NURL_INSTALLER_CURL_LOG");
        if (args.Length > 0 && args[0] == "--version")
        {
            if (!String.IsNullOrEmpty(log))
            {
                File.AppendAllText(log, "version" + Environment.NewLine);
            }
            string output = Environment.GetEnvironmentVariable("NURL_INSTALLER_CURL_VERSION_LINE") ?? "";
            string error = Environment.GetEnvironmentVariable("NURL_INSTALLER_CURL_STDERR") ?? "";
            if (!String.IsNullOrEmpty(output))
            {
                Console.Out.WriteLine(output);
            }
            if (!String.IsNullOrEmpty(error))
            {
                Console.Error.WriteLine(error);
            }
            int exitCode;
            return Int32.TryParse(Environment.GetEnvironmentVariable("NURL_INSTALLER_CURL_EXIT"), out exitCode)
                ? exitCode
                : 0;
        }
        if (!String.IsNullOrEmpty(log))
        {
            File.AppendAllText(log, "unexpected-transfer" + Environment.NewLine);
        }
        return 99;
    }
}
"@
Add-Type -TypeDefinition $source -OutputAssembly $env:NURL_INSTALLER_FAKE_CURL -OutputType ConsoleApplication
'
    let compiled = (with-env {NURL_INSTALLER_FAKE_CURL: $fake} {
        ^powershell.exe -NoProfile -NonInteractive -Command $compile_script | complete
    })
    assert equal $compiled.exit_code 0 $"could not compile PowerShell installer curl fixture: ($compiled.stderr)"
    "@echo off\r\nexit /b 0\r\n" | save -f ($tools | path join "nu.cmd")
}

def powershell-installer-harness [fixture: string] {
    let harness = ($fixture | path join "run-installer.ps1")
    'param($Installer, $HomePath, $AppDataPath, $ToolsPath)
$env:USERPROFILE = $HomePath
$env:HOME = $HomePath
$env:APPDATA = $AppDataPath
$env:Path = $ToolsPath

function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing)
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($OutFile)) | Out-Null
    [System.IO.File]::WriteAllText($OutFile, "# deterministic installer fixture")
    [System.IO.File]::AppendAllText($env:NURL_INSTALLER_DOWNLOAD_LOG, "download`n")
}

& $Installer
exit $LASTEXITCODE
' | save -f $harness
    $harness
}

def shell-installer-tools [tools: string, bash: string] {
    '#!/bin/sh
exit 0
' | str replace --all "\r" "" | save -f ($tools | path join "nu")
    '#!/bin/bash
if [[ "$1" == "--version" ]]; then
    echo version >> "$NURL_INSTALLER_CURL_LOG"
    if [[ -n "$NURL_INSTALLER_CURL_VERSION_LINE" ]]; then
        printf "%s\n" "$NURL_INSTALLER_CURL_VERSION_LINE"
    fi
    if [[ -n "$NURL_INSTALLER_CURL_STDERR" ]]; then
        printf "%s\n" "$NURL_INSTALLER_CURL_STDERR" >&2
    fi
    exit "${NURL_INSTALLER_CURL_EXIT:-0}"
fi

echo download >> "$NURL_INSTALLER_DOWNLOAD_LOG"
output=""
while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == "-o" ]]; then
        shift
        output="$1"
    fi
    shift
done
if [[ -z "$output" ]]; then
    exit 98
fi
printf "%s\n" "# deterministic installer fixture" > "$output"
' | str replace --all "\r" "" | save -f ($tools | path join "curl")
    if $nu.os-info.name == "windows" {
        let bash_nu = (path-for-bash $bash ($tools | path join "nu"))
        let bash_curl = (path-for-bash $bash ($tools | path join "curl"))
        let chmod_command = $"chmod 700 '($bash_nu)' '($bash_curl)'"
        let chmod_result = (^$bash -lc $chmod_command | complete)
        assert equal $chmod_result.exit_code 0 $"could not make shell installer tools executable: ($chmod_result.stderr)"
    } else {
        ^chmod 700 ($tools | path join "nu") ($tools | path join "curl")
    }
}

def path-for-bash [bash: string, path: string] {
    if $nu.os-info.name != "windows" {
        return $path
    }
    let quoted_path = "'" + ($path | str replace --all "'" "'\"'\"'") + "'"
    let conversion_command = (
        "if command -v wslpath >/dev/null 2>&1; then wslpath -a -u "
        + $quoted_path
        + "; elif command -v cygpath >/dev/null 2>&1; then cygpath -u "
        + $quoted_path
        + "; else printf '%s\\n' "
        + $quoted_path
        + "; fi"
    )
    let converted = (
        ^$bash -lc $conversion_command
        | complete
    )
    assert equal $converted.exit_code 0 $"could not map fixture path for Bash: ($converted.stderr)"
    $converted.stdout | str trim
}

def quote-for-bash [value: string] {
    "'" + ($value | str replace --all "'" "'\"'\"'") + "'"
}

def assert-rejected-installer-state [
    result: record
    home: string
    config_root: string
    curl_log: string
    download_log: string
    diagnostic: string
    label: string
] {
    let output = $result.stdout + $result.stderr
    assert ($result.exit_code != 0) $"($label) unexpectedly succeeded"
    assert ($output | str contains $diagnostic) $"($label) diagnostic was not actionable: ($output)"
    assert equal $output ($output | ansi strip) $"($label) emitted ANSI to non-TTY output"
    assert (not ($output | str contains "PROBE-STDERR-SENTINEL")) $"($label) leaked curl probe stderr"
    assert (not (($home | path join ".nurl") | path exists)) $"($label) created the installation root"
    assert (not ($config_root | path exists)) $"($label) mutated the Nushell profile/config root"
    assert (not ($download_log | path exists)) $"($label) attempted a download"
    if ($curl_log | path exists) {
        assert equal (open $curl_log --raw | lines) ["version"] $"($label) advanced past the version probe"
    }
}

def test-powershell-installer-curl-preflight [] {
    if $nu.os-info.name != "windows" {
        error make {msg: "SKIP: PowerShell installer execution is Windows-specific"}
    }
    let fixture = (make-temp-dir "installer-powershell-curl")
    let failure = try {
        let tools = ($fixture | path join "tools")
        let tools_without_curl = ($fixture | path join "tools-without-curl")
        mkdir $tools
        mkdir $tools_without_curl
        compile-powershell-installer-curl $tools
        cp ($tools | path join "nu.cmd") ($tools_without_curl | path join "nu.cmd")
        let harness = (powershell-installer-harness $fixture)
        let installer = ($env.NURL_REPO_ROOT | path join "install.ps1")

        for case in (installer-version-cases) {
            let root = ($fixture | path join $case.name)
            let home = ($root | path join "home")
            let appdata = ($root | path join "appdata")
            mkdir $home
            mkdir $appdata
            let curl_log = ($root | path join "curl.log")
            let download_log = ($root | path join "downloads.log")
            let result = (with-env {
                NURL_INSTALLER_CURL_VERSION_LINE: $case.version_line
                NURL_INSTALLER_CURL_EXIT: ($case.probe_exit | into string)
                NURL_INSTALLER_CURL_STDERR: $case.probe_stderr
                NURL_INSTALLER_CURL_LOG: $curl_log
                NURL_INSTALLER_DOWNLOAD_LOG: $download_log
            } {
                ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness $installer $home $appdata $tools | complete
            })
            if $case.accepted {
                assert equal $result.exit_code 0 $"PowerShell installer rejected ($case.name): ($result.stderr)"
                assert (($home | path join ".nurl" "api.nu") | path exists) $"PowerShell installer did not continue for ($case.name)"
                assert (($appdata | path join "nushell" "config.nu") | path exists) $"PowerShell installer did not configure Nushell for ($case.name)"
                assert ((open $download_log --raw | lines | length) > 10) $"PowerShell accepted fixture did not exercise downloads: ($case.name)"
                assert equal (open $curl_log --raw | lines) ["version"] $"PowerShell accepted fixture repeated or bypassed the version probe: ($case.name)"
            } else {
                assert-rejected-installer-state $result $home ($appdata | path join "nushell") $curl_log $download_log $case.diagnostic $"PowerShell ($case.name)"
            }
        }

        let missing_root = ($fixture | path join "missing-executable")
        let missing_home = ($missing_root | path join "home")
        let missing_appdata = ($missing_root | path join "appdata")
        mkdir $missing_home
        mkdir $missing_appdata
        let missing_download_log = ($missing_root | path join "downloads.log")
        let missing_result = (with-env {NURL_INSTALLER_DOWNLOAD_LOG: $missing_download_log} {
            ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness $installer $missing_home $missing_appdata $tools_without_curl | complete
        })
        assert-rejected-installer-state $missing_result $missing_home ($missing_appdata | path join "nushell") ($missing_root | path join "curl.log") $missing_download_log "curl 7.75.0 or newer is required" "PowerShell (missing executable)"
        null
    } catch {|error| $error }
    cleanup $fixture
    assert (not ($fixture | path exists)) "PowerShell installer fixtures leaked their temporary root"
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def test-shell-installer-curl-preflight [] {
    let bash_candidates = (which bash | where type == "external" | get path? | default [])
    if ($bash_candidates | is-empty) {
        error make {msg: "SKIP: Bash is unavailable for the shell installer fixtures"}
    }
    let bash = ($bash_candidates | first)
    let fixture = (make-temp-dir "installer-shell-curl")
    let failure = try {
        let tools = ($fixture | path join "tools")
        let tools_without_curl = ($fixture | path join "tools-without-curl")
        mkdir $tools
        mkdir $tools_without_curl
        shell-installer-tools $tools $bash
        cp ($tools | path join "nu") ($tools_without_curl | path join "nu")
        let installer = ($fixture | path join "install.sh")
        open ($env.NURL_REPO_ROOT | path join "install.sh") --raw
        | str replace --all "\r" ""
        | save -f $installer
        let bash_installer = (path-for-bash $bash $installer)
        let bash_tools = (path-for-bash $bash $tools)
        let bash_tools_without_curl = (path-for-bash $bash $tools_without_curl)

        for case in (installer-version-cases) {
            let root = ($fixture | path join $case.name)
            let home = ($root | path join "home")
            mkdir $home
            let curl_log = ($root | path join "curl.log")
            let download_log = ($root | path join "downloads.log")
            let bash_home = (path-for-bash $bash $home)
            let bash_curl_log = (path-for-bash $bash $curl_log)
            let bash_download_log = (path-for-bash $bash $download_log)
            let run_command = (
                "HOME=" + (quote-for-bash $bash_home)
                + " PATH=" + (quote-for-bash $"($bash_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
                + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash $case.version_line)
                + " NURL_INSTALLER_CURL_EXIT=" + (quote-for-bash ($case.probe_exit | into string))
                + " NURL_INSTALLER_CURL_STDERR=" + (quote-for-bash $case.probe_stderr)
                + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash $bash_curl_log)
                + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash $bash_download_log)
                + " /bin/bash " + (quote-for-bash $bash_installer)
            )
            let result = (^$bash -lc $run_command | complete)
            if $case.accepted {
                assert equal $result.exit_code 0 $"shell installer rejected ($case.name): ($result.stderr)"
                assert (($home | path join ".nurl" "api.nu") | path exists) $"shell installer did not continue for ($case.name)"
                assert (($home | path join ".config" "nushell" "config.nu") | path exists) $"shell installer did not configure Nushell for ($case.name)"
                assert ((open $download_log --raw | lines | length) > 10) $"shell accepted fixture did not exercise downloads: ($case.name)"
                assert equal (open $curl_log --raw | lines | first) "version" $"shell accepted fixture bypassed the version probe: ($case.name)"
            } else {
                assert-rejected-installer-state $result $home ($home | path join ".config" "nushell") $curl_log $download_log $case.diagnostic $"shell ($case.name)"
            }
        }

        let missing_root = ($fixture | path join "missing-executable")
        let missing_home = ($missing_root | path join "home")
        mkdir $missing_home
        let missing_download_log = ($missing_root | path join "downloads.log")
        let bash_missing_home = (path-for-bash $bash $missing_home)
        let bash_missing_download_log = (path-for-bash $bash $missing_download_log)
        let missing_command = (
            "HOME=" + (quote-for-bash $bash_missing_home)
            + " PATH=" + (quote-for-bash $bash_tools_without_curl)
            + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash $bash_missing_download_log)
            + " /bin/bash " + (quote-for-bash $bash_installer)
        )
        let missing_result = (^$bash -lc $missing_command | complete)
        assert-rejected-installer-state $missing_result $missing_home ($missing_home | path join ".config" "nushell") ($missing_root | path join "curl.log") $missing_download_log "curl is not installed" "shell (missing executable)"
        null
    } catch {|error| $error }
    cleanup $fixture
    assert (not ($fixture | path exists)) "shell installer fixtures leaked their temporary root"
    if $failure != null {
        error make {msg: $failure.msg}
    }
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
        assert ("curl-capability.nu" in $required)
        assert ("windows-private-capture.nu" not-in $required) "obsolete filesystem capture helper remains in the module closure"
        assert (not (($repo | path join "nu_modules" "windows-private-capture.nu") | path exists)) "obsolete filesystem capture helper remains shipped"
        let runtime_source = (open ($repo | path join "nu_modules" "curl-capability.nu") --raw)
        let runtime_floor = (
            $runtime_source
            | parse --regex 'const CURL_MIN_VERSION = "(?<version>\d+\.\d+\.\d+)"'
            | get 0.version
        )
        let declared_floors = [
            {
                name: "PowerShell installer"
                version: (
                    open ($repo | path join "install.ps1") --raw
                    | parse --regex '\$MinimumCurlVersion = \[version\]"(?<version>\d+\.\d+\.\d+)"'
                    | get 0.version
                )
            }
            {
                name: "shell installer"
                version: (
                    open ($repo | path join "install.sh") --raw
                    | parse --regex 'MINIMUM_CURL_VERSION="(?<version>\d+\.\d+\.\d+)"'
                    | get 0.version
                )
            }
            {
                name: "README"
                version: (
                    open ($repo | path join "README.md") --raw
                    | parse --regex 'curl >= (?<version>\d+\.\d+\.\d+)'
                    | get 0.version
                )
            }
        ]
        for declaration in $declared_floors {
            assert equal $declaration.version $runtime_floor $"($declaration.name) curl floor drifted from the runtime constant"
        }
        assert equal $runtime_floor "7.75.0" "runtime curl floor must match the newest fileless write-out feature"
        for installer in ["install.ps1" "install.sh"] {
            let source = (open ($repo | path join $installer) --raw)
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

            for required_module in ["resource-path.nu" "command-error.nu" "curl-capability.nu"] {
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
        (run-test "PowerShell installer rejects unsafe curl probes before mutation" { test-powershell-installer-curl-preflight })
        (run-test "shell installer rejects unsafe curl probes before mutation" { test-shell-installer-curl-preflight })
        (run-test "command discovery rejects duplicate source exports before deduplication" { test-command-discovery-source-duplicates })
        (run-test "command discovery exact-matches curated help entries" { test-command-discovery-exact-help })
    ]
}
