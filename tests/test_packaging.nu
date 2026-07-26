# Fresh-install payload and command-discovery regressions.

use ../nu_modules/string-compat.nu [ascii-equal-ignore-case ascii-upcase]

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
            name: "uppercase-banner"
            version_line: "CURL 7.75.0 (x86_64-pc-linux-gnu) libcurl/7.75.0"
            probe_exit: 0
            probe_stderr: ""
            accepted: false
            diagnostic: "Could not determine the installed curl version"
        }
        {
            name: "mixed-case-banner"
            version_line: "CuRl 7.75.0 (x86_64-pc-linux-gnu) libcurl/7.75.0"
            probe_exit: 0
            probe_stderr: ""
            accepted: false
            diagnostic: "Could not determine the installed curl version"
        }
        {
            name: "uppercase-exe-banner"
            version_line: "CURL.EXE 7.82.5 Windows libcurl/7.82.5 Schannel"
            probe_exit: 0
            probe_stderr: ""
            accepted: false
            diagnostic: "Could not determine the installed curl version"
        }
        {
            name: "mixed-case-exe-banner"
            version_line: "cUrL.ExE 7.82.5 Windows libcurl/7.82.5 Schannel"
            probe_exit: 0
            probe_stderr: ""
            accepted: false
            diagnostic: "Could not determine the installed curl version"
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
    '@echo off
if "%~1"=="--version" (
  if defined NURL_INSTALLER_NU_VERSION (echo %NURL_INSTALLER_NU_VERSION%) else (echo 0.113.1)
  if defined NURL_INSTALLER_NU_VERSION_EXIT (exit /b %NURL_INSTALLER_NU_VERSION_EXIT%)
  exit /b 0
)
if "%~1"=="--no-config-file" if "%~2"=="-c" (
  if defined NURL_INSTALLER_CONFIG_EMPTY (exit /b 0)
  if defined NURL_INSTALLER_CONFIG_DIR (echo %NURL_INSTALLER_CONFIG_DIR%) else (echo %APPDATA%\nushell)
  exit /b 0
)
if "%~1"=="--no-config-file" (
  if defined NURL_INSTALLER_NU_PARSE_EXIT (exit /b %NURL_INSTALLER_NU_PARSE_EXIT%)
  exit /b 0
)
exit /b 0
' | str replace --all "\n" "\r\n" | save -f ($tools | path join "nu.cmd")
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
    $countFile = if ($env:NURL_INSTALLER_DOWNLOAD_COUNT) {
        $env:NURL_INSTALLER_DOWNLOAD_COUNT
    } else {
        "$($env:NURL_INSTALLER_DOWNLOAD_LOG).count"
    }
    $count = 1
    if (Test-Path $countFile) {
        $count = 1 + [int][System.IO.File]::ReadAllText($countFile)
    }
    [System.IO.File]::WriteAllText($countFile, [string]$count)
    if ($env:NURL_INSTALLER_FAIL_DOWNLOAD -and $count -eq [int]$env:NURL_INSTALLER_FAIL_DOWNLOAD) {
        throw "deterministic download failure at $count"
    }
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
    '#!/bin/bash
if [[ "$1" == "--version" ]]; then
    printf "%s\n" "${NURL_INSTALLER_NU_VERSION:-0.113.1}"
    exit "${NURL_INSTALLER_NU_VERSION_EXIT:-0}"
fi
if [[ "$1" == "--no-config-file" && "$2" == "-c" ]]; then
    if [[ -n "$NURL_INSTALLER_CONFIG_EMPTY" ]]; then
        exit 0
    fi
    printf "%s\n" "${NURL_INSTALLER_CONFIG_DIR:-$HOME/.config/nushell}"
    exit 0
fi
if [[ "$1" == "--no-config-file" ]]; then
    exit "${NURL_INSTALLER_NU_PARSE_EXIT:-0}"
fi
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
count_file="${NURL_INSTALLER_DOWNLOAD_COUNT:-$NURL_INSTALLER_DOWNLOAD_LOG.count}"
count=1
if [[ -f "$count_file" ]]; then
    count=$(( $(cat "$count_file") + 1 ))
fi
printf "%s" "$count" > "$count_file"
if [[ -n "$NURL_INSTALLER_FAIL_DOWNLOAD" && "$count" -eq "$NURL_INSTALLER_FAIL_DOWNLOAD" ]]; then
    exit 22
fi
output=""
fail_http=false
while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == "-o" ]]; then
        shift
        output="$1"
    elif [[ "$1" == -* && "$1" == *f* ]]; then
        fail_http=true
    fi
    shift
done
if [[ -z "$output" ]]; then
    exit 98
fi
if [[ -n "$NURL_INSTALLER_HTTP_ERROR_AT" && "$count" -eq "$NURL_INSTALLER_HTTP_ERROR_AT" ]]; then
    printf "%s\n" "<html>404 not found</html>" > "$output"
    if [[ "$fail_http" == true ]]; then
        exit 22
    fi
    exit 0
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

def child-paths-starting [root: string, prefix: string] {
    if not ($root | path exists) {
        return []
    }
    ls -a $root
    | where {|entry| $entry.name | path basename | str starts-with $prefix }
    | get name
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
    let normalized_output = ($output | str replace --all "\r" "")
    assert ($result.exit_code != 0) $"($label) unexpectedly succeeded"
    assert ($output | str contains $diagnostic) $"($label) diagnostic was not actionable: ($output)"
    assert equal $normalized_output ($normalized_output | ansi strip) $"($label) emitted ANSI to non-TTY output: ($output | to nuon)"
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

def test-installer-nushell-floor [] {
    let fixture = (make-temp-dir "installer-nushell-floor")
    let failure = try {
        let bash_candidates = (which bash | where type == "external" | get path? | default [])
        if ($bash_candidates | is-not-empty) {
            let bash = ($bash_candidates | first)
            let tools = ($fixture | path join "shell-tools")
            mkdir $tools
            shell-installer-tools $tools $bash
            let home = ($fixture | path join "shell-home")
            mkdir $home
            let installer = (path-for-bash $bash ($env.NURL_REPO_ROOT | path join "install.sh"))
            let bash_home = (path-for-bash $bash $home)
            let bash_tools = (path-for-bash $bash $tools)
            let curl_log = ($fixture | path join "shell-curl.log")
            let download_log = ($fixture | path join "shell-downloads.log")
            let command = (
                "HOME=" + (quote-for-bash $bash_home)
                + " PATH=" + (quote-for-bash $"($bash_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
                + " NURL_INSTALLER_NU_VERSION=0.88.0"
                + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
                + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash $curl_log))
                + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash $download_log))
                + " /bin/bash " + (quote-for-bash $installer)
            )
            let result = (^$bash -lc $command | complete)
            assert-rejected-installer-state $result $home ($home | path join ".config" "nushell") $curl_log $download_log "Nushell 0.89.0 or newer is required" "shell Nushell 0.88.0"
        }

        if $nu.os-info.name == "windows" {
            let tools = ($fixture | path join "powershell-tools")
            let home = ($fixture | path join "powershell-home")
            let appdata = ($fixture | path join "powershell-appdata")
            mkdir $tools
            mkdir $home
            mkdir $appdata
            compile-powershell-installer-curl $tools
            let harness = (powershell-installer-harness $fixture)
            let download_log = ($fixture | path join "powershell-downloads.log")
            let result = (with-env {
                NURL_INSTALLER_NU_VERSION: "0.88.0"
                NURL_INSTALLER_CURL_VERSION_LINE: "curl 8.13.0 libcurl/8.13.0"
                NURL_INSTALLER_CURL_EXIT: "0"
                NURL_INSTALLER_CURL_STDERR: ""
                NURL_INSTALLER_CURL_LOG: ($fixture | path join "powershell-curl.log")
                NURL_INSTALLER_DOWNLOAD_LOG: $download_log
            } {
                ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness ($env.NURL_REPO_ROOT | path join "install.ps1") $home $appdata $tools | complete
            })
            assert-rejected-installer-state $result $home ($appdata | path join "nushell") ($fixture | path join "powershell-curl.log") $download_log "Nushell 0.89.0 or newer is required" "PowerShell Nushell 0.88.0"
        }
        null
    } catch {|error| $error }
    cleanup $fixture
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def test-installer-atomic-staging [] {
    let fixture = (make-temp-dir "installer-atomic")
    let failure = try {
        let bash_candidates = (which bash | where type == "external" | get path? | default [])
        if ($bash_candidates | is-empty) {
            error make {msg: "SKIP: Bash is unavailable for atomic installer fixtures"}
        }
        let bash = ($bash_candidates | first)
        let tools = ($fixture | path join "shell-tools")
        mkdir $tools
        shell-installer-tools $tools $bash
        let home = ($fixture | path join "shell home")
        let install = ($home | path join ".nurl")
        let modules = ($install | path join "nu_modules")
        let config_dir = ($fixture | path join "shell-config")
        mkdir $modules
        mkdir $config_dir
        "old api bytes" | save -f ($install | path join "api.nu")
        "old module bytes" | save -f ($modules | path join "mod.nu")
        "old user bytes" | save -f ($install | path join "config.nuon")
        "unrelated config" | save -f ($config_dir | path join "config.nu")
        let old_api = (open ($install | path join "api.nu") --raw)
        let old_module = (open ($modules | path join "mod.nu") --raw)
        let old_user = (open ($install | path join "config.nuon") --raw)
        let old_config = (open ($config_dir | path join "config.nu") --raw)
        let curl_log = ($fixture | path join "shell-curl.log")
        let download_log = ($fixture | path join "shell-downloads.log")
        let installer = (path-for-bash $bash ($env.NURL_REPO_ROOT | path join "install.sh"))
        let bash_home = (path-for-bash $bash $home)
        let bash_tools = (path-for-bash $bash $tools)
        let command = (
            "HOME=" + (quote-for-bash $bash_home)
            + " PATH=" + (quote-for-bash $"($bash_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $config_dir))
            + " NURL_INSTALLER_NU_VERSION=0.113.1"
            + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
            + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash $curl_log))
            + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash $download_log))
            + " NURL_INSTALLER_FAIL_DOWNLOAD=6"
            + " /bin/bash " + (quote-for-bash $installer)
        )
        let result = (^$bash -lc $command | complete)
        assert ($result.exit_code != 0) "shell late payload failure unexpectedly succeeded"
        assert (not (($result.stdout + $result.stderr) | str contains "successfully")) "shell failure printed success"
        assert equal (open ($install | path join "api.nu") --raw) $old_api
        assert equal (open ($modules | path join "mod.nu") --raw) $old_module
        assert equal (open ($install | path join "config.nuon") --raw) $old_user
        assert equal (open ($config_dir | path join "config.nu") --raw) $old_config
        assert ((child-paths-starting $home ".nurl-stage.") | is-empty) "shell installer leaked staging"

        let fresh_home = ($fixture | path join "shell-fresh")
        mkdir $fresh_home
        let fresh_download_log = ($fixture | path join "shell-fresh-downloads.log")
        let fresh_command = (
            "HOME=" + (quote-for-bash (path-for-bash $bash $fresh_home))
            + " PATH=" + (quote-for-bash $"($bash_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_INSTALLER_NU_VERSION=0.113.1"
            + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
            + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "shell-fresh-curl.log")))
            + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash $fresh_download_log))
            + " NURL_INSTALLER_HTTP_ERROR_AT=4"
            + " /bin/bash " + (quote-for-bash $installer)
        )
        let fresh_result = (^$bash -lc $fresh_command | complete)
        assert ($fresh_result.exit_code != 0) "shell 404-style fixture unexpectedly succeeded"
        assert (not (($fresh_result.stdout + $fresh_result.stderr) | str contains "successfully")) "shell 404-style fixture printed success"
        assert (not (($fresh_home | path join ".nurl") | path exists)) "shell 404-style fixture installed a broken payload"
        assert (not (($fresh_home | path join ".config" "nushell") | path exists)) "shell 404-style fixture touched config"
        assert ((child-paths-starting $fresh_home ".nurl-stage.") | is-empty) "shell 404-style fixture leaked staging"

        let incompatible_shell_path = ($modules | path join "auth.nu")
        mkdir $incompatible_shell_path
        "directory must survive" | save -f ($incompatible_shell_path | path join "keep.txt")
        let rollback_command = (
            "HOME=" + (quote-for-bash $bash_home)
            + " PATH=" + (quote-for-bash $"($bash_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $config_dir))
            + " NURL_INSTALLER_NU_VERSION=0.113.1"
            + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
            + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "shell-rollback-curl.log")))
            + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "shell-rollback-downloads.log")))
            + " /bin/bash " + (quote-for-bash $installer)
        )
        let rollback_result = (^$bash -lc $rollback_command | complete)
        assert ($rollback_result.exit_code != 0) "shell incompatible live path unexpectedly succeeded"
        assert (($rollback_result.stdout + $rollback_result.stderr) | str contains "Refusing to replace non-file install path") "shell incompatible path failure was not actionable"
        assert equal (open ($install | path join "api.nu") --raw) $old_api "shell rollback did not restore api.nu"
        assert equal (open ($modules | path join "mod.nu") --raw) $old_module "shell rollback did not restore mod.nu"
        assert (not (($modules | path join "http.nu") | path exists)) "shell rollback left a newly promoted module"
        assert equal (open ($incompatible_shell_path | path join "keep.txt") --raw) "directory must survive" "shell rollback damaged an incompatible path"
        assert equal (open ($config_dir | path join "config.nu") --raw) $old_config "shell rollback changed config"
        assert ((child-paths-starting $home ".nurl-stage.") | is-empty) "shell rollback leaked staging"

        if $nu.os-info.name == "windows" {
            let ps_tools = ($fixture | path join "powershell-tools")
            let ps_home = ($fixture | path join "powershell-home")
            let ps_appdata = ($fixture | path join "powershell-appdata")
            let ps_install = ($ps_home | path join ".nurl")
            let ps_modules = ($ps_install | path join "nu_modules")
            mkdir $ps_tools
            mkdir $ps_modules
            mkdir $ps_appdata
            compile-powershell-installer-curl $ps_tools
            "old ps api" | save -f ($ps_install | path join "api.nu")
            "old ps module" | save -f ($ps_modules | path join "mod.nu")
            "old ps data" | save -f ($ps_install | path join "config.nuon")
            let ps_api = (open ($ps_install | path join "api.nu") --raw)
            let ps_module = (open ($ps_modules | path join "mod.nu") --raw)
            let ps_data = (open ($ps_install | path join "config.nuon") --raw)
            let harness = (powershell-installer-harness $fixture)
            let ps_result = (with-env {
                NURL_INSTALLER_NU_VERSION: "0.113.1"
                NURL_INSTALLER_CURL_VERSION_LINE: "curl 8.13.0 libcurl/8.13.0"
                NURL_INSTALLER_CURL_EXIT: "0"
                NURL_INSTALLER_CURL_STDERR: ""
                NURL_INSTALLER_CURL_LOG: ($fixture | path join "ps-curl.log")
                NURL_INSTALLER_DOWNLOAD_LOG: ($fixture | path join "ps-downloads.log")
                NURL_INSTALLER_DOWNLOAD_COUNT: ($fixture | path join "ps-download-count")
                NURL_INSTALLER_FAIL_DOWNLOAD: "6"
            } {
                ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness ($env.NURL_REPO_ROOT | path join "install.ps1") $ps_home $ps_appdata $ps_tools | complete
            })
            assert ($ps_result.exit_code != 0) "PowerShell late payload failure unexpectedly succeeded"
            assert (not (($ps_result.stdout + $ps_result.stderr) | str contains "successfully")) "PowerShell failure printed success"
            assert equal (open ($ps_install | path join "api.nu") --raw) $ps_api
            assert equal (open ($ps_modules | path join "mod.nu") --raw) $ps_module
            assert equal (open ($ps_install | path join "config.nuon") --raw) $ps_data
            assert ((child-paths-starting $ps_home ".nurl-stage-") | is-empty) "PowerShell installer leaked staging"
            assert (not (($ps_appdata | path join "nushell") | path exists)) "PowerShell failure touched config"

            let incompatible_ps_path = ($ps_modules | path join "auth.nu")
            mkdir $incompatible_ps_path
            "PowerShell directory must survive" | save -f ($incompatible_ps_path | path join "keep.txt")
            let ps_rollback = (with-env {
                NURL_INSTALLER_NU_VERSION: "0.113.1"
                NURL_INSTALLER_CURL_VERSION_LINE: "curl 8.13.0 libcurl/8.13.0"
                NURL_INSTALLER_CURL_EXIT: "0"
                NURL_INSTALLER_CURL_STDERR: ""
                NURL_INSTALLER_CURL_LOG: ($fixture | path join "ps-rollback-curl.log")
                NURL_INSTALLER_DOWNLOAD_LOG: ($fixture | path join "ps-rollback-downloads.log")
                NURL_INSTALLER_DOWNLOAD_COUNT: ($fixture | path join "ps-rollback-download-count")
                NURL_INSTALLER_FAIL_DOWNLOAD: ""
            } {
                ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness ($env.NURL_REPO_ROOT | path join "install.ps1") $ps_home $ps_appdata $ps_tools | complete
            })
            assert ($ps_rollback.exit_code != 0) "PowerShell incompatible live path unexpectedly succeeded"
            assert (($ps_rollback.stdout + $ps_rollback.stderr) | str contains "Refusing to replace non-file install path") "PowerShell incompatible path failure was not actionable"
            assert equal (open ($ps_install | path join "api.nu") --raw) $ps_api "PowerShell rollback did not restore api.nu"
            assert equal (open ($ps_modules | path join "mod.nu") --raw) $ps_module "PowerShell rollback did not restore mod.nu"
            assert (not (($ps_modules | path join "http.nu") | path exists)) "PowerShell rollback left a newly promoted module"
            assert equal (open ($incompatible_ps_path | path join "keep.txt") --raw) "PowerShell directory must survive" "PowerShell rollback damaged an incompatible path"
            assert (not (($ps_appdata | path join "nushell") | path exists)) "PowerShell rollback changed config"
            assert ((child-paths-starting $ps_home ".nurl-stage-") | is-empty) "PowerShell rollback leaked staging"
        }
        null
    } catch {|error| $error }
    cleanup $fixture
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def test-shell-uninstall-backup-and-consent [] {
    let bash_candidates = (which bash | where type == "external" | get path? | default [])
    if ($bash_candidates | is-empty) {
        error make {msg: "SKIP: Bash is unavailable for shell uninstall fixtures"}
    }
    let bash = ($bash_candidates | first)
    let fixture = (make-temp-dir "shell-uninstall")
    let failure = try {
        let tools = ($fixture | path join "tools")
        mkdir $tools
        shell-installer-tools $tools $bash
        let home = ($fixture | path join "home O'Brien ü")
        let nurl = ($home | path join ".nurl")
        let resolved_config = ($fixture | path join "resolved config")
        let legacy_config = ($home | path join ".config" "nushell")
        mkdir ($nurl | path join "collections" "demo")
        mkdir ($nurl | path join "chains")
        mkdir ($nurl | path join "history")
        mkdir $resolved_config
        mkdir $legacy_config
        let collection_path = ($nurl | path join "collections" "demo" "request.nuon")
        let chain_path = ($nurl | path join "chains" "flow.nuon")
        let history_path = ($nurl | path join "history" "entry.nuon")
        let config_path = ($nurl | path join "config.nuon")
        let secrets_path = ($nurl | path join "secrets.nuon")
        "collection O'Brien ü\r\n" | save -f $collection_path
        "chain\r\nbytes" | save -f $chain_path
        "history ü" | save -f $history_path
        "{config: true}" | save -f $config_path
        "{tokens: {demo: secret}}" | save -f $secrets_path
        let expected_collection = (open $collection_path --raw)
        let expected_chain = (open $chain_path --raw)
        let expected_history = (open $history_path --raw)
        let expected_config = (open $config_path --raw)
        let expected_secrets = (open $secrets_path --raw)
        let resolved_original = "# comment source ~/.nurl/api.nu\r\nalias nurl-note = echo ~/.nurl/api.nu\r\n# >>> nurl >>>\r\nsource ~/.nurl/api.nu\r\n# <<< nurl <<<"
        $resolved_original | save -f ($resolved_config | path join "config.nu")
        "# >>> nurl >>>\nsource ~/.nurl/api.nu\n# <<< nurl <<<\nlegacy keep\n" | save -f ($legacy_config | path join "config.nu")

        let script = (path-for-bash $bash ($env.NURL_REPO_ROOT | path join "uninstall.sh"))
        let bash_home = (path-for-bash $bash $home)
        let bash_tools = (path-for-bash $bash $tools)
        let bash_config = (path-for-bash $bash $resolved_config)
        let environment = (
            "HOME=" + (quote-for-bash $bash_home)
            + " PATH=" + (quote-for-bash $"($bash_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash $bash_config)
        )
        let abort = (^$bash -lc $"($environment) /usr/bin/setsid -w /bin/bash (quote-for-bash $script) </dev/null" | complete)
        assert ($abort.exit_code != 0) "non-TTY shell uninstall unexpectedly proceeded"
        assert (($abort.stdout + $abort.stderr) | str contains "--yes") "non-TTY shell uninstall did not explain explicit consent"
        assert ($nurl | path exists) "non-TTY shell uninstall mutated the installation"

        let piped = (^$bash -lc $"cat (quote-for-bash $script) | ($environment) /bin/bash -s -- --yes" | complete)
        assert equal $piped.exit_code 0 $"piped shell uninstall failed: ($piped.stderr)"
        assert (($piped.stdout + $piped.stderr) | str contains "complete, byte-verified backup") "shell uninstall did not describe the complete backup"
        assert (not ($nurl | path exists)) "shell uninstall left the installation"
        let backups = (child-paths-starting $home ".nurl-backup-")
        assert equal ($backups | length) 1 "shell uninstall did not create exactly one backup"
        let backup = ($backups | first)
        assert equal (open ($backup | path join "collections" "demo" "request.nuon") --raw) $expected_collection
        assert equal (open ($backup | path join "chains" "flow.nuon") --raw) $expected_chain
        assert equal (open ($backup | path join "history" "entry.nuon") --raw) $expected_history
        assert equal (open ($backup | path join "config.nuon") --raw) $expected_config
        assert equal (open ($backup | path join "secrets.nuon") --raw) $expected_secrets
        let resolved_after = (open ($resolved_config | path join "config.nu") --raw)
        assert ($resolved_after | str contains "# comment source ~/.nurl/api.nu") "commented Nurl mention was removed"
        assert ($resolved_after | str contains "alias nurl-note") "alias mentioning Nurl was removed"
        assert (not ($resolved_after | str contains "# >>> nurl >>>")) "owned sentinel survived uninstall"
        assert (not ($resolved_after | str ends-with "\n")) "config trailing-newline state changed"
        assert equal (open ($legacy_config | path join "config.nu") --raw) "legacy keep\n" "legacy config path was not cleaned precisely"

        let failure_home = ($fixture | path join "copy failure home")
        let failure_nurl = ($failure_home | path join ".nurl")
        mkdir ($failure_nurl | path join "collections")
        "must survive" | save -f ($failure_nurl | path join "collections" "data.nuon")
        let fail_tools = ($fixture | path join "fail-tools")
        mkdir $fail_tools
        '#!/bin/sh
exit 73
' | str replace --all "\r" "" | save -f ($fail_tools | path join "cp")
        let bash_cp = (path-for-bash $bash ($fail_tools | path join "cp"))
        let chmod_result = (^$bash -lc $"chmod 700 (quote-for-bash $bash_cp)" | complete)
        assert equal $chmod_result.exit_code 0
        let fail_environment = (
            "HOME=" + (quote-for-bash (path-for-bash $bash $failure_home))
            + " PATH=" + (quote-for-bash $"(path-for-bash $bash $fail_tools):($bash_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_ASSUME_YES=1"
        )
        let copy_failure = (^$bash -lc $"($fail_environment) /bin/bash (quote-for-bash $script)" | complete)
        assert ($copy_failure.exit_code != 0) "forced backup copy failure unexpectedly succeeded"
        assert ($failure_nurl | path exists) "forced backup copy failure removed Nurl"
        assert equal (open ($failure_nurl | path join "collections" "data.nuon") --raw) "must survive"
        assert ((child-paths-starting $failure_home ".nurl-backup-") | is-empty) "forced copy failure left a success-shaped backup"
        null
    } catch {|error| $error }
    cleanup $fixture
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def test-shell-config-ownership-and-resolution [] {
    let bash_candidates = (which bash | where type == "external" | get path? | default [])
    if ($bash_candidates | is-empty) {
        error make {msg: "SKIP: Bash is unavailable for shell config fixtures"}
    }
    let bash = ($bash_candidates | first)
    let fixture = (make-temp-dir "shell-config")
    let failure = try {
        let tools = ($fixture | path join "tools")
        mkdir $tools
        shell-installer-tools $tools $bash
        let home = ($fixture | path join "home")
        let resolved = ($fixture | path join "resolved")
        mkdir $home
        mkdir $resolved
        let config = ($resolved | path join "config.nu")
        let original = "# commented source ~/.nurl/api.nu\r\nalias nurl-note = echo ~/.nurl/api.nu\r\n# tail"
        $original | save -f $config
        let installer = (path-for-bash $bash ($env.NURL_REPO_ROOT | path join "install.sh"))
        let uninstaller = (path-for-bash $bash ($env.NURL_REPO_ROOT | path join "uninstall.sh"))
        let bash_home = (path-for-bash $bash $home)
        let bash_tools = (path-for-bash $bash $tools)
        let bash_resolved = (path-for-bash $bash $resolved)
        let base_environment = (
            "HOME=" + (quote-for-bash $bash_home)
            + " PATH=" + (quote-for-bash $"($bash_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash $bash_resolved)
            + " NURL_INSTALLER_NU_VERSION=0.113.1"
            + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
            + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "curl.log")))
            + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "downloads.log")))
        )
        let installed = (^$bash -lc $"($base_environment) /bin/bash (quote-for-bash $installer)" | complete)
        assert equal $installed.exit_code 0 $"shell config install failed: ($installed.stderr)"
        let configured = (open $config --raw)
        assert equal ($configured | split row "# >>> nurl >>>" | length) 2 "installer did not add exactly one sentinel"
        assert ($configured | str contains "# commented source ~/.nurl/api.nu") "installer removed a commented mention"
        assert ($configured | str contains "alias nurl-note") "installer removed an alias mention"
        assert (not ($configured | str replace --all "\r\n" "" | str contains "\r")) $"installer changed CRLF discipline: ($configured | encode hex)"
        assert (not ($configured | str ends-with "\n")) "installer changed trailing-newline state"
        let repeated = (^$bash -lc $"($base_environment) /bin/bash (quote-for-bash $installer)" | complete)
        assert equal $repeated.exit_code 0 $"idempotent shell install failed: ($repeated.stderr)"
        assert equal (open $config --raw) $configured "idempotent shell install rewrote config"

        let legacy_config = ($home | path join ".config" "nushell")
        mkdir $legacy_config
        "# unrelated source ~/.nurl/api.nu\r\n# Nurl - Terminal API Client\r\nsource ~/.nurl/api.nu\r\nlegacy keep" | save -f ($legacy_config | path join "config.nu")
        let removed = (^$bash -lc $"($base_environment) /bin/bash (quote-for-bash $uninstaller) --yes" | complete)
        assert equal $removed.exit_code 0 $"shell config uninstall failed: ($removed.stderr)"
        assert equal (open $config --raw) $original "sentinel add/remove did not restore config bytes"
        assert equal (open ($legacy_config | path join "config.nu") --raw) "# unrelated source ~/.nurl/api.nu\r\nlegacy keep" "legacy cleanup was broad or lossy"

        let xdg_home = ($fixture | path join "xdg-home")
        let xdg_root = ($fixture | path join "xdg-root")
        mkdir $xdg_home
        mkdir $xdg_root
        let xdg_environment = (
            "HOME=" + (quote-for-bash (path-for-bash $bash $xdg_home))
            + " XDG_CONFIG_HOME=" + (quote-for-bash (path-for-bash $bash $xdg_root))
            + " PATH=" + (quote-for-bash $"($bash_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_INSTALLER_CONFIG_EMPTY=1"
            + " NURL_INSTALLER_NU_VERSION=0.113.1"
            + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
            + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "xdg-curl.log")))
            + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "xdg-downloads.log")))
        )
        let xdg_install = (^$bash -lc $"($xdg_environment) /bin/bash (quote-for-bash $installer)" | complete)
        assert equal $xdg_install.exit_code 0 $"XDG shell install failed: ($xdg_install.stderr)"
        assert (($xdg_root | path join "nushell" "config.nu") | path exists) "shell installer ignored XDG_CONFIG_HOME fallback"
        let xdg_remove = (^$bash -lc $"($xdg_environment) /bin/bash (quote-for-bash $uninstaller) --yes" | complete)
        assert equal $xdg_remove.exit_code 0 $"XDG shell uninstall failed: ($xdg_remove.stderr)"
        assert equal (open ($xdg_root | path join "nushell" "config.nu") --raw) "" "XDG config sentinel was not removed"
        null
    } catch {|error| $error }
    cleanup $fixture
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def test-powershell-config-and-host-safety [] {
    if $nu.os-info.name != "windows" {
        error make {msg: "SKIP: PowerShell packaging behavior is Windows-specific"}
    }
    let fixture = (make-temp-dir "powershell-config")
    let failure = try {
        let tools = ($fixture | path join "tools")
        let home = ($fixture | path join "home")
        let appdata = ($fixture | path join "appdata")
        let resolved = ($fixture | path join "resolved")
        mkdir $tools
        mkdir $home
        mkdir $appdata
        mkdir $resolved
        compile-powershell-installer-curl $tools
        let config = ($resolved | path join "config.nu")
        let original_text = "# comment source ~/.nurl/api.nu\r\nalias nurl-note = echo ~/.nurl/api.nu\r\n# tail"
        let write_utf16 = '[System.IO.File]::WriteAllText($env:NURL_TEST_CONFIG_PATH, $env:NURL_TEST_CONFIG_TEXT, [System.Text.UnicodeEncoding]::new($false, $true))'
        let written = (with-env {NURL_TEST_CONFIG_PATH: $config, NURL_TEST_CONFIG_TEXT: $original_text} {
            ^powershell.exe -NoProfile -NonInteractive -Command $write_utf16 | complete
        })
        assert equal $written.exit_code 0 $"could not create UTF-16 config fixture: ($written.stderr)"
        let original_bytes = (open $config --raw)
        let installer_harness = (powershell-installer-harness $fixture)
        let install_result = (with-env {
            NURL_INSTALLER_NU_VERSION: "0.113.1"
            NURL_INSTALLER_CONFIG_DIR: $resolved
            NURL_INSTALLER_CURL_VERSION_LINE: "curl 8.13.0 libcurl/8.13.0"
            NURL_INSTALLER_CURL_EXIT: "0"
            NURL_INSTALLER_CURL_STDERR: ""
            NURL_INSTALLER_CURL_LOG: ($fixture | path join "curl.log")
            NURL_INSTALLER_DOWNLOAD_LOG: ($fixture | path join "downloads.log")
            NURL_INSTALLER_DOWNLOAD_COUNT: ($fixture | path join "download-count")
        } {
            ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer_harness ($env.NURL_REPO_ROOT | path join "install.ps1") $home $appdata $tools | complete
        })
        assert equal $install_result.exit_code 0 $"PowerShell config install failed: ($install_result.stderr)"
        let read_text = '[System.IO.File]::ReadAllText($env:NURL_TEST_CONFIG_PATH)'
        let configured_result = (with-env {NURL_TEST_CONFIG_PATH: $config} {
            ^powershell.exe -NoProfile -NonInteractive -Command $read_text | complete
        })
        assert equal $configured_result.exit_code 0
        let configured = $configured_result.stdout
        assert ($configured | str contains "# >>> nurl >>>") "PowerShell installer omitted the sentinel"
        assert ($configured | str contains "# comment source ~/.nurl/api.nu") "PowerShell installer removed a comment mention"
        assert ($configured | str contains "alias nurl-note") "PowerShell installer removed an alias mention"
        let encoding_probe = '[System.BitConverter]::ToString([System.IO.File]::ReadAllBytes($env:NURL_TEST_CONFIG_PATH)[0..1])'
        let encoding_result = (with-env {NURL_TEST_CONFIG_PATH: $config} {
            ^powershell.exe -NoProfile -NonInteractive -Command $encoding_probe | complete
        })
        assert equal ($encoding_result.stdout | str trim) "FF-FE" "PowerShell installer did not preserve UTF-16 LE encoding"

        let legacy_dir = ($appdata | path join "nushell")
        mkdir $legacy_dir
        let legacy_config = ($legacy_dir | path join "config.nu")
        "# unrelated source ~/.nurl/api.nu\r\n# Nurl - Terminal API Client\r\nsource ~/.nurl/api.nu\r\nlegacy keep" | save -f $legacy_config
        let uninstall_harness = ($fixture | path join "run-uninstaller.ps1")
        'param($Uninstaller, $HomePath, $AppDataPath, $ToolsPath)
$env:USERPROFILE = $HomePath
$env:HOME = $HomePath
$env:APPDATA = $AppDataPath
$env:Path = $ToolsPath
& $Uninstaller -Yes
' | save -f $uninstall_harness
        let uninstall_result = (with-env {NURL_INSTALLER_CONFIG_DIR: $resolved} {
            ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $uninstall_harness ($env.NURL_REPO_ROOT | path join "uninstall.ps1") $home $appdata $tools | complete
        })
        assert equal $uninstall_result.exit_code 0 $"PowerShell config uninstall failed: ($uninstall_result.stderr)"
        assert equal (open $config --raw) $original_bytes "PowerShell sentinel add/remove did not preserve encoding/EOL/trailing newline"
        assert equal (open $legacy_config --raw) "# unrelated source ~/.nurl/api.nu\r\nlegacy keep" "PowerShell legacy cleanup was broad or lossy"
        let backups = (child-paths-starting $home ".nurl-backup-")
        assert equal ($backups | length) 1 "PowerShell uninstall did not create a verified backup"

        let empty_home = ($fixture | path join "empty-home")
        let empty_appdata = ($fixture | path join "empty-appdata")
        let empty_resolved = ($fixture | path join "empty-resolved")
        mkdir ($empty_home | path join ".nurl")
        mkdir $empty_appdata
        mkdir $empty_resolved
        let empty_config = ($empty_resolved | path join "config.nu")
        let write_empty_fixture = '[System.IO.File]::WriteAllText($env:NURL_TEST_CONFIG_PATH, "# >>> nurl >>>`r`nsource ~/.nurl/api.nu`r`n# <<< nurl <<<`r`n", [System.Text.UTF8Encoding]::new($false))'
        let empty_written = (with-env {NURL_TEST_CONFIG_PATH: $empty_config} {
            ^powershell.exe -NoProfile -NonInteractive -Command $write_empty_fixture | complete
        })
        assert equal $empty_written.exit_code 0 $"could not create sentinel-only config: ($empty_written.stderr)"
        let empty_result = (with-env {NURL_INSTALLER_CONFIG_DIR: $empty_resolved} {
            ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $uninstall_harness ($env.NURL_REPO_ROOT | path join "uninstall.ps1") $empty_home $empty_appdata $tools | complete
        })
        assert equal $empty_result.exit_code 0 $"PowerShell sentinel-only uninstall failed: ($empty_result.stderr)"
        assert equal (ls $empty_config | first | get size) 0B "PowerShell sentinel-only config was not emptied safely"

        let reparse_home = ($fixture | path join "reparse-home")
        let reparse_appdata = ($fixture | path join "reparse-appdata")
        let reparse_external = ($fixture | path join "reparse-external")
        let reparse_link = ($reparse_home | path join ".nurl" "collections" "linked")
        mkdir ($reparse_home | path join ".nurl" "collections")
        mkdir $reparse_appdata
        mkdir $reparse_external
        "external data" | save -f ($reparse_external | path join "keep.txt")
        let create_junction = 'New-Item -ItemType Junction -Path $env:NURL_TEST_LINK -Target $env:NURL_TEST_TARGET | Out-Null'
        let junction_result = (with-env {NURL_TEST_LINK: $reparse_link, NURL_TEST_TARGET: $reparse_external} {
            ^powershell.exe -NoProfile -NonInteractive -Command $create_junction | complete
        })
        assert equal $junction_result.exit_code 0 $"could not create reparse-point fixture: ($junction_result.stderr)"
        let reparse_result = (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $uninstall_harness ($env.NURL_REPO_ROOT | path join "uninstall.ps1") $reparse_home $reparse_appdata $tools | complete)
        assert ($reparse_result.exit_code != 0) "PowerShell uninstall accepted nested reparse data"
        assert (($reparse_result.stdout + $reparse_result.stderr) | str contains "verifiable backup") "PowerShell reparse rejection was not actionable"
        assert (($reparse_home | path join ".nurl") | path exists) "PowerShell reparse rejection removed Nurl"
        assert equal (open ($reparse_external | path join "keep.txt") --raw) "external data" "PowerShell reparse rejection damaged external data"
        assert ((child-paths-starting $reparse_home ".nurl-backup-") | is-empty) "PowerShell reparse rejection created a success-shaped backup"

        let installer_source = (open ($env.NURL_REPO_ROOT | path join "install.ps1") --raw)
        let uninstaller_source = (open ($env.NURL_REPO_ROOT | path join "uninstall.ps1") --raw)
        assert equal ($installer_source | parse --regex '(?m)^\s*exit(?:\s|$)' | length) 0 "PowerShell installer contains a host-killing exit"
        assert equal ($uninstaller_source | parse --regex '(?m)^\s*exit(?:\s|$)' | length) 0 "PowerShell uninstaller contains a host-killing exit"

        let host_home = ($fixture | path join "host-home")
        let host_appdata = ($fixture | path join "host-appdata")
        mkdir $host_home
        mkdir $host_appdata
        let install_host_harness = ($fixture | path join "install-host.ps1")
        'param($Installer, $HomePath, $AppDataPath, $ToolsPath)
$env:USERPROFILE = $HomePath
$env:HOME = $HomePath
$env:APPDATA = $AppDataPath
$env:Path = $ToolsPath
$env:NURL_INSTALLER_NU_VERSION = "0.88.0"
$script = [System.IO.File]::ReadAllText($Installer)
try { Invoke-Expression $script } catch { Write-Output "CAUGHT-INSTALL" }
Write-Output "HOST-ALIVE-INSTALL"
' | save -f $install_host_harness
        let install_host = (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $install_host_harness ($env.NURL_REPO_ROOT | path join "install.ps1") $host_home $host_appdata $tools | complete)
        assert equal $install_host.exit_code 0 $"PowerShell install failure terminated the host: ($install_host.stderr)"
        assert ($install_host.stdout | str contains "CAUGHT-INSTALL") "PowerShell install failure was not catchable"
        assert ($install_host.stdout | str contains "HOST-ALIVE-INSTALL") "PowerShell install failure killed its host"

        mkdir ($host_home | path join ".nurl")
        let decline_harness = ($fixture | path join "decline-host.ps1")
        'param($Uninstaller, $HomePath, $AppDataPath, $ToolsPath)
$env:USERPROFILE = $HomePath
$env:HOME = $HomePath
$env:APPDATA = $AppDataPath
$env:Path = $ToolsPath
function Read-Host { return "n" }
$script = [System.IO.File]::ReadAllText($Uninstaller)
Invoke-Expression $script
Write-Output "HOST-ALIVE-DECLINE"
' | save -f $decline_harness
        let decline = (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $decline_harness ($env.NURL_REPO_ROOT | path join "uninstall.ps1") $host_home $host_appdata $tools | complete)
        assert equal $decline.exit_code 0 $"PowerShell decline terminated the host: ($decline.stderr)"
        assert ($decline.stdout | str contains "Cancelled") "PowerShell decline was not honored"
        assert ($decline.stdout | str contains "HOST-ALIVE-DECLINE") "PowerShell decline killed its host"
        assert (($host_home | path join ".nurl") | path exists) "PowerShell decline mutated Nurl"

        let failure_harness = ($fixture | path join "failure-host.ps1")
        'param($Uninstaller, $HomePath, $AppDataPath, $ToolsPath)
$env:USERPROFILE = $HomePath
$env:HOME = $HomePath
$env:APPDATA = $AppDataPath
$env:Path = $ToolsPath
$env:NURL_ASSUME_YES = "1"
function Copy-Item { throw "forced copy failure" }
$script = [System.IO.File]::ReadAllText($Uninstaller)
try { Invoke-Expression $script } catch { Write-Output "CAUGHT-UNINSTALL" }
Write-Output "HOST-ALIVE-UNINSTALL"
' | save -f $failure_harness
        let host_failure = (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $failure_harness ($env.NURL_REPO_ROOT | path join "uninstall.ps1") $host_home $host_appdata $tools | complete)
        assert equal $host_failure.exit_code 0 $"PowerShell uninstall failure terminated the host: ($host_failure.stderr)"
        assert ($host_failure.stdout | str contains "CAUGHT-UNINSTALL") "PowerShell uninstall failure was not catchable"
        assert ($host_failure.stdout | str contains "HOST-ALIVE-UNINSTALL") "PowerShell uninstall failure killed its host"
        assert (($host_home | path join ".nurl") | path exists) "PowerShell uninstall failure removed Nurl"
        null
    } catch {|error| $error }
    cleanup $fixture
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

def test-nushell-command-compatibility-floor [] {
    let forbidden = ["str downcase" "str upcase" "str escape-regex"]
    let modules = (
        ls ($env.NURL_REPO_ROOT | path join "nu_modules")
        | where type == file
        | where {|entry| $entry.name | str ends-with ".nu" }
    )
    for module in $modules {
        let source = (open $module.name --raw)
        for command in $forbidden {
            assert (not ($source | str contains $command)) $"($module.name | path basename) uses unsupported or deprecated command '($command)'"
        }
    }
    assert (ascii-equal-ignore-case "M+SEARCH" "m+search") "ASCII protocol-token comparison should ignore letter case"
    assert (not (ascii-equal-ignore-case "M+SEARCH" "MSEARCH")) "ASCII protocol-token comparison should treat metacharacters literally"
    assert equal ("m-search" | ascii-upcase) "M-SEARCH" "TUI method normalization should uppercase ASCII letters"
}

def test-installer-script-syntax [] {
    let repo = $env.NURL_REPO_ROOT
    let ps_paths = [
        ($repo | path join "install.ps1")
        ($repo | path join "uninstall.ps1")
    ]
    let ps_command = '& { param($path) $tokens = $null; $errors = $null; [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null; if ($errors.Count -gt 0) { $errors | ForEach-Object { [Console]::Error.WriteLine($_.Message) }; exit 1 } }'
    let powershell = if (which pwsh | is-not-empty) {
        "pwsh"
    } else if (which powershell.exe | is-not-empty) {
        "powershell.exe"
    } else {
        null
    }
    if $powershell != null {
        for ps_path in $ps_paths {
            let ps_parse = (^$powershell -NoProfile -NonInteractive -Command $ps_command $ps_path | complete)
            assert equal $ps_parse.exit_code 0 $"PowerShell script syntax failed for ($ps_path | path basename): ($ps_parse.stderr)"
        }
    } else {
        let modules = (installer-modules ($ps_paths | first) '$Modules = @(')
        assert (($modules | length) > 0) "PowerShell module declaration must remain parseable without PowerShell"
    }

    if (which bash | is-not-empty) {
        for shell_script in ["install.sh" "uninstall.sh"] {
            let raw = (open ($repo | path join $shell_script) --raw)
            assert (not ($raw | str contains "\r")) $"($shell_script) contains a carriage return"
            let sh_parse = ($raw | ^bash -n | complete)
            assert equal $sh_parse.exit_code 0 $"shell script syntax failed for ($shell_script): ($sh_parse.stderr)"
        }
    } else {
        let modules = (installer-modules ($repo | path join "install.sh") "MODULES=(")
        assert (($modules | length) > 0) "shell module declaration must remain parseable without Bash"
    }
    let attributes = (open ($repo | path join ".gitattributes") --raw)
    assert ($attributes | str contains "*.sh text eol=lf") "shell line-ending policy is missing"
    assert ($attributes | str contains "*.ps1 text eol=crlf") "PowerShell text policy is missing"
    for shell_script in ["install.sh" "uninstall.sh"] {
        let shell_source = (open ($repo | path join $shell_script) --raw)
        assert ($shell_source | str contains "Library/Application Support/nushell") $"($shell_script) is missing the macOS config fallback"
        assert (not ($shell_source | str contains "set -euo pipefail")) $"($shell_script) uses nounset, which breaks empty arrays on macOS Bash 3.2"
    }
}

def test-command-discovery-source-duplicates [] {
    let repo = $env.NURL_REPO_ROOT
    let discover = ($repo | path join ".github" "skills" "validate-nurl-api" "scripts" "discover-commands.nu")
    let current = (^$nu.current-exe --no-config-file $discover --root $repo --check-help --json | complete)
    assert equal $current.exit_code 0 $"current command discovery failed: ($current.stderr)"
    let current_data = ($current.stdout | from json)
    assert equal $current_data.defined_count 85
    assert equal $current_data.defined_export_count 85
    assert equal $current_data.covered_count 85
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

def test-saml-secret-template-consistency [] {
    let repo = $env.NURL_REPO_ROOT
    let templates = [
        {name: "api init", path: ($repo | path join "nu_modules" "mod.nu")}
        {name: "PowerShell installer", path: ($repo | path join "install.ps1")}
        {name: "shell installer", path: ($repo | path join "install.sh")}
    ]
    for template in $templates {
        let source = (open $template.path --raw)
        let declarations = ($source | parse --regex '(?m)^\s*saml_tokens:\s*\{\}\s*$')
        assert equal ($declarations | length) 1 $"($template.name) must declare exactly one empty SAML token bucket"
    }

    let root = (make-temp-dir "saml-template")
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let secrets = (open ($root | path join "secrets.nuon"))
        assert equal ($secrets | columns) ["tokens" "saml_tokens" "oauth" "api_keys" "basic_auth"]
        assert equal $secrets.saml_tokens {}
        null
    } catch {|error| $error }
    cleanup $root
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def test-saml-help-coverage-integration [] {
    let repo = $env.NURL_REPO_ROOT
    let discover = ($repo | path join ".github" "skills" "validate-nurl-api" "scripts" "discover-commands.nu")
    let manifest = ($repo | path join ".github" "skills" "validate-nurl-api" "coverage.nuon")
    let result = (^$nu.current-exe --no-config-file $discover --root $repo --manifest $manifest --check-help --json | complete)
    assert equal $result.exit_code 0 $"SAML help/coverage discovery failed: ($result.stderr)"
    let discovered = ($result.stdout | from json)
    let expected = [
        "api auth saml set"
        "api auth saml get"
        "api auth saml delete"
    ]
    for command in $expected {
        assert ($command in $discovered.help_commands) $"SAML command is absent from api help: ($command)"
    }
    let coverage = (open $manifest | where command in $expected | sort-by command)
    assert equal ($coverage | get command) ($expected | sort)
    for row in $coverage {
        assert equal $row.kind command $"SAML coverage entry has the wrong kind: ($row.command)"
        assert equal $row.group auth $"SAML coverage entry has the wrong group: ($row.command)"
        assert (not ($row.test | str trim | is-empty)) $"SAML coverage entry has no runnable test: ($row.command)"
    }
    let help_source = (open ($repo | path join "nu_modules" "mod.nu") --raw)
    assert ($help_source | str contains "SAML \\(stored\\):") "api help omitted the stored SAML auth example"
    assert ($help_source | str contains "SAML \\(inline\\):") "api help omitted the inline SAML auth example"
}

export def run-suite-packaging []: nothing -> list<record> {
    print $"\n(ansi yellow)── Installer packaging and discovery ──(ansi reset)"
    [
        (run-test "fresh installer payloads include and source every transitive module" { test-installer-module-payloads })
        (run-test "runtime modules keep the documented Nushell command floor" { test-nushell-command-compatibility-floor })
        (run-test "installer scripts remain syntactically valid" { test-installer-script-syntax })
        (run-test "PowerShell installer rejects unsafe curl probes before mutation" { test-powershell-installer-curl-preflight })
        (run-test "shell installer rejects unsafe curl probes before mutation" { test-shell-installer-curl-preflight })
        (run-test "both installers reject Nushell below 0.89.0 before mutation" { test-installer-nushell-floor })
        (run-test "both installers stage atomically and preserve existing bytes on late failure" { test-installer-atomic-staging })
        (run-test "shell uninstall requires explicit non-TTY consent and verifies complete backups" { test-shell-uninstall-backup-and-consent })
        (run-test "shell config ownership preserves unrelated bytes and honors resolved/XDG paths" { test-shell-config-ownership-and-resolution })
        (run-test "PowerShell config ownership and failures preserve the invoking host" { test-powershell-config-and-host-safety })
        (run-test "command discovery rejects duplicate source exports before deduplication" { test-command-discovery-source-duplicates })
        (run-test "command discovery exact-matches curated help entries" { test-command-discovery-exact-help })
        (run-test "SAML CRUD commands and examples stay synchronized across help and coverage" { test-saml-help-coverage-integration })
        (run-test "fresh runtime and installer secret templates include one empty SAML bucket" { test-saml-secret-template-consistency })
    ]
}
