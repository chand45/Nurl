# Fileless response-header transport security, compatibility, and latency regressions.

def response-header-artifact-roots [extra_roots: list = []] {
    mut roots = [(test-temp-dir)]
    if $nu.os-info.name == "windows" {
        let local = ($env.LOCALAPPDATA? | default "")
        if not ($local | is-empty) {
            $roots = ($roots | append ($local | path join "NurlPrivateHttp"))
        }
    }
    $roots
    | append $extra_roots
    | where {|root| not ($root | is-empty) }
    | uniq
}

def response-header-artifacts [extra_roots: list = []] {
    response-header-artifact-roots $extra_roots
    | each {|root|
        if not ($root | path exists) {
            []
        } else {
            try {
                ls -la $root
                | where {|entry|
                    ($entry.name | path basename) | str starts-with "nurl-response-headers-"
                }
            } catch {
                []
            }
        }
    }
    | flatten
}

def assert-no-new-header-artifacts [baseline_paths: list, label: string, extra_roots: list = []] {
    let unexpected = (
        response-header-artifacts $extra_roots
        | where {|artifact| $artifact.name not-in $baseline_paths }
    )
    assert equal ($unexpected | length) 0 $"($label) created a response-header filesystem artifact"
}

def wait-for-secure-process [pid: int, expected_running: bool, attempts: int = 200] {
    mut reached = false
    for _ in 1..$attempts {
        if (command-error-process-running $pid) == $expected_running {
            $reached = true
            break
        }
        sleep 50ms
    }
    assert $reached $"process ($pid) did not reach the expected state"
}

def wait-for-wire-count [server: record, expected: int, attempts: int = 200] {
    mut reached = false
    for _ in 1..$attempts {
        if (command-error-wire-events $server | length) >= $expected {
            $reached = true
            break
        }
        sleep 50ms
    }
    assert $reached $"server did not observe ($expected) requests"
}

def secure-python [] {
    let candidates = (
        (which python3 | append (which python))
        | where type == "external"
        | get command
    )
    if ($candidates | is-empty) {
        error make {msg: "Python is required for POSIX response-header process tests"}
    }
    $candidates | first
}

def start-secure-client [
    tmp: string
    root: string
    command: string
    label: string
    redirected_temp: string = ""
] {
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

if sys.argv[5]:
    os.environ["TMPDIR"] = sys.argv[5]
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
        ^$python $launcher $nu.current-exe $script $stdout $stderr $redirected_temp | complete
    }
    assert equal $launched.exit_code 0 $"could not launch response-header client: ($launched.stderr)"
    {
        pid: ($launched.stdout | str trim | into int)
        stdout: $stdout
        stderr: $stderr
    }
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

def make-fake-curl [
    dir: string
    version: string
    mode: string
    --version-line: string = ""
] {
    let log = ($dir | path join "request-invocations.log")
    if $nu.os-info.name == "windows" {
        let fake = ($dir | path join "curl.exe")
        let compile_script = '
$ErrorActionPreference = "Stop"
$source = @"
using System;
using System.IO;

public static class FakeCurl
{
    public static int Main(string[] args)
    {
        string version = Environment.GetEnvironmentVariable("NURL_FAKE_CURL_VERSION") ?? "8.13.0";
        string log = Environment.GetEnvironmentVariable("NURL_FAKE_CURL_LOG");
        if (args.Length > 0 && args[0] == "--version")
        {
            if (!String.IsNullOrEmpty(log))
            {
                File.AppendAllText(log, "version" + Environment.NewLine);
            }
            string versionLine = Environment.GetEnvironmentVariable("NURL_FAKE_CURL_VERSION_LINE");
            Console.WriteLine(String.IsNullOrEmpty(versionLine)
                ? "curl " + version + " Windows libcurl/" + version
                : versionLine);
            return 0;
        }
        string mode = Environment.GetEnvironmentVariable("NURL_FAKE_CURL_MODE") ?? "";
        string format = "";
        string outputPath = "";
        string sensitiveArguments = "";
        string expectedSecret = Environment.GetEnvironmentVariable("NURL_FAKE_CURL_EXPECTED_SECRET") ?? "";
        for (int index = 0; index + 1 < args.Length; index++)
        {
            if (args[index] == "--write-out")
            {
                format = args[index + 1];
            }
            if (args[index] == "-o")
            {
                outputPath = args[index + 1];
            }
            if (args[index] == "-H")
            {
                string header = args[index + 1];
                if (header.StartsWith("Authorization:", StringComparison.OrdinalIgnoreCase)
                    || header.StartsWith("Proxy-Authorization:", StringComparison.OrdinalIgnoreCase)
                    || header.StartsWith("X-API-Key:", StringComparison.OrdinalIgnoreCase))
                {
                    sensitiveArguments += " " + header;
                }
            }
            if (args[index] == "-u")
            {
                sensitiveArguments += " Basic " + args[index + 1];
            }
        }
        if (mode == "supported-oauth" && format.IndexOf("%{time_total}", StringComparison.Ordinal) < 0)
        {
            if (!String.IsNullOrEmpty(log))
            {
                File.AppendAllText(log, "token" + Environment.NewLine);
            }
            string token = Environment.GetEnvironmentVariable("NURL_FAKE_CURL_OAUTH_TOKEN");
            if (String.IsNullOrEmpty(token))
            {
                token = "SUPPORTED-ACCESS";
            }
            string tokenMetadata = format.Replace("%{http_code}", "200");
            Console.Out.Write("{\"access_token\":\"" + token + "\",\"refresh_token\":\"SUPPORTED-REFRESH\",\"expires_in\":3600}" + tokenMetadata);
            return 0;
        }
        if (!String.IsNullOrEmpty(log))
        {
            File.AppendAllText(log, "request" + Environment.NewLine);
        }
        int requestNumber = 0;
        if (!String.IsNullOrEmpty(log) && File.Exists(log))
        {
            foreach (string line in File.ReadAllLines(log))
            {
                if (line == "request")
                {
                    requestNumber++;
                }
            }
        }
        if (mode == "transport-unframed" || (mode == "transport-unframed-eventual-success" && requestNumber == 1))
        {
            if (!String.IsNullOrEmpty(expectedSecret)
                && sensitiveArguments.IndexOf(expectedSecret, StringComparison.Ordinal) >= 0)
            {
                File.AppendAllText(log, "exact-sensitive-match" + Environment.NewLine);
            }
            Console.Error.WriteLine("\u001b[31mcurl: (7) deterministic transport failure" + sensitiveArguments + "\u001b[0m");
            return 7;
        }
        if (mode == "transport-failure" || mode == "partial-timeout" || (mode == "transport-eventual-success" && requestNumber == 1))
        {
            int exitCode = mode == "partial-timeout" ? 28 : 7;
            if (!String.IsNullOrEmpty(expectedSecret)
                && sensitiveArguments.IndexOf(expectedSecret, StringComparison.Ordinal) >= 0)
            {
                File.AppendAllText(log, "exact-sensitive-match" + Environment.NewLine);
            }
            Console.Error.WriteLine("\u001b[31mcurl: (" + exitCode + ") deterministic transport failure" + sensitiveArguments + "\u001b[0m");
            if (!String.IsNullOrEmpty(outputPath))
            {
                File.WriteAllBytes(outputPath, new byte[] { 1, 2 });
            }
            Console.Error.WriteLine("\u001b[31mcurl: (" + exitCode + ") deterministic transport failure Authorization: Bearer TRANSPORT-TOKEN-SENTINEL\u001b[0m");
            string metadata = format
                .Replace("%{stderr}", "")
                .Replace("%{http_code}", "000")
                .Replace("%{time_total}", "0.001")
                .Replace("%{size_download}", String.IsNullOrEmpty(outputPath) ? "0" : "2")
                .Replace("%{size_header}", "0")
                .Replace("%{exitcode}", exitCode.ToString());
            Console.Error.Write(metadata);
            return exitCode;
        }
        if (mode == "malformed")
        {
            Console.Error.WriteLine("FAKE-CURL-DIAGNOSTIC NURL_RESPONSE_META_static_BEGIN INTERNAL-METADATA-SENTINEL");
            Console.Out.Write("UNTRUSTED-BODY-SENTINEL");
            return 0;
        }
        if (mode == "supported" || mode == "supported-oauth" || mode == "transport-eventual-success" || mode == "transport-unframed-eventual-success" || mode == "size-too-large" || mode == "size-too-small" || mode == "malformed-trailer" || mode.StartsWith("invalid-trailer"))
        {
            string header = "HTTP/1.1 200 OK\r\nETag: \"fake\"\r\nContent-Length: 4\r\n\r\n";
            string trailer = mode == "malformed-trailer"
                ? "NOT-A-TRAILER\r\n"
                : (mode == "invalid-trailer-name"
                    ? "Bad Name: value\r\n"
                    : (mode == "invalid-trailer-leading-space"
                        ? " Bad: value\r\n"
                        : (mode == "invalid-trailer-before-colon"
                            ? "Bad : value\r\n"
                            : (mode == "invalid-trailer-tab-before-colon" ? "Bad\t: value\r\n" : ""))));
            string output = header + "BODY" + trailer;
            if (String.IsNullOrEmpty(outputPath))
            {
                Console.Out.Write(output);
            }
            else
            {
                File.WriteAllBytes(outputPath, System.Text.Encoding.ASCII.GetBytes("BODY"));
            }
            string headerSize = mode == "size-too-large"
                ? "9999"
                : (mode == "size-too-small" ? "10" : System.Text.Encoding.ASCII.GetByteCount(header).ToString());
            string metadata = format
                .Replace("%{stderr}", "")
                .Replace("%{http_code}", "200")
                .Replace("%{time_total}", "0.001")
                .Replace("%{size_download}", "4")
                .Replace("%{size_header}", headerSize)
                .Replace("%{exitcode}", "0");
            Console.Error.Write(metadata);
            return 0;
        }
        return 99;
    }
}
"@
Add-Type -TypeDefinition $source -OutputAssembly $env:NURL_FAKE_CURL_EXE -OutputType ConsoleApplication
'
        let compiled = (with-env {NURL_FAKE_CURL_EXE: $fake} {
            ^powershell.exe -NoProfile -NonInteractive -Command $compile_script | complete
        })
        assert equal $compiled.exit_code 0 $"could not compile deterministic fake curl: ($compiled.stderr)"
    } else {
        let fake = ($dir | path join "curl")
        let request_action = if $mode == "malformed" {
            'echo request >> "$NURL_FAKE_CURL_LOG"
printf "%s\n" "FAKE-CURL-DIAGNOSTIC NURL_RESPONSE_META_static_BEGIN INTERNAL-METADATA-SENTINEL" >&2
printf "%s" "UNTRUSTED-BODY-SENTINEL"
exit 0'
        } else if $mode in ["transport-unframed" "transport-unframed-eventual-success"] {
            'format=""
sensitive_arguments=""
previous=""
for argument in "$@"; do
  if [ "x$previous" = "x--write-out" ]; then
    format="$argument"
  fi
  if [ "x$previous" = "x-H" ]; then
    case "$argument" in
      [Aa]uthorization:*|[Pp]roxy-[Aa]uthorization:*|[Xx]-[Aa][Pp][Ii]-[Kk]ey:*)
        sensitive_arguments="$sensitive_arguments $argument"
        ;;
    esac
  fi
  if [ "x$previous" = "x-u" ]; then
    sensitive_arguments="$sensitive_arguments Basic $argument"
  fi
  previous="$argument"
done
echo request >> "$NURL_FAKE_CURL_LOG"
request_number=$(grep -c "^request$" "$NURL_FAKE_CURL_LOG")
if [ "x$NURL_FAKE_CURL_MODE" = "xtransport-unframed" ] || [ "$request_number" -eq 1 ]; then
  if [ -n "$NURL_FAKE_CURL_EXPECTED_SECRET" ]; then
    case "$sensitive_arguments" in
      *"$NURL_FAKE_CURL_EXPECTED_SECRET"*)
        echo exact-sensitive-match >> "$NURL_FAKE_CURL_LOG"
        ;;
    esac
  fi
  printf "\033[31mcurl: (7) deterministic transport failure%s\033[0m\n" "$sensitive_arguments" >&2
  exit 7
fi
printf "HTTP/1.1 200 OK\r\nETag: \"fake\"\r\nContent-Length: 4\r\n\r\nBODY"
metadata=$(printf "%s" "$format" | sed \
  -e "s/%{stderr}//g" \
  -e "s/%{http_code}/200/g" \
  -e "s/%{time_total}/0.001/g" \
  -e "s/%{size_download}/4/g" \
  -e "s/%{size_header}/52/g" \
  -e "s/%{exitcode}/0/g")
printf "%s" "$metadata" >&2
exit 0'
        } else if $mode in ["transport-failure" "transport-eventual-success" "partial-timeout"] {
            'format=""
output_path=""
sensitive_arguments=""
previous=""
for argument in "$@"; do
  if [ "x$previous" = "x--write-out" ]; then
    format="$argument"
  fi
  if [ "x$previous" = "x-o" ]; then
    output_path="$argument"
  fi
  if [ "x$previous" = "x-H" ]; then
    case "$argument" in
      [Aa]uthorization:*|[Pp]roxy-[Aa]uthorization:*|[Xx]-[Aa][Pp][Ii]-[Kk]ey:*)
        sensitive_arguments="$sensitive_arguments $argument"
        ;;
    esac
  fi
  if [ "x$previous" = "x-u" ]; then
    sensitive_arguments="$sensitive_arguments Basic $argument"
  fi
  previous="$argument"
done
echo request >> "$NURL_FAKE_CURL_LOG"
request_number=$(grep -c "^request$" "$NURL_FAKE_CURL_LOG")
if [ "x$NURL_FAKE_CURL_MODE" = "xtransport-failure" ] || [ "x$NURL_FAKE_CURL_MODE" = "xpartial-timeout" ] || [ "$request_number" -eq 1 ]; then
  exit_code=7
  download_size=0
  if [ "x$NURL_FAKE_CURL_MODE" = "xpartial-timeout" ]; then
    exit_code=28
  fi
  if [ -n "$output_path" ]; then
    printf "\001\002" > "$output_path"
    download_size=2
  fi
  if [ -n "$NURL_FAKE_CURL_EXPECTED_SECRET" ]; then
    case "$sensitive_arguments" in
      *"$NURL_FAKE_CURL_EXPECTED_SECRET"*)
        echo exact-sensitive-match >> "$NURL_FAKE_CURL_LOG"
        ;;
    esac
  fi
  printf "\033[31mcurl: (%s) deterministic transport failure%s\033[0m\n" "$exit_code" "$sensitive_arguments" >&2
  printf "\033[31mcurl: (%s) deterministic transport failure Authorization: Bearer TRANSPORT-TOKEN-SENTINEL\033[0m\n" "$exit_code" >&2
  metadata=$(printf "%s" "$format" | sed \
    -e "s/%{stderr}//g" \
    -e "s/%{http_code}/000/g" \
    -e "s/%{time_total}/0.001/g" \
    -e "s/%{size_download}/$download_size/g" \
    -e "s/%{size_header}/0/g" \
    -e "s/%{exitcode}/$exit_code/g")
  printf "%s" "$metadata" >&2
  exit "$exit_code"
fi
if [ -n "$output_path" ]; then
  printf "BODY" > "$output_path"
else
  printf "HTTP/1.1 200 OK\r\nETag: \"fake\"\r\nContent-Length: 4\r\n\r\nBODY"
fi
metadata=$(printf "%s" "$format" | sed \
  -e "s/%{stderr}//g" \
  -e "s/%{http_code}/200/g" \
  -e "s/%{time_total}/0.001/g" \
  -e "s/%{size_download}/4/g" \
  -e "s/%{size_header}/52/g" \
  -e "s/%{exitcode}/0/g")
printf "%s" "$metadata" >&2
exit 0'
        } else if $mode in ["supported" "supported-oauth" "size-too-large" "size-too-small" "malformed-trailer"] or ($mode | str starts-with "invalid-trailer") {
            let header_size = if $mode == "size-too-large" {
                "9999"
            } else if $mode == "size-too-small" {
                "10"
            } else {
                "52"
            }
            let trailer = if $mode == "malformed-trailer" {
                "NOT-A-TRAILER\\r\\n"
            } else if $mode == "invalid-trailer-name" {
                "Bad Name: value\\r\\n"
            } else if $mode == "invalid-trailer-leading-space" {
                " Bad: value\\r\\n"
            } else if $mode == "invalid-trailer-before-colon" {
                "Bad : value\\r\\n"
            } else if $mode == "invalid-trailer-tab-before-colon" {
                "Bad\\t: value\\r\\n"
            } else {
                ""
            }
            'format=""
output_path=""
previous=""
for argument in "$@"; do
  if [ "x$previous" = "x--write-out" ]; then
    format="$argument"
  fi
  if [ "x$previous" = "x-o" ]; then
    output_path="$argument"
  fi
  previous="$argument"
done
if [ "x$NURL_FAKE_CURL_MODE" = "xsupported-oauth" ]; then
  case "$format" in
    *"%{time_total}"*)
      ;;
    *)
      echo token >> "$NURL_FAKE_CURL_LOG"
      token=${NURL_FAKE_CURL_OAUTH_TOKEN:-SUPPORTED-ACCESS}
      token_metadata=$(printf "%s" "$format" | sed -e "s/%{http_code}/200/g")
      printf "%s%s" "{\"access_token\":\"$token\",\"refresh_token\":\"SUPPORTED-REFRESH\",\"expires_in\":3600}" "$token_metadata"
      exit 0
      ;;
  esac
fi
echo request >> "$NURL_FAKE_CURL_LOG"
if [ -n "$output_path" ]; then
  printf "BODY" > "$output_path"
else
  printf "HTTP/1.1 200 OK\r\nETag: \"fake\"\r\nContent-Length: 4\r\n\r\nBODYTRAILER_TEXT"
fi
metadata=$(printf "%s" "$format" | sed \
  -e "s/%{stderr}//g" \
  -e "s/%{http_code}/200/g" \
  -e "s/%{time_total}/0.001/g" \
  -e "s/%{size_download}/4/g" \
  -e "s/%{size_header}/HEADER_SIZE/g" \
  -e "s/%{exitcode}/0/g")
metadata=$(printf "%s" "$metadata" | sed "s/HEADER_SIZE/' + $header_size + '/g")
printf "%s" "$metadata" >&2
exit 0' | str replace "TRAILER_TEXT" $trailer
        } else {
            'echo request >> "$NURL_FAKE_CURL_LOG"
exit 99'
        }
        $"#!/bin/sh
if [ \"x$1\" = \"x--version\" ]; then
  echo version >> \"$NURL_FAKE_CURL_LOG\"
  if [ -n \"$NURL_FAKE_CURL_VERSION_LINE\" ]; then
    printf \"%s\\n\" \"$NURL_FAKE_CURL_VERSION_LINE\"
  else
    echo \"curl ($version) libcurl/($version)\"
  fi
  exit 0
fi
($request_action)
" | str replace --all "\r\n" "\n" | save -f $fake
        ^chmod 700 $fake
    }
    {path: $dir, log: $log, version: $version, version_line: $version_line, mode: $mode}
}

def run-with-fake-curl [root: string, fake: record, command: string] {
    let setup = (
        "$env.PATH = (["
        + ($fake.path | to nuon)
        + "] | append $env.PATH)\n$env.NURL_FAKE_CURL_LOG = "
        + ($fake.log | to nuon)
        + "\n$env.NURL_FAKE_CURL_VERSION = "
        + ($fake.version | to nuon)
        + "\n$env.NURL_FAKE_CURL_VERSION_LINE = "
        + ($fake.version_line | to nuon)
        + "\n$env.NURL_FAKE_CURL_MODE = "
        + ($fake.mode | to nuon)
        + "\n$env.NURL_FAKE_CURL_OAUTH_TOKEN = "
        + (($fake.oauth_token? | default "") | to nuon)
        + "\n$env.NURL_FAKE_CURL_EXPECTED_SECRET = "
        + (($fake.expected_secret? | default "") | to nuon)
    )
    run-command-process $root ($setup + "\n" + $command)
}

def summarize-latency [samples: list] {
    let sorted = ($samples | sort)
    let p95_index = (((($sorted | length) * 0.95) | math ceil) - 1)
    {
        median_ms: ($sorted | math median | math round --precision 2)
        p95_ms: ($sorted | get $p95_index | math round --precision 2)
    }
}

def measure-latency [count: int, operation: closure] {
    1..$count | each {
        let started = (date now)
        do $operation
        ((date now) - $started) / 1ms
    }
}

def test-fileless-header-correctness-and-secrecy [] {
    let root = (make-temp-dir "fileless-header-correctness")
    let infra = (make-temp-dir "fileless-header-correctness-server")
    let server = (surface-server $infra)
    let baseline = (response-header-artifacts | get name? | default [])
    let failure = try {
        surface-workspace $root $server
        let base = $"http://127.0.0.1:($server.port)"

        let sensitive_command = (
            "let result = (api get "
            + (($base + "/sensitive-headers") | to nuon)
            + " --raw); if ($result.response.headers | get 'Set-Cookie') != '******' { error make {msg: 'cookie header was not masked'} }; if ($result.response.headers | get 'X-Session-Token') != '******' { error make {msg: 'token header was not masked'} }; if ($result.response.headers | get 'X-Debug-Auth') != '******' { error make {msg: 'auth-like header was not masked'} }; print 'sensitive response headers parsed safely'"
        )
        let sensitive = (run-command-process $root $sensitive_command)
        assert equal $sensitive.exit_code 0 "sensitive response-header parse failed"
        assert ($sensitive.stdout | str contains "sensitive response headers parsed safely") "sensitive headers were not masked in the typed response"
        assert (not ($"($sensitive.stdout)\n($sensitive.stderr)" | str contains "RESPONSE-COOKIE-SENTINEL")) "typed response exposed the cookie sentinel"
        assert (not ($"($sensitive.stdout)\n($sensitive.stderr)" | str contains "RESPONSE-TOKEN-SENTINEL")) "typed response exposed the token sentinel"

        let displayed = (run-command-process $root $"api get (($base + '/sensitive-headers') | to nuon) --include --no-history")
        assert equal $displayed.exit_code 0 "redacted human response failed"
        assert ($displayed.stdout | str contains "******") "sensitive human response headers were not redacted"

        let duplicate = (run-command-process $root (
            "let result = (api get "
            + (($base + "/duplicate-headers") | to nuon)
            + " --raw --no-history); let headers = $result.response.headers; if ($headers | get 'X-Duplicate') != 'first, second' { error make {msg: 'duplicate-header values were not folded'} }; if ($headers | get 'x-mIxEd-DuPe') != 'first, second' { error make {msg: 'mixed-case duplicate did not preserve values/spelling'} }; if 'X-Mixed-Dupe' in ($headers | columns) { error make {msg: 'mixed-case duplicate kept the earlier alias'} }; if ($headers | get 'x.tRACE+id') != 'first, second' { error make {msg: 'metacharacter duplicate did not preserve values/spelling'} }; if 'X.Trace+ID' in ($headers | columns) { error make {msg: 'metacharacter duplicate kept the earlier alias'} }; if ($headers | get 'XxTraceeID') != 'distinct' { error make {msg: 'metacharacter header comparison was not literal'} }; if ($headers | get 'X-Marker-Like') != 'NURL_RESPONSE_META_static_BEGIN' { error make {msg: 'marker-like header changed'} }; print 'duplicate and marker headers parsed'"
        ))
        assert equal $duplicate.exit_code 0 $"duplicate response-header parse failed: ($duplicate.stderr)"

        let trailers = (run-command-process $root (
            "let result = (api get "
            + (($base + "/trailers") | to nuon)
            + " --raw); let headers = $result.response.headers; if $result.response.body != 'BODY' { error make {msg: 'trailers contaminated the body'} }; if ($headers | get 'x-TrAiLeR-CaSe') != 'trailer-value' { error make {msg: 'trailer spelling/value changed'} }; if ($headers | get 'x-MiXeD-TrAiLeR') != 'first, second' { error make {msg: 'mixed-case trailer duplicate changed'} }; if 'X-Mixed-Trailer' in ($headers | columns) { error make {msg: 'mixed-case trailer kept the earlier alias'} }; if ($headers | get 'X-Trailer-Repeat') != 'one, two' { error make {msg: 'repeated trailer values were not folded'} }; if ($headers | get 'x-Override') != 'trailer-value' { error make {msg: 'trailer did not override the response header'} }; if ($headers | get 'x-Override') == 'header-value, trailer-value' { error make {msg: 'trailer was combined across field sections'} }; if ($headers | get 'Set-Cookie') != '******' { error make {msg: 'sensitive trailer was not masked'} }; print 'trailers separated and parsed safely'"
        ))
        assert equal $trailers.exit_code 0 $"response-trailer parse failed: ($trailers.stderr)"
        let trailer_history_id = (api history list --limit 1 | first | get id)
        let trailer_history = (api history show $trailer_history_id)
        assert equal ($trailer_history.response.headers | get "Set-Cookie") "******" "sensitive trailer was not redacted in history"
        let trailer_display = (run-command-process $root $"api get (($base + '/trailers') | to nuon) --include --no-history")
        assert equal $trailer_display.exit_code 0 "response-trailer human rendering failed"
        assert ($trailer_display.stdout | str contains "******") "sensitive trailer was not redacted in human output"
        assert (not ($trailer_display.stdout | str contains "trailer-secret-sentinel")) "sensitive trailer leaked in human output"
        let trailer_raw = (run-command-process $root $"api get (($base + '/trailers') | to nuon) --output raw --no-history")
        assert equal $trailer_raw.exit_code 0 "raw trailer response failed"
        assert equal ($trailer_raw.stdout | str trim) "BODY" "raw body included response trailers"

        let exact_case = (run-command-process $root (
            "let result = (api get "
            + (($base + "/case-headers") | to nuon)
            + " --raw --no-history); let headers = $result.response.headers; "
            + "if ($headers | get 'ETag') != '\"case-etag\"' { error make {msg: 'ETag spelling/value changed'} }; "
            + "if ($headers | get 'WWW-Authenticate') != '******' { error make {msg: 'WWW-Authenticate spelling/value changed'} }; "
            + "if ($headers | get 'X-RateLimit-Remaining') != '42' { error make {msg: 'rate-limit spelling/value changed'} }; "
            + "if ($headers | get 'x-CuStOm-AcRoNyM') != 'mixed-value' { error make {msg: 'custom spelling/value changed'} }; "
            + "if ($headers | get 'Content-Type') != 'application/json' { error make {msg: 'ordinary header changed'} }; "
            + "if ($headers | get 'X-Empty-Value') != '' { error make {msg: 'empty header value changed'} }; "
            + "for alias in ['Etag' 'X-Ratelimit-Remaining' 'X-Custom-Acronym'] { if $alias in ($headers | columns) { error make {msg: $'guessed alias survived: ($alias)'} } }; "
            + "print 'exact wire header casing preserved'"
        ))
        assert equal $exact_case.exit_code 0 $"exact response-header casing failed: ($exact_case.stderr)"
        assert ($exact_case.stdout | str contains "exact wire header casing preserved")

        api request create case-wire GET $"($base)/case-headers" --collection contracts | ignore
        api auth basic set case-basic case-user case-password | ignore
        api auth apikey set case-key case-api-key | ignore
        api auth oauth2 configure case-oauth --client-id case-client --client-secret case-secret --token-url $"($base)/token" | ignore
        mkdir ($root | path join "chains")
        {
            name: case-wire
            steps: [{method: GET, url: $"($base)/case-headers"}]
        } | to nuon --indent 4 | save -f ($root | path join "chains" "case-wire.nuon")
        let case_route_commands = [
            "let result = (api send case-wire --collection contracts --raw --no-history); $result.response.headers | get 'ETag'"
            ("let result = (api chain run ([{method: GET, url: " + (($base + "/case-headers") | to nuon) + "}]) --quiet); $result.results.0.response.headers | get 'ETag'")
            "let result = (api chain exec case-wire --quiet); $result.results.0.response.headers | get 'ETag'"
            ("let result = (api get " + (($base + "/case-headers") | to nuon) + " -a {type: basic, username: case-user, password: case-password} --raw --no-history); $result.response.headers | get 'ETag'")
            ("let result = (api get " + (($base + "/case-headers") | to nuon) + " -a {type: api_key, key: case-api-key, header: X-Case-Key} --raw --no-history); $result.response.headers | get 'ETag'")
            ("let result = (api get " + (($base + "/case-headers") | to nuon) + " -a {type: oauth2, ref: case-oauth} --raw --no-history); $result.response.headers | get 'ETag'")
            $"api get (($base + '/case-headers') | to nuon) --output headers --no-history | get 'ETag'"
            $"api get (($base + '/case-headers') | to nuon) --select headers.ETag --no-history"
            $"api get (($base + '/case-headers') | to nuon) --output json --no-history | from json | get response.headers.ETag"
        ]
        for command in $case_route_commands {
            let routed = (run-command-process $root $command)
            assert equal $routed.exit_code 0 $"header casing failed on a public execution route: ($routed.stderr)"
            assert equal ($routed.stdout | str trim) "\"case-etag\"" "public execution route changed the exact ETag key/value"
        }
        api get $"($base)/case-headers" --output none
        let latest_history = (api history list --limit 1 | first)
        let persisted_case = (api history show $latest_history.id)
        assert equal ($persisted_case.response.headers | get "ETag") "\"case-etag\"" "history changed response-header casing"
        assert ("Etag" not-in ($persisted_case.response.headers | columns)) "history persisted a guessed response-header alias"
        let case_display = (run-command-process $root $"api get (($base + '/case-headers') | to nuon) --include --no-history")
        assert equal $case_display.exit_code 0 "human header rendering failed"
        assert ($case_display.stdout | str contains "ETag") "human output changed exact response-header casing"
        assert (not ($case_display.stdout | str contains "Etag")) "human output included a guessed response-header alias"

        let redirected = (run-command-process $root (
            "let result = (api get "
            + (($base + "/redirect") | to nuon)
            + " --follow-redirects --raw --no-history); if $result.response.status != 200 { error make {msg: 'redirect final status changed'} }; if ($result.response.headers | get 'Set-Cookie') != '******' { error make {msg: 'redirect final headers missing'} }; print 'redirect final response parsed safely'"
        ))
        assert equal $redirected.exit_code 0 $"redirect response-header parse failed: ($redirected.stderr)"

        let early = (run-command-process $root (
            "let result = (api get "
            + (($base + "/early-hints") | to nuon)
            + " --raw --no-history); if $result.response.status != 200 { error make {msg: 'early-hints final status changed'} }; if ($result.response.headers | get 'X-Final') != 'final-value' { error make {msg: 'early-hints final headers missing'} }; print 'early hints final response parsed'"
        ))
        assert equal $early.exit_code 0 $"1xx response-header parse failed: ($early.stderr)"

        let empty_headers = (run-command-process $root (
            "let result = (api get "
            + (($base + "/empty-headers") | to nuon)
            + " --raw --no-history); if $result.response.status != 204 { error make {msg: 'empty-header status changed'} }; if ($result.response.headers | columns | is-not-empty) { error make {msg: 'empty-header response gained headers'} }; print 'empty headers parsed'"
        ))
        assert equal $empty_headers.exit_code 0 $"empty response-header parse failed: ($empty_headers.stderr)"

        for path in ["/sentinel" "/http-like-text" "/whitespace" "/json-string" "/json-null" "/empty"] {
            let result = (run-command-process $root $"api get (($base + $path) | to nuon) --raw --no-history | ignore")
            assert equal $result.exit_code 0 $"marker/scalar/empty body failed: ($path): ($result.stderr)"
        }

        let binary_exact = (run-command-process $root (
            "let result = (api get "
            + (($base + "/binary-body") | to nuon)
            + " --raw --no-history); if ($result.response.body | describe) !~ '^binary' { error make {msg: 'binary body was decoded as text'} }; if $result.response.body != 0x[00ff01804142] { error make {msg: 'binary body boundary changed'} }; print 'binary boundary preserved'"
        ))
        assert equal $binary_exact.exit_code 0 $"binary response-body split failed: ($binary_exact.stderr)"

        for mode in ["pretty" "raw" "body" "json" "headers" "status" "none"] {
            let result = (run-command-process $root $"api get (($base + '/success') | to nuon) --output ($mode) --no-history")
            assert equal $result.exit_code 0 $"fileless response failed for --output ($mode)"
            assert equal ($result.stderr | str trim) "" $"fileless response wrote stderr for --output ($mode)"
            assert-no-new-header-artifacts $baseline $"output mode ($mode)"
        }

        let binary_path = ($root | path join "binary-response.bin")
        let binary = (run-command-process $root $"api get (($base + '/sentinel') | to nuon) --binary-save ($binary_path | to nuon) --output none --no-history")
        assert equal $binary.exit_code 0 $"binary response failed: ($binary.stderr)"
        assert ($binary_path | path exists) "binary response was not saved"

        let persisted = (command-error-snapshot $root | to nuon)
        let public_streams = ([
            $sensitive.stdout $sensitive.stderr
            $displayed.stdout $displayed.stderr
            $duplicate.stdout $duplicate.stderr
            $trailers.stdout $trailers.stderr
            $trailer_display.stdout $trailer_display.stderr
            $trailer_raw.stdout $trailer_raw.stderr
            $exact_case.stdout $exact_case.stderr
            $case_display.stdout $case_display.stderr
            $binary_exact.stdout $binary_exact.stderr
            $redirected.stdout $redirected.stderr
            $early.stdout $early.stderr
            $empty_headers.stdout $empty_headers.stderr
        ] | str join "\n")
        let bearer_secret = (["RESPONSE" "BEARER" "SENTINEL"] | str join "-")
        for secret in [
            "RESPONSE-COOKIE-SENTINEL"
            "RESPONSE-TOKEN-SENTINEL"
            $bearer_secret
            "INTERNAL-METADATA-SENTINEL"
            "trailer-secret-sentinel"
        ] {
            assert (not ($public_streams | str contains $secret)) $"sensitive/internal header transport data leaked publicly: ($secret)"
            assert (not ($persisted | str contains $secret)) $"sensitive/internal header transport data leaked to persisted state: ($secret)"
        }
        assert (not ($public_streams | str contains "NURL_RESPONSE_META_")) "internal response metadata frame leaked publicly"
        assert-no-new-header-artifacts $baseline "correctness and secrecy"
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    assert-no-new-header-artifacts $baseline "correctness teardown"
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def test-repeated-header-folding-and-secrecy [] {
    let root = (make-temp-dir "repeated-header-folding")
    let infra = (make-temp-dir "repeated-header-folding-server")
    let server = (surface-server $infra)
    let failure = try {
        surface-workspace $root $server
        let base = $"http://127.0.0.1:($server.port)"
        let response = (api get $"($base)/repeated-headers" --raw --no-history)
        let headers = $response.response.headers

        assert equal ($headers | get "Link") "</a>; rel=\"next\", </b>; rel=\"prev\""
        assert equal ($headers | get "X-Custom") "one, two, three"
        assert equal ($headers | get "x-alPHA") "1, 3, 5"
        assert ("X-Alpha" not-in ($headers | columns)) "non-adjacent duplicate kept its earlier spelling"
        assert equal ($headers | get "X-Beta") "2"
        assert equal ($headers | get "X-Gamma") "4"
        assert equal ($headers | get "Vary") "Accept-Encoding, Origin"
        assert equal ($headers | get "WWW-Authenticate") "Digest realm=\"one\", Newauth realm=\"two\""
        assert equal ($headers | get "Proxy-Authenticate") "Digest realm=\"proxy-one\", Newauth realm=\"proxy-two\""
        assert equal ($headers | get "X-DUP") "a, b, c"
        assert ("x-dup" not-in ($headers | columns)) "earlier duplicate spelling survived"
        assert ("X-Dup" not-in ($headers | columns)) "middle duplicate spelling survived"
        assert equal ($headers | get "X-Empty-Repeat") ", "
        assert equal ($headers | get "X-Comma") "alpha,beta, gamma"
        assert equal ($headers | get "X-Colon") "urn:one:two, https://example.test:8443/path"
        assert equal ($headers | get "x.tRACE+id") "trace-one, trace-two"
        assert ("X.Trace+ID" not-in ($headers | columns)) "metacharacter duplicate kept its earlier spelling"
        let stress_expected = (1..25 | each {|index| $"v($index)" } | str join ", ")
        assert equal ($headers | get "X-Stress") $stress_expected

        for index in 1..15 {
            let name = $"X-Single-($index)"
            let value = ($headers | get $name)
            assert equal ($value | describe) "string" $"single response header type changed: ($name)"
            assert equal $value $"single-($index)" $"single response header value changed: ($name)"
        }
        let tracked_order = (
            $headers
            | columns
            | where {|name| $name in [
                "Link"
                "X-Custom"
                "x-alPHA"
                "X-Beta"
                "X-Gamma"
                "Vary"
                "WWW-Authenticate"
                "Proxy-Authenticate"
                "X-DUP"
                "X-Empty-Repeat"
                "X-Comma"
                "X-Colon"
                "x.tRACE+id"
                "Set-Cookie"
                "Set-Cookie2"
                "X-Debug-Alpha"
                "X-Debug-Beta"
                "X-Stress"
            ] }
        )
        assert equal $tracked_order [
            "Link"
            "X-Custom"
            "x-alPHA"
            "X-Beta"
            "X-Gamma"
            "Vary"
            "WWW-Authenticate"
            "Proxy-Authenticate"
            "X-DUP"
            "X-Empty-Repeat"
            "X-Comma"
            "X-Colon"
            "x.tRACE+id"
            "Set-Cookie"
            "Set-Cookie2"
            "X-Debug-Alpha"
            "X-Debug-Beta"
            "X-Stress"
        ] "folded headers did not retain first-appearance position with last spelling"
        for name in ["Set-Cookie" "Set-Cookie2" "X-Debug-Alpha" "X-Debug-Beta"] {
            assert equal ($headers | get $name) "******" $"sensitive repeated header did not collapse to one mask: ($name)"
        }
        assert equal ($headers | columns | where $it == "Set-Cookie" | length) 1
        assert equal ($headers | columns | where $it == "Set-Cookie2" | length) 1
        assert equal ($response.response | columns) ["status" "status_text" "headers" "body" "time_ms" "size_bytes"]
        assert ("headers_all" not-in ($response.response | columns)) "response schema gained headers_all"

        let challenge_response = (api get $"($base)/sensitive-challenges" --raw --no-history)
        assert equal ($challenge_response.response.headers | get "WWW-Authenticate") "******"
        assert equal ($challenge_response.response.headers | get "Proxy-Authenticate") "******"

        let redirected = (api get $"($base)/redirect-repeated" --follow-redirects --raw --no-history)
        assert equal ($redirected.response.headers | get "Link") "</a>; rel=\"next\", </b>; rel=\"prev\""
        assert (not (($redirected.response.headers | get "Link") | str contains "redirect-only")) "redirect headers were combined with the final block"

        let surface_commands = [
            $"api get (($base + '/repeated-headers') | to nuon) --raw --no-history | to nuon"
            $"api get (($base + '/repeated-headers') | to nuon) --select headers.Link --no-history"
            $"api get (($base + '/repeated-headers') | to nuon) --include --no-history"
            $"api get (($base + '/repeated-headers') | to nuon) --output pretty --no-history"
            $"api get (($base + '/repeated-headers') | to nuon) --output body --no-history"
            $"api get (($base + '/repeated-headers') | to nuon) --output raw --no-history"
            $"api get (($base + '/repeated-headers') | to nuon) --output json --no-history"
            $"api get (($base + '/repeated-headers') | to nuon) --output headers --no-history"
            $"api get (($base + '/repeated-headers') | to nuon) --output status --no-history"
            $"api get (($base + '/repeated-headers') | to nuon) --output none --no-history"
            $"api get (($base + '/sensitive-challenges') | to nuon) --include --no-history"
        ]
        mut public_streams = []
        for command in $surface_commands {
            let rendered = (run-command-process $root $command)
            assert equal $rendered.exit_code 0 $"repeated response-header surface failed: ($command): ($rendered.stderr)"
            $public_streams = ($public_streams | append [$rendered.stdout $rendered.stderr])
        }
        let selected = (run-command-process $root $"api get (($base + '/repeated-headers') | to nuon) --select headers.X-Debug-Alpha --no-history")
        assert equal $selected.exit_code 0
        assert equal ($selected.stdout | str trim) "******"
        $public_streams = ($public_streams | append [$selected.stdout $selected.stderr])

        api get $"($base)/repeated-headers" --output none
        let history_id = (api history list --limit 1 | first | get id)
        let history_entry = (api history show $history_id)
        assert equal ($history_entry.response.headers | get "Link") "</a>; rel=\"next\", </b>; rel=\"prev\""
        assert equal ($history_entry.response.headers | get "X-Debug-Alpha") "******"
        assert equal ($history_entry.response.headers | get "X-Debug-Beta") "******"
        assert equal ($history_entry.response.headers | get "Set-Cookie") "******"
        assert equal ($history_entry.response.headers | get "Set-Cookie2") "******"
        assert (not (($history_entry | to nuon) | str contains "headers_all")) "history schema gained headers_all"

        let resent = (api history resend $history_id --raw)
        assert equal ($resent.response.headers | get "Link") "</a>; rel=\"next\", </b>; rel=\"prev\""
        assert equal ($resent.response.headers | get "X-Debug-Beta") "******"

        let history_json = ($root | path join "repeated-history.json")
        let history_csv = ($root | path join "repeated-history.csv")
        api history export --format json --output $history_json | ignore
        api history export --format csv --output $history_csv | ignore
        let persisted = (
            [
                (command-error-snapshot $root | to nuon)
                (open $history_json --raw)
                (open $history_csv --raw)
                ($history_entry | to nuon)
                ($resent | to nuon)
            ]
            | str join "\n"
        )
        let reader_commands = [
            $"api history show ($history_id | to nuon) | to nuon"
            $"api history get ($history_id | to nuon) | to nuon"
            "api history export --format json"
        ]
        for command in $reader_commands {
            let reader = (run-command-process $root $command)
            assert equal $reader.exit_code 0 $"history repeated-header reader failed: ($command): ($reader.stderr)"
            $public_streams = ($public_streams | append [$reader.stdout $reader.stderr])
        }
        let exposed = ($public_streams | str join "\n")
        for secret in [
            "COOKIE-FIRST-SENTINEL"
            "COOKIE-SECOND-SENTINEL"
            "COOKIE2-FIRST-SENTINEL"
            "COOKIE2-SECOND-SENTINEL"
            "SENSITIVE-LAST-SENTINEL"
            "SENSITIVE-FIRST-SENTINEL"
            "AUTH-LAST-SENTINEL"
            "AUTH-FIRST-SENTINEL"
        ] {
            assert (not ($exposed | str contains $secret)) $"repeated response header leaked through a public stream: ($secret)"
            assert (not ($persisted | str contains $secret)) $"repeated response header leaked through history/export bytes: ($secret)"
        }
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def test-fileless-failure-retry-and-capability-contracts [] {
    let root = (make-temp-dir "fileless-header-failures")
    let infra = (make-temp-dir "fileless-header-failures-server")
    let fake_dir = (make-temp-dir "fileless-header-fake-curl")
    let server = (surface-server $infra)
    let baseline = (response-header-artifacts | get name? | default [])
    let failure = try {
        surface-workspace $root $server
        let base = $"http://127.0.0.1:($server.port)"

        let http_error = (run-command-process $root $"api get (($base + '/http-error') | to nuon) --output status --retries 2 --no-history")
        assert equal $http_error.exit_code 0 "HTTP error response/retry failed"
        assert equal ($http_error.stdout | str trim) "503" "HTTP error status was not preserved"
        assert-no-new-header-artifacts $baseline "HTTP error and retry"

        let connection = (run-command-process $root "api get 'http://127.0.0.1:1/connection-failure' --output none --retries 1 --no-history")
        assert (not ($connection.stderr | str contains "NURL_RESPONSE_META_")) "curl connection failure exposed an internal metadata frame"
        assert-no-new-header-artifacts $baseline "curl connection failure"

        let config_path = ($root | path join "config.nuon")
        open $config_path | upsert timeout_seconds 1 | save -f $config_path
        let wire_before_timeout = (command-error-wire-events $server | length)
        let timeout_started = (date now)
        let timeout = (run-command-process $root $"api get (($base + '/timeout') | to nuon) --output none --no-history")
        let timeout_ms = (((date now) - $timeout_started) / 1ms)
        assert equal (command-error-wire-events $server | length) ($wire_before_timeout + 1) "curl timeout path did not reach the endpoint"
        assert ($timeout_ms >= 500 and $timeout_ms < 5000) $"curl timeout did not stop the slow transfer within its configured subprocess bound: ($timeout_ms) ms"
        assert (not ($timeout.stderr | str contains "NURL_RESPONSE_META_")) "curl timeout exposed an internal metadata frame"
        open $config_path | upsert timeout_seconds 30 | save -f $config_path
        assert-no-new-header-artifacts $baseline "curl timeout"

        let malformed_header = (run-command-process $root $"api get (($base + '/malformed-header') | to nuon) --output none --no-history")
        assert equal $malformed_header.exit_code 0 "obs-text response-header compatibility changed"
        assert equal ($malformed_header.stderr | str trim) "" "obs-text response header wrote stderr"
        assert-no-new-header-artifacts $baseline "obs-text wire header"

        let wire_before_selection = (command-error-wire-events $server | length)
        let selection = (run-command-process $root $"api get (($base + '/post-capture-failure') | to nuon) --select response.body.missing --no-history")
        assert (not ($selection.stderr | str contains "NURL_RESPONSE_META_")) "post-response selection path exposed an internal metadata frame"
        assert equal (command-error-wire-events $server | length) ($wire_before_selection + 1) "post-response output failure did not execute"
        assert-no-new-header-artifacts $baseline "post-response output failure"

        let unsupported_dir = ($fake_dir | path join "unsupported")
        mkdir $unsupported_dir
        let unsupported = (
            make-fake-curl $unsupported_dir "7.74.0" "unsupported"
                --version-line "curl 7.74.0-vendor (x86_64-pc-linux-gnu) libcurl/7.74.0"
        )
        let capability_state = (command-error-snapshot $root)
        let wire_before_unsupported = (command-error-wire-events $server | length)
        let old_curl = (run-with-fake-curl $root $unsupported $"api get (($base + '/must-not-run') | to nuon) --output none --no-history")
        assert ($old_curl.exit_code != 0) "unsupported curl version unexpectedly succeeded"
        assert equal ($old_curl.stdout | str trim) "" "unsupported curl version wrote stdout"
        assert ($old_curl.stderr | str contains "requires curl 7.75.0 or newer") "unsupported curl diagnostic was not actionable"
        assert equal $old_curl.stderr ($old_curl.stderr | ansi strip) "unsupported curl diagnostic contained ANSI"
        assert equal (command-error-wire-events $server | length) $wire_before_unsupported "unsupported curl reached the network"
        assert equal (open $unsupported.log --raw | lines) ["version"] "unsupported curl must run only its version preflight"

        for supported_case in [
            {
                name: "minimum-posix-vendor"
                version: "7.75.0"
                version_line: "curl 7.75.0-acme1 (x86_64-pc-linux-gnu) libcurl/7.75.0"
            }
            {
                name: "7.82-windows"
                version: "7.82.5"
                version_line: "curl.exe 7.82.5 Windows libcurl/7.82.5"
            }
            {
                name: "current"
                version: "8.13.0"
                version_line: "curl 8.13.0 (x86_64-pc-linux-gnu) libcurl/8.13.0"
            }
        ] {
            let supported_dir = ($fake_dir | path join $supported_case.name)
            mkdir $supported_dir
            let supported = (
                make-fake-curl $supported_dir $supported_case.version "supported"
                    --version-line $supported_case.version_line
            )
            let command = (
                "let result = (api get "
                + (($base + "/supported-" + $supported_case.name) | to nuon)
                + " --raw --no-history); "
                + "if $result.response.status != 200 { error make {msg: 'supported curl status was not parsed'} }; "
                + "if ($result.response.headers | get 'ETag') != '\"fake\"' { error make {msg: 'supported curl headers were not parsed'} }; "
                + "if $result.response.body != 'BODY' { error make {msg: 'supported curl body was not parsed'} }; "
                + "print 'supported fileless transfer'"
            )
            let accepted = (run-with-fake-curl $root $supported $command)
            assert equal $accepted.exit_code 0 $"compatible curl was rejected: ($supported_case.name): ($accepted.stderr)"
            assert ($accepted.stdout | str contains "supported fileless transfer") $"compatible curl did not complete: ($supported_case.name)"
            assert equal ($accepted.stderr | str trim) "" $"compatible curl wrote stderr: ($supported_case.name)"
            assert equal (open $supported.log --raw | lines) ["version" "request"] $"compatible curl did not exercise one preflight and every framed write-out variable: ($supported_case.name)"
        }

        for malformed_case in [
            {name: "missing-version", line: "curl"}
            {name: "malformed-version", line: "curl release-seven-seventy-five"}
            {name: "numeric-tail", line: "curl 7.75.0.1 libcurl/7.75.0"}
        ] {
            let malformed_version_dir = ($fake_dir | path join $malformed_case.name)
            mkdir $malformed_version_dir
            let malformed_version = (
                make-fake-curl $malformed_version_dir "7.75.0" "supported"
                    --version-line $malformed_case.line
            )
            let rejected = (run-with-fake-curl $root $malformed_version $"api get (($base + '/must-not-run') | to nuon) --output none --no-history")
            assert ($rejected.exit_code != 0) $"malformed curl version unexpectedly succeeded: ($malformed_case.name)"
            assert equal ($rejected.stdout | str trim) "" $"malformed curl version wrote stdout: ($malformed_case.name)"
            assert ($rejected.stderr | str contains "Could not determine whether curl supports fileless response metadata") $"malformed curl version diagnostic was not actionable: ($malformed_case.name)"
            assert equal $rejected.stderr ($rejected.stderr | ansi strip) $"malformed curl version diagnostic contained ANSI: ($malformed_case.name)"
            assert equal (open $malformed_version.log --raw | lines) ["version"] $"malformed curl version advanced beyond the preflight: ($malformed_case.name)"
        }

        let missing_curl_dir = ($fake_dir | path join "missing-curl")
        mkdir $missing_curl_dir
        let missing_curl_command = (
            "$env.PATH = ["
            + ($missing_curl_dir | to nuon)
            + "]\napi get "
            + (($base + "/must-not-run") | to nuon)
            + " --output none --no-history"
        )
        let missing_curl = (run-command-process $root $missing_curl_command)
        assert ($missing_curl.exit_code != 0) "missing curl executable unexpectedly succeeded"
        assert equal ($missing_curl.stdout | str trim) "" "missing curl executable wrote stdout"
        assert ($missing_curl.stderr | str contains "requires curl 7.75.0 or newer") "missing curl diagnostic was not actionable"
        assert equal $missing_curl.stderr ($missing_curl.stderr | ansi strip) "missing curl diagnostic contained ANSI"
        assert equal (command-error-snapshot $root) $capability_state "capability boundary fixtures mutated workspace state"
        assert equal (command-error-wire-events $server | length) $wire_before_unsupported "capability boundary fixtures reached the real network"

        let malformed_dir = ($fake_dir | path join "malformed")
        mkdir $malformed_dir
        let malformed = (make-fake-curl $malformed_dir "8.13.0" "malformed")
        let malformed_frame = (run-with-fake-curl $root $malformed $"api get (($base + '/fake-transfer') | to nuon) --retries 2 --output none --no-history")
        assert ($malformed_frame.exit_code != 0) "missing trusted metadata frame unexpectedly succeeded"
        assert equal ($malformed_frame.stdout | str trim) "" "malformed metadata frame exposed response body"
        assert ($malformed_frame.stderr | str contains "trusted response metadata") $"malformed metadata diagnostic was not actionable: ($malformed_frame.stderr)"
        for forbidden in ["FAKE-CURL-DIAGNOSTIC" "INTERNAL-METADATA-SENTINEL" "UNTRUSTED-BODY-SENTINEL" "NURL_RESPONSE_META_static_BEGIN"] {
            assert (not ($malformed_frame.stdout | str contains $forbidden)) $"malformed metadata leaked to stdout: ($forbidden)"
            assert (not ($malformed_frame.stderr | str contains $forbidden)) $"malformed metadata leaked to stderr: ($forbidden)"
        }
        assert equal (open $malformed.log --raw | lines | where $it == "request" | length) 1 "successful curl with malformed metadata was retried"

        for mode in ["size-too-large" "size-too-small"] {
            let mismatch_dir = ($fake_dir | path join $mode)
            mkdir $mismatch_dir
            let mismatch = (make-fake-curl $mismatch_dir "8.13.0" $mode)
            let mismatch_result = (run-with-fake-curl $root $mismatch $"api get (($base + '/fake-transfer') | to nuon) --output none --no-history")
            assert ($mismatch_result.exit_code != 0) $"mismatched size_header unexpectedly succeeded: ($mode)"
            assert equal ($mismatch_result.stdout | str trim) "" $"mismatched size_header exposed body: ($mode)"
            assert ($mismatch_result.stderr | str contains "response header size") $"mismatched size_header diagnostic was not actionable: ($mode): ($mismatch_result.stderr)"
            assert (not ($mismatch_result.stderr | str contains "NURL_RESPONSE_META_")) $"mismatched size_header exposed internal framing: ($mode)"
        }
        for mode in [
            "malformed-trailer"
            "invalid-trailer-name"
            "invalid-trailer-leading-space"
            "invalid-trailer-before-colon"
            "invalid-trailer-tab-before-colon"
        ] {
            let malformed_trailer_dir = ($fake_dir | path join $mode)
            mkdir $malformed_trailer_dir
            let malformed_trailer = (make-fake-curl $malformed_trailer_dir "8.13.0" $mode)
            let malformed_trailer_result = (run-with-fake-curl $root $malformed_trailer $"api get (($base + '/fake-transfer') | to nuon) --output none --no-history")
            assert ($malformed_trailer_result.exit_code != 0) $"malformed response trailers unexpectedly succeeded: ($mode)"
            assert equal ($malformed_trailer_result.stdout | str trim) "" $"malformed response trailers exposed body output: ($mode)"
            assert ($malformed_trailer_result.stderr | str contains "malformed response trailers") $"malformed trailer diagnostic was not actionable: ($mode): ($malformed_trailer_result.stderr)"
            assert (not ($malformed_trailer_result.stderr | str contains "NURL_RESPONSE_META_")) $"malformed response trailers exposed internal framing: ($mode)"
        }
        assert-no-new-header-artifacts $baseline "capability and malformed framing"
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    assert-no-new-header-artifacts $baseline "failure teardown"
    cleanup $root
    cleanup $infra
    cleanup $fake_dir
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def test-unsupported-curl-precedes-oauth-and-state [] {
    let root = (make-temp-dir "old-curl-oauth-preflight")
    let infra = (make-temp-dir "old-curl-oauth-server")
    let fake_dir = (make-temp-dir "old-curl-oauth-fake")
    let server = (surface-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let base = $"http://127.0.0.1:($server.port)"
        api collection create preflight | ignore
        api auth oauth2 configure obtain --client-id obtain-client --client-secret obtain-secret --token-url $"($base)/token" | ignore
        api auth oauth2 configure refresh --client-id refresh-client --client-secret refresh-secret --token-url $"($base)/token" | ignore

        let secrets_path = ($root | path join "secrets.nuon")
        let expired = (
            open $secrets_path
            | update oauth.refresh.access_token "OLD-ACCESS-SENTINEL"
            | update oauth.refresh.refresh_token "OLD-REFRESH-SENTINEL"
            | update oauth.refresh.expires_at "2000-01-01T00:00:00Z"
        )
        $expired | to nuon --indent 4 | save -f $secrets_path

        api request create oauth-saved GET $"($base)/saved-protected" --collection preflight --auth {type: oauth2, ref: obtain} | ignore
        mkdir ($root | path join "chains")
        {
            name: preflight
            steps: [{
                method: GET
                url: $"($base)/named-chain-protected"
                auth: {type: oauth2, ref: refresh}
            }]
        } | to nuon --indent 4 | save -f ($root | path join "chains" "preflight.nuon")
        let history_id = (api history save {
            method: GET
            url: $"($base)/history-protected"
            headers: {}
            body: null
        } {
            status: 200
            status_text: OK
            headers: {}
            body: null
            time_ms: 1
            size_bytes: 0
        })

        let output_file = ($root | path join "must-not-exist.bin")
        let save_file = ($root | path join "must-not-save.txt")
        let missing_body_file = ($root | path join "missing-body.json")
        let dry_run_before = (command-error-snapshot $root)
        let dry_run_commands = [
            $"api get (($base + '/dry-run-obtain') | to nuon) -a {type: oauth2, ref: obtain} --dry-run --no-history"
            $"api get (($base + '/dry-run-refresh') | to nuon) -a {type: oauth2, ref: refresh} --dry-run --no-history"
            "api request export oauth-saved --collection preflight"
        ]
        for command in $dry_run_commands {
            let rendered = (run-command-process $root $command)
            assert equal $rendered.exit_code 0 $"OAuth dry-run/export failed: ($command)"
            assert ($rendered.stdout | str contains "Authorization: ******") $"OAuth dry-run/export omitted the redacted header: ($command)"
            assert equal ($rendered.stderr | str trim) "" $"OAuth dry-run/export wrote stderr: ($command)"
            for secret in ["obtain-secret" "refresh-secret" "OLD-ACCESS-SENTINEL" "OLD-REFRESH-SENTINEL"] {
                assert (not ($rendered.stdout | str contains $secret)) $"OAuth dry-run/export leaked state: ($secret)"
            }
        }
        assert equal (command-error-snapshot $root) $dry_run_before "OAuth dry-run/export mutated request/config/secret/history state"
        assert equal (open $server.count_file --raw | str trim) "0" "OAuth dry-run/export reached the token endpoint"
        assert equal (command-error-wire-events $server | length) 0 "OAuth dry-run/export reached a protected endpoint"

        let unsupported_dir = ($fake_dir | path join "unsupported")
        mkdir $unsupported_dir
        let unsupported = (
            make-fake-curl $unsupported_dir "7.74.0" "unsupported"
                --version-line "curl 7.74.0-vendor (x86_64-pc-linux-gnu) libcurl/7.74.0"
        )
        let before = (command-error-snapshot $root)
        let invalid_output = (run-with-fake-curl $root $unsupported $"api get (($base + '/invalid-output') | to nuon) --output Pretty --no-history")
        assert ($invalid_output.exit_code != 0) "invalid output mode unexpectedly succeeded"
        assert ($invalid_output.stderr | str contains "Unsupported output mode") "invalid output must precede curl capability probing"
        assert (not ($unsupported.log | path exists)) "invalid output mode invoked curl capability probing"
        let commands = [
            $"api request -m GET (($base + '/direct-protected') | to nuon) -a {type: oauth2, ref: obtain} --output none --no-history"
            $"api request -m POST (($base + '/body-file-protected') | to nuon) --body-file ($missing_body_file | to nuon) -a {type: oauth2, ref: obtain} --save ($save_file | to nuon) --output none --no-history"
            "api send oauth-saved --collection preflight --output none --no-history"
            $"api chain run ([{method: GET, url: (($base + '/inline-chain-protected') | to nuon), auth: {type: oauth2, ref: obtain}}]) --quiet | ignore"
            "api chain exec preflight --quiet | ignore"
            $"api get (($base + '/binary-protected') | to nuon) -a {type: oauth2, ref: refresh} --binary-save ($output_file | to nuon) --output none --no-history"
            $"api history resend ($history_id | to nuon) -a {type: oauth2, ref: obtain} --raw | ignore"
        ]
        for command in $commands {
            let rejected = (run-with-fake-curl $root $unsupported $command)
            assert ($rejected.exit_code != 0) $"unsupported curl unexpectedly executed: ($command)"
            assert equal ($rejected.stdout | str trim) "" $"unsupported curl wrote stdout: ($command)"
            assert ($rejected.stderr | str contains "requires curl 7.75.0 or newer") $"unsupported curl diagnostic was not actionable: ($command)"
            assert equal $rejected.stderr ($rejected.stderr | ansi strip) $"unsupported curl diagnostic contained ANSI: ($command)"
            for secret in ["obtain-secret" "refresh-secret" "OLD-ACCESS-SENTINEL" "OLD-REFRESH-SENTINEL" "ACCESS-TOKEN-SENTINEL" "REFRESH-TOKEN-SENTINEL"] {
                assert (not ($rejected.stderr | str contains $secret)) $"unsupported curl leaked OAuth state: ($secret)"
            }
        }

        assert equal (command-error-snapshot $root) $before "unsupported curl mutated request/config/secret/history state"
        assert (not ($output_file | path exists)) "unsupported curl created the binary output file"
        assert (not ($save_file | path exists)) "unsupported curl created the text output file"
        assert equal (open $server.count_file --raw | str trim) "0" "unsupported curl reached the OAuth token endpoint"
        assert equal (command-error-wire-events $server | length) 0 "unsupported curl reached a protected endpoint"
        let invocations = (open $unsupported.log --raw | lines)
        assert equal ($invocations | length) ($commands | length) "each rejected route must perform exactly one capability probe"
        assert equal ($invocations | where $it != "version" | length) 0 "unsupported curl advanced beyond a version probe"

        for supported_case in [
            {
                name: "minimum-obtain"
                version: "7.75.0"
                version_line: "curl 7.75.0-acme1 (x86_64-pc-linux-gnu) libcurl/7.75.0"
                auth_ref: "obtain"
            }
            {
                name: "7.82-refresh"
                version: "7.82.5"
                version_line: "curl.exe 7.82.5 Windows libcurl/7.82.5"
                auth_ref: "refresh"
            }
        ] {
            let supported_dir = ($fake_dir | path join $supported_case.name)
            mkdir $supported_dir
            let supported = (
                make-fake-curl $supported_dir $supported_case.version "supported-oauth"
                    --version-line $supported_case.version_line
            )
            let command = (
                "let result = (api get "
                + (($base + "/supported-" + $supported_case.name) | to nuon)
                + " -a {type: oauth2, ref: "
                + ($supported_case.auth_ref | to nuon)
                + "} --raw --no-history); "
                + "if $result.response.status != 200 { error make {msg: 'supported OAuth status was not parsed'} }; "
                + "if ($result.response.headers | get 'ETag') != '\"fake\"' { error make {msg: 'supported OAuth headers were not parsed'} }; "
                + "if $result.response.body != 'BODY' { error make {msg: 'supported OAuth body was not parsed'} }"
            )
            let accepted = (run-with-fake-curl $root $supported $command)
            assert equal $accepted.exit_code 0 $"compatible curl OAuth path failed: ($supported_case.name): ($accepted.stderr)"
            assert equal ($accepted.stderr | str trim) "" $"compatible curl OAuth path wrote stderr: ($supported_case.name)"
            assert equal (open $supported.log --raw | lines) ["version" "token" "request"] $"compatible curl OAuth path did not exercise preflight, token, and framed transfer: ($supported_case.name)"
        }
        assert equal (open $server.count_file --raw | str trim) "0" "controlled compatible wrappers unexpectedly reached the real token endpoint"
        assert equal (command-error-wire-events $server | length) 0 "controlled compatible wrappers unexpectedly reached a real protected endpoint"

        api auth oauth2 configure obtain --client-id obtain-client --client-secret obtain-secret --token-url $"($base)/token" | ignore
        api auth oauth2 configure refresh --client-id refresh-client --client-secret refresh-secret --token-url $"($base)/token" | ignore
        let reset_refresh = (
            open $secrets_path
            | update oauth.refresh.access_token "OLD-ACCESS-SENTINEL"
            | update oauth.refresh.refresh_token "OLD-REFRESH-SENTINEL"
            | update oauth.refresh.expires_at "2000-01-01T00:00:00Z"
        )
        $reset_refresh | to nuon --indent 4 | save -f $secrets_path
        let valid_obtain = (api request -m GET $"($base)/valid-obtain" -a {type: oauth2, ref: obtain} --raw --no-history)
        let valid_refresh = (api get $"($base)/valid-refresh" -a {type: oauth2, ref: refresh} --raw --no-history)
        assert equal $valid_obtain.response.status 200 "supported curl OAuth obtain counterpart failed"
        assert equal $valid_refresh.response.status 200 "supported curl OAuth refresh counterpart failed"
        assert equal (open $server.count_file --raw | str trim) "2" "supported curl did not execute obtain and refresh"
        assert equal (command-error-wire-events $server | length) 2 "supported curl did not reach both protected endpoints"
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    cleanup $root
    cleanup $infra
    cleanup $fake_dir
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def test-fileless-parallel-interruption-and-redirected-temp [] {
    let root = (make-temp-dir "fileless-header-parallel")
    let infra = (make-temp-dir "fileless-header-parallel-server")
    let clients = (make-temp-dir "fileless-header-clients")
    let redirected_temp = (make-temp-dir "fileless-header-redirected-temp")
    let server = (surface-server $infra)
    let baseline = (response-header-artifacts [$redirected_temp] | get name? | default [])
    mut clients_to_stop = []
    let failure = try {
        surface-workspace $root $server
        let url = $"http://127.0.0.1:($server.port)/acl-slow"
        let wire_before = (command-error-wire-events $server | length)

        let first = (start-secure-client $clients $root $"api get ($url | to nuon) --output none --no-history" "first" $redirected_temp)
        $clients_to_stop = ($clients_to_stop | append $first.pid)
        wait-for-wire-count $server ($wire_before + 1)
        assert (command-error-process-running $first.pid) "interrupt target exited before observation"
        assert-no-new-header-artifacts $baseline "active redirected-temp request" [$redirected_temp]

        let second = (start-secure-client $clients $root $"api get ($url | to nuon) --output none --no-history" "second" $redirected_temp)
        $clients_to_stop = ($clients_to_stop | append $second.pid)
        sleep 200ms
        assert ($first.pid != $second.pid) "parallel requests shared a client process"
        assert (command-error-process-running $second.pid) "parallel request exited before overlap"
        assert-no-new-header-artifacts $baseline "parallel active requests" [$redirected_temp]

        stop-secure-process-tree $first.pid $clients
        $clients_to_stop = ($clients_to_stop | where {|pid| $pid != $first.pid })
        assert-no-new-header-artifacts $baseline "controlled interruption" [$redirected_temp]

        wait-for-secure-process $second.pid false 400
        $clients_to_stop = ($clients_to_stop | where {|pid| $pid != $second.pid })
        assert equal (open $second.stderr --raw | str trim) "" "completed parallel request wrote diagnostics"
        assert-no-new-header-artifacts $baseline "parallel completion" [$redirected_temp]
        null
    } catch {|error| $error }

    for pid in $clients_to_stop {
        if (command-error-process-running $pid) {
            try { stop-secure-process-tree $pid $clients }
        }
    }
    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    assert-no-new-header-artifacts $baseline "parallel teardown" [$redirected_temp]
    cleanup $root
    cleanup $infra
    cleanup $clients
    cleanup $redirected_temp
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def test-fileless-windows-latency-regression [] {
    if $nu.os-info.name != "windows" {
        print "  [capability gated: Windows process-startup latency regression runs on Windows]"
        return
    }

    let root = (make-temp-dir "fileless-header-latency")
    let infra = (make-temp-dir "fileless-header-latency-server")
    let server = (surface-server $infra)
    let baseline = (response-header-artifacts | get name? | default [])
    let failure = try {
        surface-workspace $root $server
        let url = $"http://127.0.0.1:($server.port)/success"
        let retry_url = $"http://127.0.0.1:($server.port)/http-error"
        let null_device = "NUL"

        for _ in 1..2 {
            let direct_warmup = (curl --silent --output $null_device $url | complete)
            assert equal $direct_warmup.exit_code 0 "direct curl warm-up failed"
            api get $url --output none --no-history
        }

        let direct_samples = (measure-latency 7 {
            let result = (curl --silent --output $null_device $url | complete)
            assert equal $result.exit_code 0 "direct curl benchmark request failed"
        })
        let nurl_samples = (measure-latency 7 {
            api get $url --output none --no-history
        })
        let retry_started = (date now)
        api get $retry_url --output none --retries 2 --no-history
        let retry_ms = (((date now) - $retry_started) / 1ms)
        let direct = (summarize-latency $direct_samples)
        let nurl = (summarize-latency $nurl_samples)
        let added_median = ($nurl.median_ms - $direct.median_ms)

        assert ($added_median < 1500) $"fileless response metadata added too much median latency: ($added_median) ms"
        assert ($nurl.p95_ms < ($direct.p95_ms + 2000)) $"fileless response metadata added too much p95 latency: direct=($direct.p95_ms) ms, nurl=($nurl.p95_ms) ms"
        assert ($retry_ms < 5000) $"three-attempt local retry exceeded the regression ceiling: ($retry_ms) ms"
        assert-no-new-header-artifacts $baseline "latency benchmark"
        print $"  [latency proof: 2 warm-ups, 7 samples; direct median/p95=($direct.median_ms)/($direct.p95_ms) ms; Nurl median/p95=($nurl.median_ms)/($nurl.p95_ms) ms; three attempts=($retry_ms | math round --precision 2) ms]"
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    assert-no-new-header-artifacts $baseline "latency teardown"
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

export def run-suite-secure-header-capture [] {
    print "\n=== Fileless Response-Header Transport Tests ==="
    [
        (run-test "fileless headers preserve structured responses without secret/frame leaks" { test-fileless-header-correctness-and-secrecy })
        (run-test "repeated response headers preserve values while masking each field line" { test-repeated-header-folding-and-secrecy })
        (run-test "fileless failures, retries, capability checks, and malformed frames create no artifacts" { test-fileless-failure-retry-and-capability-contracts })
        (run-test "unsupported curl fails before OAuth, files, history, or network side effects" { test-unsupported-curl-precedes-oauth-and-state })
        (run-test "fileless parallel, interruption, and redirected-temp paths create no artifacts" { test-fileless-parallel-interruption-and-redirected-temp })
        (run-test "Windows local-request latency excludes cold PowerShell regressions" { test-fileless-windows-latency-regression })
    ]
}
