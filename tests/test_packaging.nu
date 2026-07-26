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

function Move-Item {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$LiteralPath,
        [Parameter(Mandatory)]$Destination,
        [switch]$Force
    )
    if ($env:NURL_INSTALLER_INJECT_POST_PROMOTION -eq "1" -and
        [string]$Destination -like "*\nu_modules\auth.nu") {
        [System.IO.File]::WriteAllText(
            [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName([string]$Destination), "concurrent.txt"),
            "concurrent content"
        )
        throw "post-promotion failure sentinel"
    }
    if ($env:NURL_INSTALLER_FAIL_ROLLBACK_RESTORE -eq "1" -and
        [string]$LiteralPath -like "*\rollback\*") {
        throw "forced rollback restore failure"
    }
    if ($env:NURL_INSTALLER_MUTATE_CONFIG_PATH -and
        [string]$Destination -like "*\nu_modules\string-compat.nu") {
        [System.IO.File]::WriteAllText($env:NURL_INSTALLER_MUTATE_CONFIG_PATH, "concurrent config")
    }
    Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
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
                assert (($appdata | path join "nushell" "config.nu") | path exists) $"PowerShell installer did not configure Nushell for ($case.name): (($result.stdout + $result.stderr) | to nuon)"
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

        let fresh_concurrent_home = ($fixture | path join "shell-fresh-concurrent")
        let fresh_concurrent_tools = ($fixture | path join "shell-fresh-concurrent-tools")
        mkdir $fresh_concurrent_home
        mkdir $fresh_concurrent_tools
        cp ($tools | path join "nu") ($fresh_concurrent_tools | path join "nu")
        cp ($tools | path join "curl") ($fresh_concurrent_tools | path join "curl")
        '#!/bin/bash
source_path=""
for argument in "$@"; do
    if [[ "$argument" != -* ]]; then source_path="$argument"; break; fi
done
if [[ "$NURL_INSTALLER_INJECT_FRESH_DATA" == "1" && "$source_path" == *"/.config.nu.nurl."* && "$source_path" != *".rollback."* ]]; then
    printf "%s" "concurrent fresh data" > "$HOME/.nurl/only-copy.txt"
    exit 80
fi
exec /bin/mv "$@"
' | str replace --all "\r" "" | save -f ($fresh_concurrent_tools | path join "mv")
        let fresh_concurrent_chmod = (^$bash -lc $"chmod 700 (quote-for-bash (path-for-bash $bash ($fresh_concurrent_tools | path join 'nu'))) (quote-for-bash (path-for-bash $bash ($fresh_concurrent_tools | path join 'curl'))) (quote-for-bash (path-for-bash $bash ($fresh_concurrent_tools | path join 'mv')))" | complete)
        assert equal $fresh_concurrent_chmod.exit_code 0
        let fresh_concurrent_result = (^$bash -lc (
            "HOME=" + (quote-for-bash (path-for-bash $bash $fresh_concurrent_home))
            + " PATH=" + (quote-for-bash $"(path-for-bash $bash $fresh_concurrent_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_INSTALLER_NU_VERSION=0.113.1"
            + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
            + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "fresh-concurrent-curl.log")))
            + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "fresh-concurrent-downloads.log")))
            + " NURL_INSTALLER_INJECT_FRESH_DATA=1"
            + " /bin/bash " + (quote-for-bash $installer)
        ) | complete)
        assert ($fresh_concurrent_result.exit_code != 0) "fresh concurrent-data fixture unexpectedly succeeded"
        assert equal (open ($fresh_concurrent_home | path join ".nurl" "only-copy.txt") --raw) "concurrent fresh data" "fresh rollback deleted concurrent data"
        assert (($fresh_concurrent_result.stdout + $fresh_concurrent_result.stderr) | str contains "preserved the visible fresh installation") "fresh rollback did not report preserved concurrent data"
        assert ((child-paths-starting $fresh_concurrent_home ".nurl-stage.") | is-empty) "fresh preserved-data failure leaked an empty recovery stage"

        let created_cmp_home = ($fixture | path join "created-cmp-home")
        let created_cmp_config_dir = ($fixture | path join "created-cmp-config")
        let created_cmp_tools = ($fixture | path join "created-cmp-tools")
        mkdir $created_cmp_home
        mkdir $created_cmp_config_dir
        mkdir $created_cmp_tools
        cp ($tools | path join "nu") ($created_cmp_tools | path join "nu")
        cp ($tools | path join "curl") ($created_cmp_tools | path join "curl")
        '#!/bin/bash
if [[ "$*" == *"/dev/null /dev/null"* ]]; then exit 0; fi
destination="${!#}"
printf "%s\n" "# concurrent config data" >> "$destination"
exit 42
' | str replace --all "\r" "" | save -f ($created_cmp_tools | path join "cmp")
        let created_cmp_chmod = (^$bash -lc $"chmod 700 (quote-for-bash (path-for-bash $bash ($created_cmp_tools | path join 'nu'))) (quote-for-bash (path-for-bash $bash ($created_cmp_tools | path join 'curl'))) (quote-for-bash (path-for-bash $bash ($created_cmp_tools | path join 'cmp')))" | complete)
        assert equal $created_cmp_chmod.exit_code 0
        let created_cmp_environment = (
            "HOME=" + (quote-for-bash (path-for-bash $bash $created_cmp_home))
            + " PATH=" + (quote-for-bash $"(path-for-bash $bash $created_cmp_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $created_cmp_config_dir))
            + " NURL_INSTALLER_NU_VERSION=0.113.1"
            + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
            + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "created-cmp-curl.log")))
            + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "created-cmp-downloads.log")))
        )
        let created_cmp_result = (^$bash -lc $"($created_cmp_environment) /bin/bash (quote-for-bash $installer)" | complete)
        assert ($created_cmp_result.exit_code != 0) "post-config cmp failure unexpectedly succeeded"
        assert (($created_cmp_result.stdout + $created_cmp_result.stderr) | str contains "cmp exit 42") "post-config cmp failure did not distinguish tool error"
        let created_cmp_config = ($created_cmp_config_dir | path join "config.nu")
        assert ($created_cmp_config | path exists) "post-config cmp rollback deleted live config"
        assert ((open $created_cmp_config --raw) | str contains "concurrent config data") "post-config cmp rollback deleted concurrent config data"
        assert (($created_cmp_home | path join ".nurl") | path exists) "post-config cmp rollback deleted visible fresh install"
        assert ((child-paths-starting $created_cmp_home ".nurl-stage.") | is-empty) "post-config cmp rollback leaked empty stage"

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

        let rollback_fail_tools = ($fixture | path join "rollback-fail-tools")
        mkdir $rollback_fail_tools
        cp ($tools | path join "nu") ($rollback_fail_tools | path join "nu")
        cp ($tools | path join "curl") ($rollback_fail_tools | path join "curl")
        '#!/bin/bash
if [[ "$NURL_INSTALLER_FAIL_ROLLBACK_RESTORE" == "1" && "$*" == *"/rollback/"* ]]; then
    exit 75
fi
exec /bin/mv "$@"
' | str replace --all "\r" "" | save -f ($rollback_fail_tools | path join "mv")
        let rollback_fail_chmod = (^$bash -lc $"chmod 700 (quote-for-bash (path-for-bash $bash ($rollback_fail_tools | path join 'nu'))) (quote-for-bash (path-for-bash $bash ($rollback_fail_tools | path join 'curl'))) (quote-for-bash (path-for-bash $bash ($rollback_fail_tools | path join 'mv')))" | complete)
        assert equal $rollback_fail_chmod.exit_code 0
        let restore_failure_command = (
            "HOME=" + (quote-for-bash $bash_home)
            + " PATH=" + (quote-for-bash $"(path-for-bash $bash $rollback_fail_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $config_dir))
            + " NURL_INSTALLER_NU_VERSION=0.113.1"
            + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
            + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "shell-restore-fail-curl.log")))
            + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "shell-restore-fail-downloads.log")))
            + " NURL_INSTALLER_FAIL_ROLLBACK_RESTORE=1"
            + " /bin/bash " + (quote-for-bash $installer)
        )
        let restore_failure = (^$bash -lc $restore_failure_command | complete)
        assert ($restore_failure.exit_code != 0) "shell rollback-restore failure unexpectedly succeeded"
        assert (($restore_failure.stdout + $restore_failure.stderr) | str contains "rollback was incomplete") "shell rollback-restore failure was not reported"
        let recovery_stages = (child-paths-starting $home ".nurl-stage.")
        assert equal ($recovery_stages | length) 1 "shell rollback-restore failure deleted its recovery stage"
        assert (($recovery_stages | first | path join "rollback" "api.nu") | path exists) "shell rollback-restore failure deleted its backup"

        let config_fail_home = ($fixture | path join "config-temp-home")
        let config_fail_install = ($config_fail_home | path join ".nurl")
        let config_fail_dir = ($fixture | path join "config-temp-config")
        mkdir ($config_fail_install | path join "nu_modules")
        mkdir $config_fail_dir
        "old config-temp api" | save -f ($config_fail_install | path join "api.nu")
        let config_fail_config = ($config_fail_dir | path join "config.nu")
        let config_fail_original = "let config_failure_keep = true\n"
        $config_fail_original | save -f $config_fail_config
        let config_fail_api = (open ($config_fail_install | path join "api.nu") --raw)
        let config_fail_tools = ($fixture | path join "config-fail-tools")
        mkdir $config_fail_tools
        cp ($tools | path join "nu") ($config_fail_tools | path join "nu")
        cp ($tools | path join "curl") ($config_fail_tools | path join "curl")
        '#!/bin/bash
source_path=""
for argument in "$@"; do
    if [[ "$argument" != -* ]]; then source_path="$argument"; break; fi
done
if [[ "$source_path" == *"/.config.nu.nurl."* && "$source_path" != *".rollback."* ]]; then
    exit 76
fi
exec /bin/mv "$@"
' | str replace --all "\r" "" | save -f ($config_fail_tools | path join "mv")
        let config_fail_chmod = (^$bash -lc $"chmod 700 (quote-for-bash (path-for-bash $bash ($config_fail_tools | path join 'nu'))) (quote-for-bash (path-for-bash $bash ($config_fail_tools | path join 'curl'))) (quote-for-bash (path-for-bash $bash ($config_fail_tools | path join 'mv')))" | complete)
        assert equal $config_fail_chmod.exit_code 0
        let config_promotion_failure = (^$bash -lc (
            "HOME=" + (quote-for-bash (path-for-bash $bash $config_fail_home))
            + " PATH=" + (quote-for-bash $"(path-for-bash $bash $config_fail_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $config_fail_dir))
            + " NURL_INSTALLER_NU_VERSION=0.113.1"
            + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
            + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "config-fail-curl.log")))
            + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "config-fail-downloads.log")))
            + " /bin/bash " + (quote-for-bash $installer)
        ) | complete)
        assert ($config_promotion_failure.exit_code != 0) "shell config promotion failure unexpectedly succeeded"
        assert equal (open ($config_fail_install | path join "api.nu") --raw) $config_fail_api "shell config promotion failure did not restore api.nu"
        assert equal (open $config_fail_config --raw) $config_fail_original "shell config promotion failure did not restore config.nu"
        assert ((child-paths-starting $config_fail_dir ".config.nu.nurl.") | is-empty) "shell config promotion failure orphaned a config temp"
        assert ((child-paths-starting $config_fail_home ".nurl-stage.") | is-empty) "shell config promotion failure leaked staging"

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

            let injected_home = ($fixture | path join "powershell-injected-home")
            let injected_appdata = ($fixture | path join "powershell-injected-appdata")
            let injected_install = ($injected_home | path join ".nurl")
            mkdir $injected_install
            mkdir $injected_appdata
            "old injected api" | save -f ($injected_install | path join "api.nu")
            let injected_api = (open ($injected_install | path join "api.nu") --raw)
            let injected_result = (with-env {
                NURL_INSTALLER_NU_VERSION: "0.113.1"
                NURL_INSTALLER_CURL_VERSION_LINE: "curl 8.13.0 libcurl/8.13.0"
                NURL_INSTALLER_CURL_EXIT: "0"
                NURL_INSTALLER_CURL_STDERR: ""
                NURL_INSTALLER_CURL_LOG: ($fixture | path join "ps-injected-curl.log")
                NURL_INSTALLER_DOWNLOAD_LOG: ($fixture | path join "ps-injected-downloads.log")
                NURL_INSTALLER_DOWNLOAD_COUNT: ($fixture | path join "ps-injected-download-count")
                NURL_INSTALLER_FAIL_DOWNLOAD: ""
                NURL_INSTALLER_INJECT_POST_PROMOTION: "1"
            } {
                ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness ($env.NURL_REPO_ROOT | path join "install.ps1") $injected_home $injected_appdata $ps_tools | complete
            })
            assert ($injected_result.exit_code != 0) "PowerShell injected post-promotion failure unexpectedly succeeded"
            assert (($injected_result.stdout + $injected_result.stderr) | str contains "post-promotion failure sentinel") "PowerShell rollback masked the original failure"
            assert equal (open ($injected_install | path join "api.nu") --raw) $injected_api "PowerShell injected rollback did not restore api.nu"
            assert equal (open ($injected_install | path join "nu_modules" "concurrent.txt") --raw) "concurrent content" "PowerShell rollback deleted concurrent directory content"
            assert ((child-paths-starting $injected_home ".nurl-stage-") | is-empty) "PowerShell injected rollback leaked staging"

            let ps_config_fail_home = ($fixture | path join "powershell-config-fail-home")
            let ps_config_fail_appdata = ($fixture | path join "powershell-config-fail-appdata")
            let ps_config_fail_install = ($ps_config_fail_home | path join ".nurl")
            let ps_config_fail_dir = ($ps_config_fail_appdata | path join "nushell")
            let ps_config_fail_config = ($ps_config_fail_dir | path join "config.nu")
            mkdir $ps_config_fail_install
            mkdir $ps_config_fail_dir
            "old config-fail api" | save -f ($ps_config_fail_install | path join "api.nu")
            "original config" | save -f $ps_config_fail_config
            let ps_config_fail_api = (open ($ps_config_fail_install | path join "api.nu") --raw)
            let ps_config_fail_result = (with-env {
                NURL_INSTALLER_NU_VERSION: "0.113.1"
                NURL_INSTALLER_CURL_VERSION_LINE: "curl 8.13.0 libcurl/8.13.0"
                NURL_INSTALLER_CURL_EXIT: "0"
                NURL_INSTALLER_CURL_STDERR: ""
                NURL_INSTALLER_CURL_LOG: ($fixture | path join "ps-config-fail-curl.log")
                NURL_INSTALLER_DOWNLOAD_LOG: ($fixture | path join "ps-config-fail-downloads.log")
                NURL_INSTALLER_DOWNLOAD_COUNT: ($fixture | path join "ps-config-fail-download-count")
                NURL_INSTALLER_FAIL_DOWNLOAD: ""
                NURL_INSTALLER_MUTATE_CONFIG_PATH: $ps_config_fail_config
            } {
                ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness ($env.NURL_REPO_ROOT | path join "install.ps1") $ps_config_fail_home $ps_config_fail_appdata $ps_tools | complete
            })
            assert ($ps_config_fail_result.exit_code != 0) "PowerShell config promotion failure unexpectedly succeeded"
            assert (($ps_config_fail_result.stdout + $ps_config_fail_result.stderr) | str contains "config changed during installation") "PowerShell config conflict was not actionable"
            assert equal (open ($ps_config_fail_install | path join "api.nu") --raw) $ps_config_fail_api "PowerShell config promotion failure did not restore api.nu"
            assert equal (open $ps_config_fail_config --raw) "concurrent config" "PowerShell config conflict overwrote the concurrent edit"
            assert ((child-paths-starting $ps_config_fail_dir ".config.nu.nurl.") | is-empty) "PowerShell install config promotion failure leaked a temp"
            assert ((child-paths-starting $ps_config_fail_home ".nurl-stage-") | is-empty) "PowerShell config promotion failure leaked staging"

            let ps_restore_home = ($fixture | path join "powershell-restore-home")
            let ps_restore_appdata = ($fixture | path join "powershell-restore-appdata")
            let ps_restore_install = ($ps_restore_home | path join ".nurl")
            let ps_restore_modules = ($ps_restore_install | path join "nu_modules")
            mkdir ($ps_restore_modules | path join "auth.nu")
            mkdir $ps_restore_appdata
            "restore api" | save -f ($ps_restore_install | path join "api.nu")
            "restore mod" | save -f ($ps_restore_modules | path join "mod.nu")
            "preserve directory" | save -f ($ps_restore_modules | path join "auth.nu" "keep.txt")
            let ps_restore_result = (with-env {
                NURL_INSTALLER_NU_VERSION: "0.113.1"
                NURL_INSTALLER_CURL_VERSION_LINE: "curl 8.13.0 libcurl/8.13.0"
                NURL_INSTALLER_CURL_EXIT: "0"
                NURL_INSTALLER_CURL_STDERR: ""
                NURL_INSTALLER_CURL_LOG: ($fixture | path join "ps-restore-curl.log")
                NURL_INSTALLER_DOWNLOAD_LOG: ($fixture | path join "ps-restore-downloads.log")
                NURL_INSTALLER_DOWNLOAD_COUNT: ($fixture | path join "ps-restore-download-count")
                NURL_INSTALLER_FAIL_DOWNLOAD: ""
                NURL_INSTALLER_FAIL_ROLLBACK_RESTORE: "1"
            } {
                ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness ($env.NURL_REPO_ROOT | path join "install.ps1") $ps_restore_home $ps_restore_appdata $ps_tools | complete
            })
            assert ($ps_restore_result.exit_code != 0) "PowerShell rollback-restore failure unexpectedly succeeded"
            assert (($ps_restore_result.stdout + $ps_restore_result.stderr) | str contains "rollback was incomplete") "PowerShell rollback-restore failure was not reported"
            let ps_recovery_stages = (child-paths-starting $ps_restore_home ".nurl-stage-")
            assert equal ($ps_recovery_stages | length) 1 "PowerShell rollback-restore failure deleted its recovery stage"
            assert (($ps_recovery_stages | first | path join "rollback" "api.nu") | path exists) "PowerShell rollback-restore failure deleted its backup"
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
    let require_posix = ($env.NURL_REQUIRE_POSIX_PACKAGING? | default "") == "1"
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
        let has_setsid = (^$bash -lc "command -v setsid >/dev/null 2>&1" | complete)
        let non_tty_bash = if $has_setsid.exit_code == 0 {
            "setsid -w /bin/bash"
        } else {
            "/bin/bash"
        }
        let abort = (^$bash -lc $"($environment) ($non_tty_bash) (quote-for-bash $script) </dev/null" | complete)
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

        let failure_home = ($fixture | path join "detach failure home")
        let failure_nurl = ($failure_home | path join ".nurl")
        mkdir ($failure_nurl | path join "collections")
        "must survive" | save -f ($failure_nurl | path join "collections" "data.nuon")
        let fail_tools = ($fixture | path join "fail-tools")
        mkdir $fail_tools
        '#!/bin/bash
if [[ "$*" == *"/.nurl "* ]]; then
    exit 73
fi
exec /bin/mv "$@"
' | str replace --all "\r" "" | save -f ($fail_tools | path join "mv")
        let bash_mv = (path-for-bash $bash ($fail_tools | path join "mv"))
        let chmod_result = (^$bash -lc $"chmod 700 (quote-for-bash $bash_mv)" | complete)
        assert equal $chmod_result.exit_code 0
        let fail_environment = (
            "HOME=" + (quote-for-bash (path-for-bash $bash $failure_home))
            + " PATH=" + (quote-for-bash $"(path-for-bash $bash $fail_tools):($bash_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_ASSUME_YES=1"
        )
        let detach_failure = (^$bash -lc $"($fail_environment) /bin/bash (quote-for-bash $script)" | complete)
        assert ($detach_failure.exit_code != 0) "forced backup detach failure unexpectedly succeeded"
        assert ($failure_nurl | path exists) "forced backup detach failure removed Nurl"
        assert equal (open ($failure_nurl | path join "collections" "data.nuon") --raw) "must survive"
        assert ((child-paths-starting $failure_home ".nurl-backup-") | is-empty) "forced detach failure left a success-shaped backup"

        let temp_failure_home = ($fixture | path join "temp-failure-home")
        let temp_failure_nurl = ($temp_failure_home | path join ".nurl")
        let temp_failure_config_dir = ($fixture | path join "temp-failure-config")
        let temp_failure_config = ($temp_failure_config_dir | path join "config.nu")
        let temp_failure_tools = ($fixture | path join "temp-failure-tools")
        mkdir $temp_failure_nurl
        mkdir $temp_failure_config_dir
        mkdir $temp_failure_tools
        shell-installer-tools $temp_failure_tools $bash
        "must survive temp failure" | save -f ($temp_failure_nurl | path join "data.nuon")
        "# >>> nurl >>>\nsource ~/.nurl/api.nu\n# <<< nurl <<<\nkeep\n" | save -f $temp_failure_config
        let temp_failure_config_bytes = (open $temp_failure_config --raw)
        '#!/bin/bash
if [[ "$*" == *"/.config.nu.nurl."* ]]; then
    exit 78
fi
exec /usr/bin/mktemp "$@"
' | str replace --all "\r" "" | save -f ($temp_failure_tools | path join "mktemp")
        let temp_failure_chmod = (^$bash -lc $"chmod 700 (quote-for-bash (path-for-bash $bash ($temp_failure_tools | path join 'nu'))) (quote-for-bash (path-for-bash $bash ($temp_failure_tools | path join 'curl'))) (quote-for-bash (path-for-bash $bash ($temp_failure_tools | path join 'mktemp')))" | complete)
        assert equal $temp_failure_chmod.exit_code 0
        let temp_failure_environment = (
            "HOME=" + (quote-for-bash (path-for-bash $bash $temp_failure_home))
            + " PATH=" + (quote-for-bash $"(path-for-bash $bash $temp_failure_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $temp_failure_config_dir))
            + " NURL_ASSUME_YES=1"
        )
        let temp_failure = (^$bash -lc $"($temp_failure_environment) /bin/bash (quote-for-bash $script)" | complete)
        assert ($temp_failure.exit_code != 0) "uninstall config-temp preflight failure unexpectedly succeeded"
        assert (($temp_failure.stdout + $temp_failure.stderr) | str contains "Could not create an atomic temp") "uninstall config-temp failure was not actionable"
        assert ($temp_failure_nurl | path exists) "uninstall config-temp failure removed Nurl"
        assert equal (open $temp_failure_config --raw) $temp_failure_config_bytes "uninstall config-temp failure changed config"
        assert ((child-paths-starting $temp_failure_home ".nurl-backup-") | is-empty) "uninstall config-temp failure created a backup"
        assert ((child-paths-starting $temp_failure_config_dir ".config.nu.nurl.") | is-empty) "uninstall config-temp failure leaked a temp"

        let populate_failure_home = ($fixture | path join "populate-failure-home")
        let populate_failure_nurl = ($populate_failure_home | path join ".nurl")
        let populate_failure_config_dir = ($fixture | path join "populate-failure-config")
        let populate_failure_tools = ($fixture | path join "populate-failure-tools")
        mkdir $populate_failure_nurl
        mkdir $populate_failure_config_dir
        mkdir $populate_failure_tools
        shell-installer-tools $populate_failure_tools $bash
        "must survive population failure" | save -f ($populate_failure_nurl | path join "data.nuon")
        "# >>> nurl >>>\nsource ~/.nurl/api.nu\n# <<< nurl <<<\nkeep\n" | save -f ($populate_failure_config_dir | path join "config.nu")
        '#!/bin/bash
destination="${!#}"
if [[ "$destination" == *"/.config.nu.nurl."* ]]; then
    exit 79
fi
exec /bin/cp "$@"
' | str replace --all "\r" "" | save -f ($populate_failure_tools | path join "cp")
        let populate_failure_chmod = (^$bash -lc $"chmod 700 (quote-for-bash (path-for-bash $bash ($populate_failure_tools | path join 'nu'))) (quote-for-bash (path-for-bash $bash ($populate_failure_tools | path join 'curl'))) (quote-for-bash (path-for-bash $bash ($populate_failure_tools | path join 'cp')))" | complete)
        assert equal $populate_failure_chmod.exit_code 0
        let populate_failure_environment = (
            "HOME=" + (quote-for-bash (path-for-bash $bash $populate_failure_home))
            + " PATH=" + (quote-for-bash $"(path-for-bash $bash $populate_failure_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $populate_failure_config_dir))
            + " NURL_ASSUME_YES=1"
        )
        let populate_failure = (^$bash -lc $"($populate_failure_environment) /bin/bash (quote-for-bash $script)" | complete)
        assert ($populate_failure.exit_code != 0) "uninstall config-temp population failure unexpectedly succeeded"
        assert ($populate_failure_nurl | path exists) "uninstall config-temp population failure removed Nurl"
        assert ((child-paths-starting $populate_failure_home ".nurl-backup-") | is-empty) "uninstall config-temp population failure created a backup"
        assert ((child-paths-starting $populate_failure_config_dir ".config.nu.nurl.") | is-empty) "uninstall config-temp population failure leaked a temp"

        let pty_available = (^$bash -lc "command -v script >/dev/null 2>&1 && printf '' | script -qfec 'exit 0' /dev/null >/dev/null 2>&1" | complete)
        if $pty_available.exit_code == 0 {
            let pty_home = ($fixture | path join "pty-home")
            let pty_nurl = ($pty_home | path join ".nurl")
            let pty_tools = ($fixture | path join "pty-tools")
            let pty_config_dir = ($fixture | path join "pty-config")
            mkdir $pty_nurl
            mkdir $pty_tools
            mkdir $pty_config_dir
            shell-installer-tools $pty_tools $bash
            "pty data" | save -f ($pty_nurl | path join "data.nuon")
            "# >>> nurl >>>\nsource ~/.nurl/api.nu\n# <<< nurl <<<\nkeep\n" | save -f ($pty_config_dir | path join "config.nu")
            '#!/bin/bash
source_path=""
for argument in "$@"; do
    if [[ "$argument" != -* ]]; then source_path="$argument"; break; fi
done
if [[ "$NURL_UNINSTALL_FAIL_CONFIG" == "1" && "$source_path" == *"/.config.nu.nurl."* && "$source_path" != *".rollback."* ]]; then
    printf "%s\n" "forced config failure" >&2
    exit 77
fi
exec /bin/mv "$@"
' | str replace --all "\r" "" | save -f ($pty_tools | path join "mv")
            let pty_chmod = (^$bash -lc $"chmod 700 (quote-for-bash (path-for-bash $bash ($pty_tools | path join 'nu'))) (quote-for-bash (path-for-bash $bash ($pty_tools | path join 'curl'))) (quote-for-bash (path-for-bash $bash ($pty_tools | path join 'mv')))" | complete)
            assert equal $pty_chmod.exit_code 0
            let pty_environment = (
                "HOME=" + (quote-for-bash (path-for-bash $bash $pty_home))
                + " PATH=" + (quote-for-bash $"(path-for-bash $bash $pty_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
                + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $pty_config_dir))
                + " NURL_UNINSTALL_FAIL_CONFIG=1"
            )
            let piped_command = $"cat (quote-for-bash $script) | /bin/bash"
            let pty_inner = $"($pty_environment) /bin/bash -c (quote-for-bash $piped_command)"
            let pty_result = (^$bash -lc $"printf 'y\\n' | script -qfec (quote-for-bash $pty_inner) /dev/null" | complete)
            assert ($pty_result.exit_code != 0) "PTY piped uninstall config failure unexpectedly succeeded"
            let pty_output = $pty_result.stdout + $pty_result.stderr
            assert ($pty_output | str contains "Nushell config could not be updated") "PTY piped uninstall lost later stderr"
            assert ($pty_output | str contains "backup remains at") "PTY piped uninstall omitted the backup location"
            assert (not ($pty_nurl | path exists)) "PTY config failure left the detached install path"
            assert equal ((child-paths-starting $pty_home ".nurl-backup-") | length) 1 "PTY config failure did not preserve the verified backup"
        } else if $require_posix {
            error make {msg: "required Ubuntu PTY packaging capability is unavailable"}
        }

        let link_home = ($fixture | path join "link-home")
        let link_nurl = ($link_home | path join ".nurl")
        let link_target = ($fixture | path join "link-target")
        mkdir $link_nurl
        mkdir $link_target
        "external link target" | save -f ($link_target | path join "keep.txt")
        let link_result = (^$bash -lc $"ln -s (quote-for-bash (path-for-bash $bash $link_target)) (quote-for-bash (path-for-bash $bash ($link_nurl | path join 'linked')))" | complete)
        let actual_link = if $link_result.exit_code == 0 {
            ^$bash -lc $"test -L (quote-for-bash (path-for-bash $bash ($link_nurl | path join 'linked')))" | complete
        } else {
            {exit_code: 1}
        }
        if $actual_link.exit_code == 0 {
            let unsafe_result = (^$bash -lc (
                "HOME=" + (quote-for-bash (path-for-bash $bash $link_home))
                + " PATH=" + (quote-for-bash $"($bash_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
                + " NURL_ASSUME_YES=1"
                + " /bin/bash " + (quote-for-bash $script)
            ) | complete)
            assert ($unsafe_result.exit_code != 0) "shell uninstall accepted internal link data"
            assert (($unsafe_result.stdout + $unsafe_result.stderr) | str contains "verifiable backup") "shell internal-link rejection was not actionable"
            assert ($link_nurl | path exists) "shell internal-link rejection removed Nurl"
            assert equal (open ($link_target | path join "keep.txt") --raw) "external link target" "shell internal-link rejection damaged external data"
            assert ((child-paths-starting $link_home ".nurl-backup-") | is-empty) "shell internal-link rejection created a success-shaped backup"
        } else if $require_posix {
            error make {msg: "required Ubuntu symlink packaging capability is unavailable"}
        }
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
    let require_posix = ($env.NURL_REQUIRE_POSIX_PACKAGING? | default "") == "1"
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
        let restored_config = (open $config --raw)
        assert equal $restored_config $original $"sentinel add/remove did not restore config bytes: expected=($original | encode hex) actual=($restored_config | encode hex)"
        assert equal (open ($legacy_config | path join "config.nu") --raw) "# unrelated source ~/.nurl/api.nu\r\nlegacy keep" "legacy cleanup was broad or lossy"

        let migration_home = ($fixture | path join "migration-home")
        let migration_config_dir = ($fixture | path join "migration-config")
        let migration_config = ($migration_config_dir | path join "config.nu")
        let migration_original = "a\r\nsource ~/.nurl/api.nu\r\nz"
        let migration_expected = "a\r\n# >>> nurl >>>\r\nsource ~/.nurl/api.nu\r\n# <<< nurl <<<\r\nz"
        let migration_uninstalled = "a\r\nz"
        mkdir $migration_home
        mkdir $migration_config_dir
        $migration_original | save -f $migration_config
        let migration_chmod = (^$bash -lc $"chmod 640 (quote-for-bash (path-for-bash $bash $migration_config))" | complete)
        assert equal $migration_chmod.exit_code 0
        let migration_mode_before = (^$bash -lc $"stat -c '%a' (quote-for-bash (path-for-bash $bash $migration_config)) 2>/dev/null || stat -f '%Lp' (quote-for-bash (path-for-bash $bash $migration_config))" | complete)
        assert equal $migration_mode_before.exit_code 0
        let expected_migration_mode = ($migration_mode_before.stdout | str trim)
        let migration_environment = (
            "HOME=" + (quote-for-bash (path-for-bash $bash $migration_home))
            + " PATH=" + (quote-for-bash $"($bash_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $migration_config_dir))
            + " NURL_INSTALLER_NU_VERSION=0.113.1"
            + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
            + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "migration-curl.log")))
            + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "migration-downloads.log")))
        )
        let migration_install = (^$bash -lc $"($migration_environment) /bin/bash (quote-for-bash $installer)" | complete)
        assert equal $migration_install.exit_code 0 $"legacy migration install failed: ($migration_install.stderr)"
        assert equal (open $migration_config --raw) $migration_expected "non-final legacy CRLF migration changed EOLs or added a terminal newline"
        let migration_mode_after_install = (^$bash -lc $"stat -c '%a' (quote-for-bash (path-for-bash $bash $migration_config)) 2>/dev/null || stat -f '%Lp' (quote-for-bash (path-for-bash $bash $migration_config))" | complete)
        assert equal ($migration_mode_after_install.stdout | str trim) $expected_migration_mode $"shell installer changed config mode: expected=($expected_migration_mode) actual=($migration_mode_after_install.stdout | str trim)"
        let migration_remove = (^$bash -lc $"($migration_environment) /bin/bash (quote-for-bash $uninstaller) --yes" | complete)
        assert equal $migration_remove.exit_code 0 $"legacy migration uninstall failed: ($migration_remove.stderr)"
        assert equal (open $migration_config --raw) $migration_uninstalled "legacy migration uninstall did not preserve surrounding CRLF bytes"
        let migration_mode_after_remove = (^$bash -lc $"stat -c '%a' (quote-for-bash (path-for-bash $bash $migration_config)) 2>/dev/null || stat -f '%Lp' (quote-for-bash (path-for-bash $bash $migration_config))" | complete)
        assert equal ($migration_mode_after_remove.stdout | str trim) $expected_migration_mode $"shell uninstaller changed config mode: expected=($expected_migration_mode) actual=($migration_mode_after_remove.stdout | str trim)"

        let ln_failure_home = ($fixture | path join "ln-failure-home")
        let ln_failure_config_dir = ($fixture | path join "ln-failure-config")
        let ln_failure_tools = ($fixture | path join "ln-failure-tools")
        mkdir $ln_failure_home
        mkdir $ln_failure_config_dir
        mkdir $ln_failure_tools
        cp ($tools | path join "nu") ($ln_failure_tools | path join "nu")
        cp ($tools | path join "curl") ($ln_failure_tools | path join "curl")
        '#!/bin/bash
printf "%s\n" "ln: Operation not permitted" >&2
exit 81
' | str replace --all "\r" "" | save -f ($ln_failure_tools | path join "ln")
        let ln_failure_chmod = (^$bash -lc $"chmod 700 (quote-for-bash (path-for-bash $bash ($ln_failure_tools | path join 'nu'))) (quote-for-bash (path-for-bash $bash ($ln_failure_tools | path join 'curl'))) (quote-for-bash (path-for-bash $bash ($ln_failure_tools | path join 'ln')))" | complete)
        assert equal $ln_failure_chmod.exit_code 0
        let ln_failure_config = ($ln_failure_config_dir | path join "config.nu")
        let ln_failure_original = "let keep = 'hard-link-independent'\r\n"
        $ln_failure_original | save -f $ln_failure_config
        let ln_failure_environment = (
            "HOME=" + (quote-for-bash (path-for-bash $bash $ln_failure_home))
            + " PATH=" + (quote-for-bash $"(path-for-bash $bash $ln_failure_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $ln_failure_config_dir))
            + " NURL_INSTALLER_NU_VERSION=0.113.1"
            + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
            + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "ln-failure-curl.log")))
            + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "ln-failure-downloads.log")))
        )
        let ln_fresh = (^$bash -lc $"($ln_failure_environment) /bin/bash (quote-for-bash $installer)" | complete)
        assert equal $ln_fresh.exit_code 0 $"fresh install depended on hard links: ($ln_fresh.stderr)"
        assert (($ln_failure_config | path exists)) "fresh install lost config when ln failed"
        let configured_without_ln = (open $ln_failure_config --raw)
        assert ($configured_without_ln | str contains "# >>> nurl >>>") "fresh install did not configure without hard links"
        let ln_failure_user = ($ln_failure_home | path join ".nurl" "collections" "user.nuon")
        "hard-link user data" | save -f $ln_failure_user
        let ln_update = (^$bash -lc $"($ln_failure_environment) /bin/bash (quote-for-bash $installer)" | complete)
        assert equal $ln_update.exit_code 0 $"update install depended on hard links: ($ln_update.stderr)"
        assert equal (open $ln_failure_config --raw) $configured_without_ln "update install changed configured bytes when ln failed"
        assert equal (open $ln_failure_user --raw) "hard-link user data" "update install lost user data when ln failed"
        let ln_remove = (^$bash -lc $"($ln_failure_environment) /bin/bash (quote-for-bash $uninstaller) --yes" | complete)
        assert equal $ln_remove.exit_code 0 $"uninstall depended on hard links: ($ln_remove.stderr)"
        assert ($ln_failure_config | path exists) "uninstall lost config when ln failed"
        assert equal (open $ln_failure_config --raw) $ln_failure_original "uninstall did not restore config bytes when ln failed"
        let ln_backup = (child-paths-starting $ln_failure_home ".nurl-backup-" | first)
        assert equal (open ($ln_backup | path join "collections" "user.nuon") --raw) "hard-link user data" "uninstall ln failure lost backup data"

        let mvn_home = ($fixture | path join "mvn-home")
        let mvn_nurl = ($mvn_home | path join ".nurl")
        let mvn_config_dir = ($fixture | path join "mvn-config")
        let mvn_tools = ($fixture | path join "mvn-tools")
        mkdir $mvn_nurl
        mkdir $mvn_config_dir
        mkdir $mvn_tools
        cp ($tools | path join "nu") ($mvn_tools | path join "nu")
        cp ($tools | path join "curl") ($mvn_tools | path join "curl")
        '#!/bin/bash
if [[ "$1" == "-n" ]]; then
    printf "%s\n" "mv: illegal option -- n" >&2
    exit 64
fi
exec /bin/mv "$@"
' | str replace --all "\r" "" | save -f ($mvn_tools | path join "mv")
        let mvn_chmod = (^$bash -lc $"chmod 700 (quote-for-bash (path-for-bash $bash ($mvn_tools | path join 'nu'))) (quote-for-bash (path-for-bash $bash ($mvn_tools | path join 'curl'))) (quote-for-bash (path-for-bash $bash ($mvn_tools | path join 'mv')))" | complete)
        assert equal $mvn_chmod.exit_code 0
        "mvn Nurl data" | save -f ($mvn_nurl | path join "data.nuon")
        let mvn_config = ($mvn_config_dir | path join "config.nu")
        let mvn_original = "let mvn_keep = true\n"
        $mvn_original | save -f $mvn_config
        let mvn_environment = (
            "HOME=" + (quote-for-bash (path-for-bash $bash $mvn_home))
            + " PATH=" + (quote-for-bash $"(path-for-bash $bash $mvn_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $mvn_config_dir))
            + " NURL_INSTALLER_NU_VERSION=0.113.1"
            + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
            + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "mvn-curl.log")))
            + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "mvn-downloads.log")))
        )
        let mvn_install = (^$bash -lc $"($mvn_environment) /bin/bash (quote-for-bash $installer)" | complete)
        assert ($mvn_install.exit_code != 0) "installer accepted unsupported mv -n"
        assert (($mvn_install.stdout + $mvn_install.stderr) | str contains "not a safe no-clobber operation") "installer mv -n capability error was not actionable"
        assert equal (open $mvn_config --raw) $mvn_original "installer mv -n failure changed config"
        assert equal (open ($mvn_nurl | path join "data.nuon") --raw) "mvn Nurl data" "installer mv -n failure changed Nurl data"
        "# >>> nurl >>>\nsource ~/.nurl/api.nu\n# <<< nurl <<<\n" | save -f $mvn_config
        let mvn_owned = (open $mvn_config --raw)
        let mvn_uninstall = (^$bash -lc $"($mvn_environment) /bin/bash (quote-for-bash $uninstaller) --yes" | complete)
        assert ($mvn_uninstall.exit_code != 0) "uninstaller accepted unsupported mv -n"
        assert (($mvn_uninstall.stdout + $mvn_uninstall.stderr) | str contains "not a safe no-clobber operation") "uninstaller mv -n capability error was not actionable"
        assert equal (open $mvn_config --raw) $mvn_owned "uninstaller mv -n failure changed config"
        assert ($mvn_nurl | path exists) "uninstaller mv -n failure detached Nurl"

        let readonly_home = ($fixture | path join "readonly-home")
        let readonly_nurl = ($readonly_home | path join ".nurl")
        let readonly_config_dir = ($fixture | path join "readonly-config")
        let readonly_config = ($readonly_config_dir | path join "config.nu")
        mkdir $readonly_nurl
        mkdir $readonly_config_dir
        "readonly Nurl data" | save -f ($readonly_nurl | path join "data.nuon")
        let readonly_original = "let unrelated = true\n"
        $readonly_original | save -f $readonly_config
        ^$bash -lc $"chmod 444 (quote-for-bash (path-for-bash $bash $readonly_config))"
        let readonly_capability = (^$bash -lc $"test ! -w (quote-for-bash (path-for-bash $bash $readonly_config))" | complete)
        if $readonly_capability.exit_code == 0 {
            let readonly_environment = (
                "HOME=" + (quote-for-bash (path-for-bash $bash $readonly_home))
                + " PATH=" + (quote-for-bash $"($bash_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
                + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $readonly_config_dir))
                + " NURL_ASSUME_YES=1"
            )
            let readonly_noop = (^$bash -lc $"($readonly_environment) /bin/bash (quote-for-bash $uninstaller)" | complete)
            assert equal $readonly_noop.exit_code 0 $"uninstaller rejected unrelated read-only config: ($readonly_noop.stderr)"
            assert equal (open $readonly_config --raw) $readonly_original "uninstaller changed unrelated read-only config"

            let readonly_changed_home = ($fixture | path join "readonly-changed-home")
            let readonly_changed_nurl = ($readonly_changed_home | path join ".nurl")
            let readonly_changed_config_dir = ($fixture | path join "readonly-changed-config")
            let readonly_changed_config = ($readonly_changed_config_dir | path join "config.nu")
            mkdir $readonly_changed_nurl
            mkdir $readonly_changed_config_dir
            "must remain" | save -f ($readonly_changed_nurl | path join "data.nuon")
            let readonly_roundtrip_original = "let readonly_roundtrip = true\n"
            $readonly_roundtrip_original | save -f $readonly_changed_config
            ^$bash -lc $"chmod 444 (quote-for-bash (path-for-bash $bash $readonly_changed_config))"
            let readonly_mode_before = (^$bash -lc $"stat -c '%a' (quote-for-bash (path-for-bash $bash $readonly_changed_config)) 2>/dev/null || stat -f '%Lp' (quote-for-bash (path-for-bash $bash $readonly_changed_config))" | complete)
            let readonly_changed_environment = (
                "HOME=" + (quote-for-bash (path-for-bash $bash $readonly_changed_home))
                + " PATH=" + (quote-for-bash $"($bash_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
                + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $readonly_changed_config_dir))
                + " NURL_INSTALLER_NU_VERSION=0.113.1"
                + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
                + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "readonly-curl.log")))
                + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "readonly-downloads.log")))
                + " NURL_ASSUME_YES=1"
            )
            let readonly_install = (^$bash -lc $"($readonly_changed_environment) /bin/bash (quote-for-bash $installer)" | complete)
            assert equal $readonly_install.exit_code 0 $"installer rejected mode-0444 config: ($readonly_install.stderr)"
            assert ((open $readonly_changed_config --raw) | str contains "# >>> nurl >>>") "installer did not configure mode-0444 config"
            let readonly_mode_after_install = (^$bash -lc $"stat -c '%a' (quote-for-bash (path-for-bash $bash $readonly_changed_config)) 2>/dev/null || stat -f '%Lp' (quote-for-bash (path-for-bash $bash $readonly_changed_config))" | complete)
            assert equal ($readonly_mode_after_install.stdout | str trim) ($readonly_mode_before.stdout | str trim) "installer changed mode-0444 config mode"
            let readonly_changed = (^$bash -lc $"($readonly_changed_environment) /bin/bash (quote-for-bash $uninstaller)" | complete)
            assert equal $readonly_changed.exit_code 0 $"uninstaller rejected mode-0444 owned config: ($readonly_changed.stderr)"
            assert equal (open $readonly_changed_config --raw) $readonly_roundtrip_original "mode-0444 install/uninstall did not restore exact config bytes"
            let readonly_mode_after_remove = (^$bash -lc $"stat -c '%a' (quote-for-bash (path-for-bash $bash $readonly_changed_config)) 2>/dev/null || stat -f '%Lp' (quote-for-bash (path-for-bash $bash $readonly_changed_config))" | complete)
            assert equal ($readonly_mode_after_remove.stdout | str trim) ($readonly_mode_before.stdout | str trim) "uninstaller changed mode-0444 config mode"
            let readonly_backup = (child-paths-starting $readonly_changed_home ".nurl-backup-" | first)
            assert equal (open ($readonly_backup | path join "data.nuon") --raw) "must remain" "mode-0444 roundtrip lost Nurl data"
            ^$bash -lc $"chmod 600 (quote-for-bash (path-for-bash $bash $readonly_changed_config))"
        } else if $require_posix {
            error make {msg: "required Ubuntu read-only config capability is unavailable"}
        }
        ^$bash -lc $"chmod 600 (quote-for-bash (path-for-bash $bash $readonly_config))"

        let symlink_home = ($fixture | path join "symlink-home")
        let symlink_config_dir = ($symlink_home | path join ".config" "nushell")
        let symlink_dotfiles = ($symlink_home | path join "dotfiles")
        let symlink_target = ($symlink_dotfiles | path join "config.nu")
        let symlink_config = ($symlink_config_dir | path join "config.nu")
        mkdir $symlink_home
        mkdir $symlink_config_dir
        mkdir $symlink_dotfiles
        "dotfile content" | save -f $symlink_target
        let config_link_result = (^$bash -lc $"ln -s (quote-for-bash (path-for-bash $bash $symlink_target)) (quote-for-bash (path-for-bash $bash $symlink_config))" | complete)
        let actual_config_link = if $config_link_result.exit_code == 0 {
            ^$bash -lc $"test -L (quote-for-bash (path-for-bash $bash $symlink_config))" | complete
        } else {
            {exit_code: 1}
        }
        if $actual_config_link.exit_code == 0 {
            let symlink_environment = (
                "HOME=" + (quote-for-bash (path-for-bash $bash $symlink_home))
                + " PATH=" + (quote-for-bash $"($bash_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
                + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $symlink_config_dir))
                + " NURL_INSTALLER_NU_VERSION=0.113.1"
                + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
                + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "symlink-curl.log")))
                + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "symlink-downloads.log")))
            )
            let symlink_install = (^$bash -lc $"($symlink_environment) /bin/bash (quote-for-bash $installer)" | complete)
            assert equal $symlink_install.exit_code 0 $"symlinked config install failed: ($symlink_install.stderr)"
            assert ((open $symlink_target --raw) | str contains "# >>> nurl >>>") "symlinked config target was not configured"
            let link_after_install = (^$bash -lc $"test -L (quote-for-bash (path-for-bash $bash $symlink_config))" | complete)
            assert equal $link_after_install.exit_code 0 "installer replaced config symlink"
            let symlink_remove = (^$bash -lc $"($symlink_environment) /bin/bash (quote-for-bash $uninstaller) --yes" | complete)
            assert equal $symlink_remove.exit_code 0 $"symlinked config uninstall failed: ($symlink_remove.stderr)"
            assert equal (open $symlink_target --raw) "dotfile content" "symlinked config target did not round-trip"
            let link_after_remove = (^$bash -lc $"test -L (quote-for-bash (path-for-bash $bash $symlink_config))" | complete)
            assert equal $link_after_remove.exit_code 0 "uninstaller replaced config symlink"
        } else if $require_posix {
            error make {msg: "required Ubuntu config-file symlink capability is unavailable"}
        }

        let contained_home = ($fixture | path join "contained-home")
        let contained_nurl = ($contained_home | path join ".nurl")
        let contained_config_dir = ($contained_home | path join ".config" "nushell")
        let contained_config_link = ($contained_config_dir | path join "config.nu")
        mkdir $contained_nurl
        mkdir $contained_config_dir
        "managed api bytes" | save -f ($contained_nurl | path join "api.nu")
        let contained_link_result = (^$bash -lc $"ln -s (quote-for-bash (path-for-bash $bash ($contained_nurl | path join 'api.nu'))) (quote-for-bash (path-for-bash $bash $contained_config_link))" | complete)
        let actual_contained_link = if $contained_link_result.exit_code == 0 {
            ^$bash -lc $"test -L (quote-for-bash (path-for-bash $bash $contained_config_link))" | complete
        } else {
            {exit_code: 1}
        }
        if $actual_contained_link.exit_code == 0 {
            let contained_environment = (
                "HOME=" + (quote-for-bash (path-for-bash $bash $contained_home))
                + " PATH=" + (quote-for-bash $"($bash_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
                + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $contained_config_dir))
                + " NURL_INSTALLER_NU_VERSION=0.113.1"
                + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
                + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "contained-curl.log")))
                + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "contained-downloads.log")))
            )
            let contained_install = (^$bash -lc $"($contained_environment) /bin/bash (quote-for-bash $installer)" | complete)
            assert ($contained_install.exit_code != 0) "installer accepted config symlink into Nurl"
            assert (($contained_install.stdout + $contained_install.stderr) | str contains "must not resolve inside") "installer config-containment error was not actionable"
            assert equal (open ($contained_nurl | path join "api.nu") --raw) "managed api bytes" "installer config symlink corrupted managed Nurl bytes"
            assert ((child-paths-starting $contained_home ".nurl-stage.") | is-empty) "installer config-containment failure leaked staging"
            let contained_remove = (^$bash -lc $"($contained_environment) /bin/bash (quote-for-bash $uninstaller) --yes" | complete)
            assert ($contained_remove.exit_code != 0) "uninstaller accepted config symlink into Nurl"
            assert (($contained_remove.stdout + $contained_remove.stderr) | str contains "must not resolve inside") "uninstaller config-containment error was not actionable"
            assert ($contained_nurl | path exists) "uninstaller config-containment failure removed Nurl"
            assert ((child-paths-starting $contained_home ".nurl-backup-") | is-empty) "uninstaller config-containment failure created a backup"
        } else if $require_posix {
            error make {msg: "required Ubuntu contained config-file symlink capability is unavailable"}
        }

        let contained_dir_home = ($fixture | path join "contained-dir-home")
        let contained_dir_nurl = ($contained_dir_home | path join ".nurl")
        let contained_dir_link = ($contained_dir_home | path join "config-link")
        mkdir $contained_dir_nurl
        "managed config bytes" | save -f ($contained_dir_nurl | path join "config.nu")
        let contained_dir_result = (^$bash -lc $"ln -s (quote-for-bash (path-for-bash $bash $contained_dir_nurl)) (quote-for-bash (path-for-bash $bash $contained_dir_link))" | complete)
        let actual_contained_dir = if $contained_dir_result.exit_code == 0 {
            ^$bash -lc $"test -L (quote-for-bash (path-for-bash $bash $contained_dir_link))" | complete
        } else {
            {exit_code: 1}
        }
        if $actual_contained_dir.exit_code == 0 {
            let contained_dir_environment = (
                "HOME=" + (quote-for-bash (path-for-bash $bash $contained_dir_home))
                + " PATH=" + (quote-for-bash $"($bash_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
                + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $contained_dir_link))
                + " NURL_INSTALLER_NU_VERSION=0.113.1"
                + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
                + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "contained-dir-curl.log")))
                + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "contained-dir-downloads.log")))
            )
            let contained_dir_install = (^$bash -lc $"($contained_dir_environment) /bin/bash (quote-for-bash $installer)" | complete)
            assert ($contained_dir_install.exit_code != 0) "installer accepted config directory symlink into Nurl"
            assert equal (open ($contained_dir_nurl | path join "config.nu") --raw) "managed config bytes" "installer config directory symlink corrupted Nurl"
        } else if $require_posix {
            error make {msg: "required Ubuntu contained config-directory symlink capability is unavailable"}
        }

        let dot_home = ($fixture | path join "dot-home")
        let dot_nurl = ($dot_home | path join ".nurl")
        mkdir $dot_nurl
        "dot-path managed bytes" | save -f ($dot_nurl | path join "config.nu")
        let dot_environment = (
            "HOME=" + (quote-for-bash (path-for-bash $bash $dot_home))
            + " PATH=" + (quote-for-bash $"($bash_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash ((path-for-bash $bash $dot_home) + "/missing/../.nurl"))
            + " NURL_INSTALLER_NU_VERSION=0.113.1"
            + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
            + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "dot-curl.log")))
            + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "dot-downloads.log")))
        )
        let dot_install = (^$bash -lc $"($dot_environment) /bin/bash (quote-for-bash $installer)" | complete)
        assert ($dot_install.exit_code != 0) "installer accepted unresolved dot components in config path"
        assert equal (open ($dot_nurl | path join "config.nu") --raw) "dot-path managed bytes" "dot-component config path corrupted Nurl"
        assert (not (($fixture | path join "dot-downloads.log") | path exists)) "dot-component config rejection happened after downloads"

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

        let mixed_home = ($fixture | path join "mixed-home")
        let mixed_target = ($fixture | path join "mixed-target")
        let mixed_link = ($fixture | path join "mixed-link")
        let mixed_config_dir = ($mixed_target | path join "nushell")
        mkdir $mixed_home
        mkdir $mixed_config_dir
        let mixed_original = "# alpha\r\n\r# beta\n# gamma\r"
        $mixed_original | save -f ($mixed_config_dir | path join "config.nu")
        let mixed_link_result = (^$bash -lc $"ln -s (quote-for-bash (path-for-bash $bash $mixed_target)) (quote-for-bash (path-for-bash $bash $mixed_link))" | complete)
        let actual_mixed_link = if $mixed_link_result.exit_code == 0 {
            ^$bash -lc $"test -L (quote-for-bash (path-for-bash $bash $mixed_link))" | complete
        } else {
            {exit_code: 1}
        }
        let mixed_resolved = if $actual_mixed_link.exit_code == 0 {
            $mixed_link | path join "nushell"
        } else {
            $mixed_config_dir
        }
        let mixed_environment = (
            "HOME=" + (quote-for-bash (path-for-bash $bash $mixed_home))
            + " PATH=" + (quote-for-bash $"($bash_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $mixed_resolved))
            + " NURL_INSTALLER_NU_VERSION=0.113.1"
            + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
            + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "mixed-curl.log")))
            + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash ($fixture | path join "mixed-downloads.log")))
        )
        let mixed_install = (^$bash -lc $"($mixed_environment) /bin/bash (quote-for-bash $installer)" | complete)
        assert equal $mixed_install.exit_code 0 $"mixed-EOL shell install failed: ($mixed_install.stderr)"
        let mixed_remove = (^$bash -lc $"($mixed_environment) /bin/bash (quote-for-bash $uninstaller) --yes" | complete)
        assert equal $mixed_remove.exit_code 0 $"mixed-EOL shell uninstall failed: ($mixed_remove.stderr)"
        assert equal (open ($mixed_config_dir | path join "config.nu") --raw) $mixed_original "mixed/CR-only config bytes did not round-trip"
        if $actual_mixed_link.exit_code == 0 {
            let parent_link_after = (^$bash -lc $"test -L (quote-for-bash (path-for-bash $bash $mixed_link))" | complete)
            assert equal $parent_link_after.exit_code 0 "packaging replaced the symlinked config parent"
        } else if $require_posix {
            error make {msg: "required Ubuntu config-parent symlink capability is unavailable"}
        }
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
        let original_text = "# comment source ~/.nurl/api.nu\r\n\r\nlet normal = true\r\nalias nurl-note = echo ~/.nurl/api.nu\r\n# tail"
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

        let uninstall_temp_home = ($fixture | path join "uninstall-temp-home")
        let uninstall_temp_appdata = ($fixture | path join "uninstall-temp-appdata")
        let uninstall_temp_resolved = ($uninstall_temp_appdata | path join "nushell")
        mkdir ($uninstall_temp_home | path join ".nurl")
        mkdir $uninstall_temp_appdata
        mkdir $uninstall_temp_resolved
        "uninstall temp data" | save -f ($uninstall_temp_home | path join ".nurl" "data.nuon")
        let uninstall_temp_config = ($uninstall_temp_resolved | path join "config.nu")
        let write_uninstall_temp_config = '[System.IO.File]::WriteAllText($env:NURL_TEST_CONFIG_PATH, "# >>> nurl >>>`r`nsource ~/.nurl/api.nu`r`n# <<< nurl <<<`r`nkeep`r`n", [System.Text.UTF8Encoding]::new($false))'
        let uninstall_temp_written = (with-env {NURL_TEST_CONFIG_PATH: $uninstall_temp_config} {
            ^powershell.exe -NoProfile -NonInteractive -Command $write_uninstall_temp_config | complete
        })
        assert equal $uninstall_temp_written.exit_code 0
        let uninstall_conflict_harness = ($fixture | path join "run-uninstaller-conflict.ps1")
        'param($Uninstaller, $HomePath, $AppDataPath, $ToolsPath, $ConfigPath)
$env:USERPROFILE = $HomePath
$env:HOME = $HomePath
$env:APPDATA = $AppDataPath
$env:Path = $ToolsPath
function Move-Item {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$LiteralPath, [Parameter(Mandatory)]$Destination, [switch]$Force)
    if ([string]$LiteralPath -eq [System.IO.Path]::Combine($HomePath, ".nurl")) {
        [System.IO.File]::WriteAllText($ConfigPath, "concurrent uninstall config")
    }
    Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
}
& $Uninstaller -Yes
' | save -f $uninstall_conflict_harness
        let uninstall_temp_result = (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $uninstall_conflict_harness ($env.NURL_REPO_ROOT | path join "uninstall.ps1") $uninstall_temp_home $uninstall_temp_appdata $tools $uninstall_temp_config | complete)
        assert ($uninstall_temp_result.exit_code != 0) $"PowerShell uninstall config promotion failure unexpectedly succeeded: output=(($uninstall_temp_result.stdout + $uninstall_temp_result.stderr) | to nuon) config=(open $uninstall_temp_config --raw | to nuon)"
        assert (($uninstall_temp_result.stdout + $uninstall_temp_result.stderr) | str contains "config changed during uninstall") "PowerShell uninstall config conflict was not actionable"
        assert equal (open $uninstall_temp_config --raw) "concurrent uninstall config" "PowerShell uninstall conflict overwrote the concurrent edit"
        assert ((child-paths-starting $uninstall_temp_resolved ".config.nu.nurl.") | is-empty) "PowerShell uninstall config promotion failure leaked a temp"
        assert equal ((child-paths-starting $uninstall_temp_home ".nurl-backup-") | length) 1 "PowerShell uninstall config promotion failure lost its verified backup"

        let readonly_ps_home = ($fixture | path join "readonly-ps-home")
        let readonly_ps_appdata = ($fixture | path join "readonly-ps-appdata")
        let readonly_ps_config_dir = ($readonly_ps_appdata | path join "nushell")
        let readonly_ps_config = ($readonly_ps_config_dir | path join "config.nu")
        mkdir ($readonly_ps_home | path join ".nurl")
        mkdir $readonly_ps_config_dir
        "read-only PS data" | save -f ($readonly_ps_home | path join ".nurl" "data.nuon")
        let write_readonly_ps = '[System.IO.File]::WriteAllText($env:NURL_TEST_CONFIG_PATH, "# >>> nurl >>>`r`nsource ~/.nurl/api.nu`r`n# <<< nurl <<<`r`n", [System.Text.UTF8Encoding]::new($false))'
        let readonly_ps_written = (with-env {NURL_TEST_CONFIG_PATH: $readonly_ps_config} {
            ^powershell.exe -NoProfile -NonInteractive -Command $write_readonly_ps | complete
        })
        assert equal $readonly_ps_written.exit_code 0
        let readonly_ps_set = (with-env {NURL_TEST_CONFIG_PATH: $readonly_ps_config} {
            ^powershell.exe -NoProfile -NonInteractive -Command '(Get-Item -LiteralPath $env:NURL_TEST_CONFIG_PATH).IsReadOnly = $true' | complete
        })
        assert equal $readonly_ps_set.exit_code 0
        let readonly_ps_result = (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $uninstall_harness ($env.NURL_REPO_ROOT | path join "uninstall.ps1") $readonly_ps_home $readonly_ps_appdata $tools | complete)
        assert ($readonly_ps_result.exit_code != 0) "PowerShell uninstall accepted read-only owned config"
        assert (($readonly_ps_result.stdout + $readonly_ps_result.stderr) | str contains "read-only; Nurl was not moved") "PowerShell read-only config error lacked actionable state"
        assert (($readonly_ps_home | path join ".nurl") | path exists) "PowerShell read-only config failure detached Nurl"
        assert ((child-paths-starting $readonly_ps_home ".nurl-backup-") | is-empty) "PowerShell read-only config failure created a backup"
        with-env {NURL_TEST_CONFIG_PATH: $readonly_ps_config} {
            ^powershell.exe -NoProfile -NonInteractive -Command '(Get-Item -LiteralPath $env:NURL_TEST_CONFIG_PATH).IsReadOnly = $false' | complete | ignore
        }

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

        let invalid_home = ($fixture | path join "invalid-home")
        let invalid_appdata = ($fixture | path join "invalid-appdata")
        let invalid_resolved = ($fixture | path join "invalid-resolved")
        mkdir $invalid_home
        mkdir $invalid_appdata
        mkdir $invalid_resolved
        let invalid_config = ($invalid_resolved | path join "config.nu")
        let write_invalid = '[System.IO.File]::WriteAllBytes($env:NURL_TEST_CONFIG_PATH, [byte[]](0xC3, 0x28, 0xFF))'
        let invalid_written = (with-env {NURL_TEST_CONFIG_PATH: $invalid_config} {
            ^powershell.exe -NoProfile -NonInteractive -Command $write_invalid | complete
        })
        assert equal $invalid_written.exit_code 0
        let invalid_bytes = (open $invalid_config --raw)
        let invalid_install = (with-env {
            NURL_INSTALLER_NU_VERSION: "0.113.1"
            NURL_INSTALLER_CONFIG_DIR: $invalid_resolved
            NURL_INSTALLER_CURL_VERSION_LINE: "curl 8.13.0 libcurl/8.13.0"
            NURL_INSTALLER_CURL_EXIT: "0"
            NURL_INSTALLER_CURL_STDERR: ""
            NURL_INSTALLER_CURL_LOG: ($fixture | path join "invalid-curl.log")
            NURL_INSTALLER_DOWNLOAD_LOG: ($fixture | path join "invalid-downloads.log")
            NURL_INSTALLER_DOWNLOAD_COUNT: ($fixture | path join "invalid-download-count")
        } {
            ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer_harness ($env.NURL_REPO_ROOT | path join "install.ps1") $invalid_home $invalid_appdata $tools | complete
        })
        assert ($invalid_install.exit_code != 0) "PowerShell installer accepted invalid config encoding"
        assert (($invalid_install.stdout + $invalid_install.stderr) | str contains "invalid or unsupported text encoding") "PowerShell invalid-encoding install error was not actionable"
        assert equal (open $invalid_config --raw) $invalid_bytes "PowerShell invalid-encoding install changed config bytes"
        assert (not (($invalid_home | path join ".nurl") | path exists)) "PowerShell invalid-encoding install mutated Nurl"
        assert ((child-paths-starting $invalid_home ".nurl-stage-") | is-empty) "PowerShell invalid-encoding install leaked staging"

        mkdir ($invalid_home | path join ".nurl")
        "must remain" | save -f ($invalid_home | path join ".nurl" "data.nuon")
        let invalid_uninstall = (with-env {NURL_INSTALLER_CONFIG_DIR: $invalid_resolved} {
            ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $uninstall_harness ($env.NURL_REPO_ROOT | path join "uninstall.ps1") $invalid_home $invalid_appdata $tools | complete
        })
        assert ($invalid_uninstall.exit_code != 0) "PowerShell uninstaller accepted invalid config encoding"
        assert (($invalid_uninstall.stdout + $invalid_uninstall.stderr) | str contains "invalid or unsupported text encoding") "PowerShell invalid-encoding uninstall error was not actionable"
        assert (($invalid_home | path join ".nurl") | path exists) "PowerShell invalid-encoding uninstall removed Nurl"
        assert equal (open $invalid_config --raw) $invalid_bytes "PowerShell invalid-encoding uninstall changed config bytes"
        assert ((child-paths-starting $invalid_home ".nurl-backup-") | is-empty) "PowerShell invalid-encoding uninstall created a backup"

        let contained_ps_home = ($fixture | path join "contained-ps-home")
        let contained_ps_appdata = ($fixture | path join "contained-ps-appdata")
        let contained_ps_nurl = ($contained_ps_home | path join ".nurl")
        mkdir $contained_ps_nurl
        mkdir $contained_ps_appdata
        "PowerShell managed config bytes" | save -f ($contained_ps_nurl | path join "config.nu")
        let contained_ps_install = (with-env {
            NURL_INSTALLER_NU_VERSION: "0.113.1"
            NURL_INSTALLER_CONFIG_DIR: $contained_ps_nurl
            NURL_INSTALLER_CURL_VERSION_LINE: "curl 8.13.0 libcurl/8.13.0"
            NURL_INSTALLER_CURL_EXIT: "0"
            NURL_INSTALLER_CURL_STDERR: ""
            NURL_INSTALLER_CURL_LOG: ($fixture | path join "contained-ps-curl.log")
            NURL_INSTALLER_DOWNLOAD_LOG: ($fixture | path join "contained-ps-downloads.log")
        } {
            ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer_harness ($env.NURL_REPO_ROOT | path join "install.ps1") $contained_ps_home $contained_ps_appdata $tools | complete
        })
        assert ($contained_ps_install.exit_code != 0) "PowerShell installer accepted config inside Nurl"
        assert (($contained_ps_install.stdout + $contained_ps_install.stderr) | str contains "must not resolve inside") "PowerShell installer containment error was not actionable"
        assert equal (open ($contained_ps_nurl | path join "config.nu") --raw) "PowerShell managed config bytes" "PowerShell installer containment changed Nurl bytes"
        let contained_ps_remove = (with-env {NURL_INSTALLER_CONFIG_DIR: $contained_ps_nurl} {
            ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $uninstall_harness ($env.NURL_REPO_ROOT | path join "uninstall.ps1") $contained_ps_home $contained_ps_appdata $tools | complete
        })
        assert ($contained_ps_remove.exit_code != 0) "PowerShell uninstaller accepted config inside Nurl"
        assert (($contained_ps_remove.stdout + $contained_ps_remove.stderr) | str contains "must not resolve inside") "PowerShell uninstaller containment error was not actionable"
        assert ($contained_ps_nurl | path exists) "PowerShell uninstaller containment removed Nurl"

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
function Move-Item { throw "forced backup detach failure" }
$script = [System.IO.File]::ReadAllText($Uninstaller)
try { Invoke-Expression $script } catch { Write-Output "CAUGHT-UNINSTALL" }
Write-Output "HOST-ALIVE-UNINSTALL"
' | save -f $failure_harness
        let host_failure = (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $failure_harness ($env.NURL_REPO_ROOT | path join "uninstall.ps1") $host_home $host_appdata $tools | complete)
        assert equal $host_failure.exit_code 0 $"PowerShell uninstall failure terminated the host: ($host_failure.stderr)"
        assert ($host_failure.stdout | str contains "CAUGHT-UNINSTALL") "PowerShell uninstall failure was not catchable"
        assert ($host_failure.stdout | str contains "HOST-ALIVE-UNINSTALL") "PowerShell uninstall failure killed its host"
        assert (($host_home | path join ".nurl") | path exists) "PowerShell uninstall failure removed Nurl"

        if (which pwsh | is-not-empty) {
            let style_home = ($fixture | path join "style-home")
            let style_appdata = ($fixture | path join "style-appdata")
            mkdir ($style_home | path join ".nurl")
            mkdir $style_appdata
            let style_harness = ($fixture | path join "style-host.ps1")
            'param($Installer, $Uninstaller, $HomePath, $AppDataPath, $ToolsPath)
$env:USERPROFILE = $HomePath
$env:HOME = $HomePath
$env:APPDATA = $AppDataPath
$env:Path = $ToolsPath
$env:NURL_INSTALLER_NU_VERSION = "0.88.0"
$PSStyle.OutputRendering = "Ansi"
$beforeInstall = $PSStyle.OutputRendering
try { Invoke-Expression ([System.IO.File]::ReadAllText($Installer)) } catch {}
if ($PSStyle.OutputRendering -ne $beforeInstall) { throw "installer changed PSStyle.OutputRendering" }
function Read-Host { return "n" }
$beforeUninstall = $PSStyle.OutputRendering
Invoke-Expression ([System.IO.File]::ReadAllText($Uninstaller))
if ($PSStyle.OutputRendering -ne $beforeUninstall) { throw "uninstaller changed PSStyle.OutputRendering" }
Write-Output "PSSTYLE-PRESERVED"
' | save -f $style_harness
            let style_result = (^pwsh -NoProfile -NonInteractive -File $style_harness ($env.NURL_REPO_ROOT | path join "install.ps1") ($env.NURL_REPO_ROOT | path join "uninstall.ps1") $style_home $style_appdata $tools | complete)
            assert equal $style_result.exit_code 0 $"PowerShell scripts changed host PSStyle: ($style_result.stderr)"
            assert ($style_result.stdout | str contains "PSSTYLE-PRESERVED") "PowerShell host style preservation fixture did not finish"
        }
        null
    } catch {|error| $error }
    cleanup $fixture
    if $failure != null {
        error make {msg: $failure.msg}
    }
}

def test-shell-config-byte-reader-and-performance [--performance-only, --huge-only, --uninstall-only] {
    let bash_candidates = (which bash | where type == "external" | get path? | default [])
    if ($bash_candidates | is-empty) {
        error make {msg: "SKIP: Bash is unavailable for config byte-reader fixtures"}
    }
    let bash = ($bash_candidates | first)
    let fixture = (make-temp-dir "shell-byte-reader")
    let failure = try {
        let base_tools = ($fixture | path join "base-tools")
        mkdir $base_tools
        shell-installer-tools $base_tools $bash
        let installer = (path-for-bash $bash ($env.NURL_REPO_ROOT | path join "install.sh"))
        let uninstaller = (path-for-bash $bash ($env.NURL_REPO_ROOT | path join "uninstall.sh"))

        if not $performance_only {
        for case in [
            {name: "missing", exit_code: 127, diagnostic: "od: command not found"}
            {name: "nonzero", exit_code: 42, diagnostic: "forced od failure"}
        ] {
            let root = ($fixture | path join $case.name)
            let home = ($root | path join "home")
            let nurl = ($home | path join ".nurl")
            let config_dir = ($root | path join "config")
            let tools = ($root | path join "tools")
            mkdir ($nurl | path join "collections")
            mkdir $config_dir
            mkdir $tools
            cp ($base_tools | path join "nu") ($tools | path join "nu")
            cp ($base_tools | path join "curl") ($tools | path join "curl")
            $"#!/bin/bash\nprintf '%s\\n' (quote-for-bash $case.diagnostic) >&2\nexit ($case.exit_code)\n"
            | str replace --all "\r" ""
            | save -f ($tools | path join "od")
            let chmod_result = (^$bash -lc $"chmod 700 (quote-for-bash (path-for-bash $bash ($tools | path join 'nu'))) (quote-for-bash (path-for-bash $bash ($tools | path join 'curl'))) (quote-for-bash (path-for-bash $bash ($tools | path join 'od')))" | complete)
            assert equal $chmod_result.exit_code 0
            "existing api bytes" | save -f ($nurl | path join "api.nu")
            "existing user data" | save -f ($nurl | path join "collections" "user.nuon")
            "existing config data" | save -f ($nurl | path join "config.nuon")
            let config = ($config_dir | path join "config.nu")
            let config_bytes = "# normal config\r\nlet keep = true\r\n"
            $config_bytes | save -f $config
            let environment = (
                "HOME=" + (quote-for-bash (path-for-bash $bash $home))
                + " PATH=" + (quote-for-bash $"(path-for-bash $bash $tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
                + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $config_dir))
                + " NURL_INSTALLER_NU_VERSION=0.113.1"
                + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
                + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($root | path join "curl.log")))
                + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash ($root | path join "downloads.log")))
            )
            let install_result = (^$bash -lc $"($environment) /bin/bash (quote-for-bash $installer)" | complete)
            assert ($install_result.exit_code != 0) $"shell install accepted ($case.name) od failure"
            let install_output = $install_result.stdout + $install_result.stderr
            assert ($install_output | str contains "Could not read Nushell config bytes with od") $"shell install ($case.name) od failure was not actionable"
            assert (not ($install_output | str contains "successfully")) $"shell install ($case.name) od failure printed success"
            assert equal (open $config --raw) $config_bytes $"shell install ($case.name) od failure changed config"
            assert equal (open ($nurl | path join "api.nu") --raw) "existing api bytes" $"shell install ($case.name) od failure changed api.nu"
            assert equal (open ($nurl | path join "collections" "user.nuon") --raw) "existing user data" $"shell install ($case.name) od failure changed user data"
            assert equal (open ($nurl | path join "config.nuon") --raw) "existing config data" $"shell install ($case.name) od failure changed config.nuon"
            assert ((child-paths-starting $home ".nurl-stage.") | is-empty) $"shell install ($case.name) od failure leaked staging"

            let uninstall_result = (^$bash -lc $"($environment) /bin/bash (quote-for-bash $uninstaller) --yes" | complete)
            assert ($uninstall_result.exit_code != 0) $"shell uninstall accepted ($case.name) od failure"
            let uninstall_output = $uninstall_result.stdout + $uninstall_result.stderr
            assert ($uninstall_output | str contains "Could not read Nushell config bytes with od") $"shell uninstall ($case.name) od failure was not actionable"
            assert ($nurl | path exists) $"shell uninstall ($case.name) od failure removed Nurl"
            assert equal (open $config --raw) $config_bytes $"shell uninstall ($case.name) od failure changed config"
            assert ((child-paths-starting $home ".nurl-backup-") | is-empty) $"shell uninstall ($case.name) od failure created a backup"
        }

        let nul_root = ($fixture | path join "nul-byte")
        let nul_home = ($nul_root | path join "home")
        let nul_nurl = ($nul_home | path join ".nurl")
        let nul_config_dir = ($nul_root | path join "config")
        mkdir $nul_nurl
        mkdir $nul_config_dir
        "nul user data" | save -f ($nul_nurl | path join "data.nuon")
        let nul_config = ($nul_config_dir | path join "config.nu")
        0x[6c 65 74 20 78 20 3d 20 31 00 0a] | save -f $nul_config
        let nul_environment = (
            "HOME=" + (quote-for-bash (path-for-bash $bash $nul_home))
            + " PATH=" + (quote-for-bash $"(path-for-bash $bash $base_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $nul_config_dir))
            + " NURL_INSTALLER_NU_VERSION=0.113.1"
            + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
            + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($nul_root | path join "curl.log")))
            + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash ($nul_root | path join "downloads.log")))
        )
        let nul_install = (^$bash -lc $"($nul_environment) /bin/bash (quote-for-bash $installer)" | complete)
        assert ($nul_install.exit_code != 0) "shell installer accepted a NUL config byte"
        let nul_install_output = $nul_install.stdout + $nul_install.stderr
        assert ($nul_install_output | str contains (path-for-bash $bash $nul_config)) "shell installer NUL diagnostic did not name the user config"
        assert (not ($nul_install_output | str contains "config.original")) "shell installer NUL diagnostic named the staging copy"
        assert ($nul_nurl | path exists) "shell installer NUL failure removed Nurl"
        let nul_uninstall = (^$bash -lc $"($nul_environment) /bin/bash (quote-for-bash $uninstaller) --yes" | complete)
        assert ($nul_uninstall.exit_code != 0) "shell uninstaller accepted a NUL config byte"
        let nul_uninstall_output = $nul_uninstall.stdout + $nul_uninstall.stderr
        assert ($nul_uninstall_output | str contains (path-for-bash $bash $nul_config)) "shell uninstaller NUL diagnostic did not name the user config"
        assert (not ($nul_uninstall_output | str contains "config-original")) "shell uninstaller NUL diagnostic named the staging copy"
        assert ($nul_nurl | path exists) "shell uninstaller NUL failure removed Nurl"

        let corrupt_root = ($fixture | path join "corrupt-sentinel")
        let corrupt_home = ($corrupt_root | path join "home")
        let corrupt_nurl = ($corrupt_home | path join ".nurl")
        let corrupt_config_dir = ($corrupt_root | path join "config")
        let corrupt_config = ($corrupt_config_dir | path join "config.nu")
        mkdir $corrupt_nurl
        mkdir $corrupt_config_dir
        "corrupt sentinel user data" | save -f ($corrupt_nurl | path join "data.nuon")
        let corrupt_bytes = "# <<< nurl <<<\nlet keep = true\n"
        $corrupt_bytes | save -f $corrupt_config
        let corrupt_environment = (
            "HOME=" + (quote-for-bash (path-for-bash $bash $corrupt_home))
            + " PATH=" + (quote-for-bash $"(path-for-bash $bash $base_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $corrupt_config_dir))
            + " NURL_INSTALLER_NU_VERSION=0.113.1"
            + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
            + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($corrupt_root | path join "curl.log")))
            + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash ($corrupt_root | path join "downloads.log")))
        )
        let corrupt_install = (^$bash -lc $"($corrupt_environment) /bin/bash (quote-for-bash $installer)" | complete)
        assert ($corrupt_install.exit_code != 0) "installer accepted corrupt sentinel"
        let corrupt_install_output = $corrupt_install.stdout + $corrupt_install.stderr
        assert ($corrupt_install_output | str contains (path-for-bash $bash $corrupt_config)) "installer sentinel diagnostic did not name live config"
        assert (not ($corrupt_install_output | str contains "config.original")) "installer sentinel diagnostic named staging config"
        assert equal (open $corrupt_config --raw) $corrupt_bytes "installer corrupt-sentinel failure changed config"
        let corrupt_uninstall = (^$bash -lc $"($corrupt_environment) /bin/bash (quote-for-bash $uninstaller) --yes" | complete)
        assert ($corrupt_uninstall.exit_code != 0) "uninstaller accepted corrupt sentinel"
        let corrupt_uninstall_output = $corrupt_uninstall.stdout + $corrupt_uninstall.stderr
        assert ($corrupt_uninstall_output | str contains (path-for-bash $bash $corrupt_config)) "uninstaller sentinel diagnostic did not name live config"
        assert (not ($corrupt_uninstall_output | str contains "config-original")) "uninstaller sentinel diagnostic named staging config"
        assert ($corrupt_nurl | path exists) "uninstaller corrupt-sentinel failure detached Nurl"
        }

        if not $huge_only {
        let perf_root = ($fixture | path join "performance")
        let perf_home = ($perf_root | path join "home")
        let perf_config_dir = ($perf_root | path join "config")
        mkdir $perf_home
        mkdir $perf_config_dir
        let perf_config = ($perf_config_dir | path join "config.nu")
        let large_config = (
            0..399
            | each {|index| $"let realistic_setting_($index) = 'value-($index)-abcdefghijklmnopqrstuvwxyz'" }
            | str join "\r\n"
        )
        assert (($large_config | str length) >= 20_000) "performance config is smaller than 20KB"
        $large_config | save -f $perf_config
        let perf_environment = (
            "HOME=" + (quote-for-bash (path-for-bash $bash $perf_home))
            + " PATH=" + (quote-for-bash $"(path-for-bash $bash $base_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $perf_config_dir))
            + " NURL_INSTALLER_NU_VERSION=0.113.1"
            + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
            + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($perf_root | path join "curl.log")))
            + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash ($perf_root | path join "downloads.log")))
        )
        let install_started = (date now)
        let perf_install = (^$bash -lc $"($perf_environment) /bin/bash (quote-for-bash $installer)" | complete)
        let install_seconds = (((date now) - $install_started) / 1sec)
        assert equal $perf_install.exit_code 0 $"large-config shell install failed: ($perf_install.stderr)"
        let uninstall_started = (date now)
        let perf_uninstall = (^$bash -lc $"($perf_environment) /bin/bash (quote-for-bash $uninstaller) --yes" | complete)
        let uninstall_seconds = (((date now) - $uninstall_started) / 1sec)
        assert equal $perf_uninstall.exit_code 0 $"large-config shell uninstall failed: ($perf_uninstall.stderr)"
        print $"  [large config timing] install=($install_seconds)s uninstall=($uninstall_seconds)s bytes=($large_config | str length)"
        assert ($install_seconds < 120) $"large-config shell install exceeded the 120s hang guard: ($install_seconds)s"
        assert ($uninstall_seconds < 120) $"large-config shell uninstall exceeded the 120s hang guard: ($uninstall_seconds)s"
        null
        }

        let huge_root = ($fixture | path join "performance-200k")
        let huge_home = ($huge_root | path join "home")
        let huge_config_dir = ($huge_root | path join "config")
        mkdir $huge_home
        mkdir $huge_config_dir
        let huge_config = ($huge_config_dir | path join "config.nu")
        let huge_content = (
            0..3299
            | each {|index| $"let realistic_setting_($index) = 'value-($index)-abcdefghijklmnopqrstuvwxyz'" }
            | str join "\r\n"
        )
        assert (($huge_content | str length) >= 200_000) "huge performance config is smaller than 200KB"
        let huge_saved_content = if $uninstall_only {
            mkdir ($huge_home | path join ".nurl")
            $huge_content + "\r\n# >>> nurl >>>\r\nsource ~/.nurl/api.nu\r\n# <<< nurl <<<"
        } else {
            $huge_content
        }
        $huge_saved_content | save -f $huge_config
        let huge_environment = (
            "HOME=" + (quote-for-bash (path-for-bash $bash $huge_home))
            + " PATH=" + (quote-for-bash $"(path-for-bash $bash $base_tools):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            + " NURL_INSTALLER_CONFIG_DIR=" + (quote-for-bash (path-for-bash $bash $huge_config_dir))
            + " NURL_INSTALLER_NU_VERSION=0.113.1"
            + " NURL_INSTALLER_CURL_VERSION_LINE=" + (quote-for-bash "curl 8.13.0 libcurl/8.13.0")
            + " NURL_INSTALLER_CURL_LOG=" + (quote-for-bash (path-for-bash $bash ($huge_root | path join "curl.log")))
            + " NURL_INSTALLER_DOWNLOAD_LOG=" + (quote-for-bash (path-for-bash $bash ($huge_root | path join "downloads.log")))
        )
        let huge_install_seconds = if $uninstall_only {
            0
        } else {
            let huge_install_started = (date now)
            let huge_install = (^$bash -lc $"($huge_environment) /bin/bash (quote-for-bash $installer)" | complete)
            let elapsed = (((date now) - $huge_install_started) / 1sec)
            assert equal $huge_install.exit_code 0 $"200KB shell install failed: ($huge_install.stderr)"
            $elapsed
        }
        let huge_uninstall_started = (date now)
        let huge_uninstall = (^$bash -lc $"($huge_environment) /bin/bash (quote-for-bash $uninstaller) --yes" | complete)
        let huge_uninstall_seconds = (((date now) - $huge_uninstall_started) / 1sec)
        assert equal $huge_uninstall.exit_code 0 $"200KB shell uninstall failed: ($huge_uninstall.stderr)"
        print $"  [200KB config timing] install=($huge_install_seconds)s uninstall=($huge_uninstall_seconds)s bytes=($huge_content | str length)"
        if not $uninstall_only {
            assert ($huge_install_seconds < 120) $"200KB shell install exceeded the 120s hang guard: ($huge_install_seconds)s"
        }
        assert ($huge_uninstall_seconds < 120) $"200KB shell uninstall exceeded the 120s hang guard: ($huge_uninstall_seconds)s"
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
    for installer in ["install.sh" "install.ps1"] {
        assert (not ((open ($repo | path join $installer) --raw) | str contains "NURL_REPO_URL")) $"($installer) exposes an undocumented repository override"
    }
    for shell_script in ["install.sh" "uninstall.sh"] {
        let shell_source = (open ($repo | path join $shell_script) --raw)
        assert ($shell_source | str contains "Library/Application Support/nushell") $"($shell_script) is missing the macOS config fallback"
        assert (not ($shell_source | str contains "set -euo pipefail")) $"($shell_script) uses nounset, which breaks empty arrays on macOS Bash 3.2"
    }
    let uninstall_source = (open ($repo | path join "uninstall.sh") --raw)
    assert ($uninstall_source | str contains "elif { exec 3<>/dev/tty; } 2>/dev/null; then") "shell /dev/tty probe permanently redirects stderr"
    assert ($uninstall_source | str contains "! -type d ! -type f") "shell uninstall does not reject special backup entries"
}

def test-reviewed-packaging-safety-contracts [] {
    let repo = $env.NURL_REPO_ROOT
    let install_sh = (open ($repo | path join "install.sh") --raw)
    let uninstall_sh = (open ($repo | path join "uninstall.sh") --raw)
    let install_ps = (open ($repo | path join "install.ps1") --raw)
    let uninstall_ps = (open ($repo | path join "uninstall.ps1") --raw)

    assert ($uninstall_sh | str contains "elif { exec 3<>/dev/tty; } 2>/dev/null; then") "shell TTY probe no longer scopes stderr suppression"
    assert (not ($uninstall_sh | str contains "elif exec 3<>/dev/tty 2>/dev/null; then")) "unsafe shell TTY exec redirection returned"
    for shell_source in [$install_sh $uninstall_sh] {
        assert ($shell_source | str contains "canonicalize_directory_path") "shell config containment is not canonical"
        assert ($shell_source | str contains "resolve_config_path") "shell config symlink support is missing"
        assert ($shell_source | str contains "get_file_mode") "shell config mode preservation is missing"
        assert ($shell_source | str contains "must not resolve inside") "shell config containment guard is missing"
        assert ($shell_source | str contains "probe_mv_no_clobber") "shell config replacement does not probe mv -n capability"
        assert (not ($shell_source | str contains "done < <(od")) "shell config reader does not check od process-substitution failure"
        assert (not ($shell_source | str contains "$(printf '%03o'")) "shell config reader forks once per byte"
        assert ($shell_source | str contains '"$decoded_count" != "$source_size"') "shell config reader does not validate decoded byte count"
        assert ($shell_source | str contains "perl -") "shell config transformation is not single-pass"
    }
    assert ($uninstall_sh | str contains "Could not create an atomic temp beside Nushell config") "uninstall does not preflight adjacent config temp creation"
    assert ($install_sh | str contains "required_tool in od awk perl wc sed tr uname dirname basename mktemp cp mv rm chmod cmp") "shell installer does not preflight cmp and required tools"
    assert ($uninstall_sh | str contains "required_tool in od awk perl wc sed tr uname find dirname basename mktemp cp mv rm chmod cmp") "shell uninstaller does not preflight cmp and required tools"
    assert (not ($uninstall_sh | str contains "restore_displaced_config \"$displaced\" \"$destination\" || true")) "shell uninstall swallows config restoration failures"
    assert equal (($install_sh | parse --regex 'ROLLBACK_FAILED=false') | length) 1 "shell installer resets an earlier rollback failure"
    assert (not ($install_sh | str contains "FRESH_SIGNATURE")) "shell installer retains dead fresh-signature state"
    for ps_source in [$install_ps $uninstall_ps] {
        assert ($ps_source | str contains "[AllowEmptyString()][string]$Line") "PowerShell legacy-source check rejects blank config lines"
        assert ($ps_source | str contains '$PSStyle.OutputRendering = $previousOutputRendering') "PowerShell host rendering state is not restored"
        assert ($ps_source | str contains "invalid or unsupported text encoding") "PowerShell encoding failure is not actionable"
    }
    assert ($install_ps | str contains "config temporary directory remains") "PowerShell install temp cleanup diagnostic is missing"
    assert (not ($install_ps | str contains "Get-NurlTreeManifest")) "PowerShell installer retains dead fresh-manifest state"
    assert ($uninstall_ps | str contains '$configTemps') "PowerShell uninstall does not track config temps"
    assert ($uninstall_ps | str contains "read-only; Nurl was not moved") "PowerShell read-only config failure is not preflighted"
    assert ($install_ps | str contains "preserved the visible fresh installation") "PowerShell fresh rollback does not preserve concurrent data"
    assert ($install_ps | str contains "[System.IO.File]::Replace") "PowerShell installer config replacement is not atomic"
    assert ($uninstall_ps | str contains "[System.IO.File]::Replace") "PowerShell uninstaller config replacement is not atomic"
    for ps_source in [$install_ps $uninstall_ps] {
        assert ($ps_source | str contains "Test-NurlPathContained") "PowerShell config containment guard is missing"
        assert ($ps_source | str contains "must not resolve inside") "PowerShell config containment diagnostic is missing"
    }
    let ps_track_index = ($uninstall_ps | str index-of '$configTemps.Add($temp)')
    let ps_write_index = ($uninstall_ps | str index-of '[System.IO.File]::WriteAllBytes($temp')
    assert ($ps_track_index >= 0 and $ps_track_index < $ps_write_index) "PowerShell uninstall tracks config temp after writing it"
    let shell_track_index = ($uninstall_sh | str index-of 'CONFIG_TEMPS+=("$config_temp")')
    let shell_copy_index = ($uninstall_sh | str index-of 'cp "$candidate" "$config_temp"')
    assert ($shell_track_index >= 0 and $shell_track_index < $shell_copy_index) "shell uninstall tracks config temp after populating it"
    assert equal (($install_sh | parse --regex 'CREATED_PATHS\+=') | length) (($install_sh | parse --regex 'CREATED_CANDIDATES\+=') | length) "shell rollback created-path arrays are desynchronized"
    assert ($install_sh | str contains "finish() {\n    local status=$?\n    set +e") "shell EXIT cleanup can abort before completing recovery"
}

def test-ubuntu-packaging-workflow-contract [] {
    let repo = $env.NURL_REPO_ROOT
    let workflow = (open ($repo | path join ".github" "workflows" "security-compatibility.yml") --raw)
    let runner = (open ($repo | path join "tests" "run-packaging.nu") --raw)
    assert ($workflow | str contains "packaging-ubuntu:") "Ubuntu behavioral packaging job is missing"
    assert ($workflow | str contains "Packaging behavior / ubuntu-latest / Nushell 0.114.1") "Ubuntu packaging job is not visibly named"
    assert ($workflow | str contains 'NURL_REQUIRE_POSIX_PACKAGING: "1"') "Ubuntu packaging job does not require PTY/symlink capabilities"
    assert ($workflow | str contains "tests/run-packaging.nu") "Ubuntu packaging job does not run the focused packaging runner"
    assert ($runner | str contains "run-suite-packaging") "focused packaging runner does not execute the packaging suite"
    assert ($runner | str contains 'where status == "fail"') "focused packaging runner does not fail on test failures"
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
        (run-test "shell config byte reader fails closed and remains single-pass on large files" { test-shell-config-byte-reader-and-performance })
        (run-test "reviewed packaging safety contracts remain explicit" { test-reviewed-packaging-safety-contracts })
        (run-test "Ubuntu workflow runs required behavioral packaging coverage" { test-ubuntu-packaging-workflow-contract })
        (run-test "command discovery rejects duplicate source exports before deduplication" { test-command-discovery-source-duplicates })
        (run-test "command discovery exact-matches curated help entries" { test-command-discovery-exact-help })
        (run-test "SAML CRUD commands and examples stay synchronized across help and coverage" { test-saml-help-coverage-integration })
        (run-test "fresh runtime and installer secret templates include one empty SAML bucket" { test-saml-secret-template-consistency })
    ]
}
