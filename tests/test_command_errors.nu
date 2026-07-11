# Public command error and OAuth2 stream-contract regressions.

def run-command-process [root: string, command: string] {
    let script_path = ($nu.temp-dir | path join $"nurl-command-error-(random uuid).nu")
    let module_path = ($env.NURL_REPO_ROOT | path join "nu_modules" "mod.nu")
    [
        $"use ($module_path | to nuon) *"
        $"$env.API_ROOT = ($root | to nuon)"
        $command
    ] | str join "\n" | save -f $script_path

    let result = (^$nu.current-exe --no-config-file $script_path | complete)
    rm -f $script_path
    $result
}

def command-error-entries [root: string] {
    if not ($root | path exists) {
        return []
    }

    ls -a $root | each {|entry|
        if $entry.type == "dir" {
            [$entry.name] | append (command-error-entries $entry.name)
        } else {
            [$entry.name]
        }
    } | flatten
}

def command-error-snapshot [root: string] {
    command-error-entries $root | each {|path|
        let path_type = ($path | path type)
        {
            path: ($path | path relative-to $root | str replace --all "\\" "/")
            type: $path_type
            content: (if $path_type == "file" { open $path --raw } else { null })
        }
    } | sort-by path
}

def assert-public-command-error [root: string, command: string, expected: string] {
    let before = (command-error-snapshot $root)
    let result = (run-command-process $root $command)
    let after = (command-error-snapshot $root)

    assert ($result.exit_code != 0) $"logical failure unexpectedly exited 0: ($command)"
    assert equal ($result.stdout | str trim) "" $"logical failure wrote stdout: ($command)"
    assert ($result.stderr | str contains $expected) $"stderr did not contain '($expected)': ($command)"
    assert equal $result.stderr ($result.stderr | ansi strip) "non-TTY stderr must not contain ANSI escapes"
    for forbidden in [" created" " deleted" " updated" " copied" "curl " "CLIENT-SECRET-SENTINEL" "ACCESS-TOKEN-SENTINEL"] {
        assert (not ($result.stderr | str contains $forbidden)) $"logical failure emitted forbidden text '($forbidden)': ($command)"
    }
    assert equal $after $before $"logical failure mutated the workspace: ($command)"
}

def command-error-process-running [pid: int] {
    try {
        (ps | where pid == $pid | length) > 0
    } catch {
        false
    }
}

def stop-command-error-server [server: record] {
    "" | save -f $server.stop_file
    for _ in 1..100 {
        if not (command-error-process-running $server.pid) {
            break
        }
        sleep 50ms
    }

    if (command-error-process-running $server.pid) {
        if $nu.os-info.name == "windows" {
            ^powershell.exe -NoProfile -NonInteractive -Command $"Stop-Process -Id ($server.pid) -Force" | ignore
        } else {
            ^kill -TERM $server.pid | ignore
        }
    }

    for _ in 1..40 {
        if not (command-error-process-running $server.pid) {
            break
        }
        sleep 50ms
    }
    assert (not (command-error-process-running $server.pid)) $"OAuth test server PID ($server.pid) did not stop"
}

def start-windows-oauth-server [tmp: string] {
    let server_script = ($tmp | path join "oauth-server.ps1")
    let launcher_script = ($tmp | path join "oauth-launcher.ps1")
    let port_file = ($tmp | path join "oauth-port.txt")
    let count_file = ($tmp | path join "oauth-count.txt")
    let stop_file = ($tmp | path join "oauth-stop.txt")

    let server_source = "param($PortFile, $CountFile, $StopFile)
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
[System.IO.File]::WriteAllText($PortFile, [string]$port)
[System.IO.File]::WriteAllText($CountFile, '0')
$clock = [System.Diagnostics.Stopwatch]::StartNew()
try {
    while (-not (Test-Path -LiteralPath $StopFile) -and $clock.Elapsed.TotalSeconds -lt 60) {
        if (-not $listener.Pending()) {
            Start-Sleep -Milliseconds 25
            continue
        }
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
            $requestLine = $reader.ReadLine()
            $contentLength = 0
            while (($line = $reader.ReadLine()) -ne '') {
                if ($line -match '(?i)^Content-Length:\\s*(\\d+)') {
                    $contentLength = [int]$Matches[1]
                }
            }
            $body = ''
            if ($contentLength -gt 0) {
                $buffer = New-Object char[] $contentLength
                $read = $reader.ReadBlock($buffer, 0, $contentLength)
                $body = -join $buffer[0..($read - 1)]
            }

            if ($requestLine -match ' /ready ') {
                $payload = 'ready'
                $contentType = 'text/plain'
            } else {
                $count = [int]([System.IO.File]::ReadAllText($CountFile)) + 1
                [System.IO.File]::WriteAllText($CountFile, [string]$count)
                if ($body -match 'grant_type=refresh_token') {
                    $response = @{
                        access_token = 'ACCESS-TOKEN-REFRESHED-SENTINEL'
                        refresh_token = 'REFRESH-TOKEN-REFRESHED-SENTINEL'
                        expires_in = 3600
                    }
                } else {
                    $response = @{
                        access_token = 'ACCESS-TOKEN-SENTINEL'
                        refresh_token = 'REFRESH-TOKEN-SENTINEL'
                        expires_in = 3600
                    }
                }
                $payload = $response | ConvertTo-Json -Compress
                $contentType = 'application/json'
            }

            $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
            $crlf = [Environment]::NewLine
            $header = 'HTTP/1.1 200 OK' + $crlf +
                'Content-Type: ' + $contentType + $crlf +
                'Content-Length: ' + $bytes.Length + $crlf +
                'Connection: close' + $crlf + $crlf
            $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
            $stream.Write($headerBytes, 0, $headerBytes.Length)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        } finally {
            $client.Dispose()
        }
    }
} finally {
    $listener.Stop()
}"
    let launcher_source = "param($ServerScript, $PortFile, $CountFile, $StopFile)
$arguments = @(
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    ('\"{0}\"' -f $ServerScript),
    ('\"{0}\"' -f $PortFile),
    ('\"{0}\"' -f $CountFile),
    ('\"{0}\"' -f $StopFile)
)
$process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -PassThru -WindowStyle Hidden
$process.Id"
    $server_source | save -f $server_script
    $launcher_source | save -f $launcher_script

    let launched = (^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcher_script $server_script $port_file $count_file $stop_file | complete)
    assert equal $launched.exit_code 0 $"OAuth server launcher failed: ($launched.stderr)"
    {
        pid: ($launched.stdout | str trim | into int)
        port: 0
        port_file: $port_file
        count_file: $count_file
        stop_file: $stop_file
    }
}

def start-posix-oauth-server [tmp: string] {
    let server_script = ($tmp | path join "oauth-server.py")
    let launcher_script = ($tmp | path join "oauth-launcher.py")
    let port_file = ($tmp | path join "oauth-port.txt")
    let count_file = ($tmp | path join "oauth-count.txt")
    let stop_file = ($tmp | path join "oauth-stop.txt")
    let python = if (which python3 | is-not-empty) {
        "python3"
    } else if (which python | is-not-empty) {
        "python"
    } else {
        error make {msg: "Python is required for the POSIX OAuth2 test endpoint"}
    }

    let server_source = "import http.server
import json
import os
import sys
import time

port_file, count_file, stop_file = sys.argv[1:4]
count = 0

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        self.wfile.write(b'ready')

    def do_POST(self):
        global count
        length = int(self.headers.get('Content-Length', '0'))
        body = self.rfile.read(length).decode('utf-8')
        count += 1
        with open(count_file, 'w', encoding='utf-8') as handle:
            handle.write(str(count))
        if 'grant_type=refresh_token' in body:
            payload = {
                'access_token': 'ACCESS-TOKEN-REFRESHED-SENTINEL',
                'refresh_token': 'REFRESH-TOKEN-REFRESHED-SENTINEL',
                'expires_in': 3600,
            }
        else:
            payload = {
                'access_token': 'ACCESS-TOKEN-SENTINEL',
                'refresh_token': 'REFRESH-TOKEN-SENTINEL',
                'expires_in': 3600,
            }
        encoded = json.dumps(payload).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
server.timeout = 0.1
with open(port_file, 'w', encoding='utf-8') as handle:
    handle.write(str(server.server_port))
with open(count_file, 'w', encoding='utf-8') as handle:
    handle.write('0')
deadline = time.time() + 60
while not os.path.exists(stop_file) and time.time() < deadline:
    server.handle_request()
server.server_close()
"
    let launcher_source = "import subprocess
import sys

process = subprocess.Popen(
    sys.argv[1:],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    start_new_session=True,
)
print(process.pid)
"
    $server_source | save -f $server_script
    $launcher_source | save -f $launcher_script

    let launched = (^$python $launcher_script $python $server_script $port_file $count_file $stop_file | complete)
    assert equal $launched.exit_code 0 $"OAuth server launcher failed: ($launched.stderr)"
    {
        pid: ($launched.stdout | str trim | into int)
        port: 0
        port_file: $port_file
        count_file: $count_file
        stop_file: $stop_file
    }
}

def start-command-error-server [tmp: string] {
    mut server = if $nu.os-info.name == "windows" {
        start-windows-oauth-server $tmp
    } else {
        start-posix-oauth-server $tmp
    }

    for _ in 1..100 {
        if ($server.port_file | path exists) and (command-error-process-running $server.pid) {
            break
        }
        sleep 50ms
    }
    if (not ($server.port_file | path exists)) or (not (command-error-process-running $server.pid)) {
        try { stop-command-error-server $server } catch {}
        error make {msg: "OAuth test server did not become ready"}
    }

    $server.port = (open $server.port_file --raw | str trim | into int)
    let ready = (^curl -s --max-time 2 $"http://127.0.0.1:($server.port)/ready" | complete)
    if $ready.exit_code != 0 or ($ready.stdout | str trim) != "ready" {
        try { stop-command-error-server $server } catch {}
        error make {msg: $"OAuth test server readiness check failed: ($ready.stderr)"}
    }
    $server
}

def setup-command-error-workspace [root: string, server: record] {
    $env.API_ROOT = $root
    api init | ignore
    api collection create jsonplaceholder | ignore
    api collection env create jsonplaceholder default | ignore
    api request create existing GET $"http://127.0.0.1:($server.port)/network-hit" --collection jsonplaceholder | ignore
    api chain create existing | ignore
    let history_id = (api history save {
        method: "GET"
        url: "https://example.invalid/success"
        headers: {}
        body: null
    } {
        status: 200
        status_text: "OK"
        headers: {}
        body: null
        time_ms: 1
        size_bytes: 0
    })

    api collection show jsonplaceholder | ignore
    assert equal (api collection env show jsonplaceholder default).environment "default"
    assert equal (api request show existing --collection jsonplaceholder).name "existing"
    assert equal (api chain show existing).name "existing"
    assert equal (api history show $history_id).id $history_id
}

def test-public-command-error-contracts [] {
    let root = (make-temp-dir "command-errors")
    let infra = (make-temp-dir "command-error-server")
    let server_result = try {
        {server: (start-command-error-server $infra), error: null}
    } catch {|error|
        {server: null, error: $error}
    }
    if $server_result.error != null {
        cleanup $root
        cleanup $infra
        error make {msg: $server_result.error.msg}
    }
    let server = $server_result.server
    let failure = try {
        setup-command-error-workspace $root $server
        let cases = [
            {command: "api collection create jsonplaceholder", expected: "Collection 'jsonplaceholder' already exists"}
            {command: "api collection show missing-valid-name", expected: "Collection 'missing-valid-name' not found"}
            {command: "api collection env create jsonplaceholder default", expected: "Environment 'default' already exists in collection 'jsonplaceholder'"}
            {command: "api send missing-valid-name --collection jsonplaceholder --raw --no-history", expected: "Request 'missing-valid-name' not found"}
            {command: "api chain show missing-valid-name", expected: "Chain 'missing-valid-name' not found"}
            {command: "api history show missing-valid-name", expected: "History entry 'missing-valid-name' not found"}
            {command: "api auth oauth2 token missing-valid-name", expected: "OAuth2 'missing-valid-name' not configured"}
            {command: "api collection delete missing-valid-name --force", expected: "Collection 'missing-valid-name' not found"}
            {command: "api collection copy missing-valid-name target", expected: "Source collection 'missing-valid-name' not found"}
            {command: "api collection copy jsonplaceholder jsonplaceholder", expected: "Target collection 'jsonplaceholder' already exists"}
            {command: "api collection env list missing-valid-name", expected: "Collection 'missing-valid-name' not found"}
            {command: "api collection env use jsonplaceholder missing-valid-name", expected: "Environment 'missing-valid-name' not found"}
            {command: "api collection env show jsonplaceholder missing-valid-name", expected: "Environment 'missing-valid-name' not found"}
            {command: "api collection env set jsonplaceholder key value --target missing-valid-name", expected: "Environment 'missing-valid-name' not found"}
            {command: "api collection env unset jsonplaceholder key --target missing-valid-name", expected: "Environment 'missing-valid-name' not found"}
            {command: "api collection env delete jsonplaceholder missing-valid-name --force", expected: "Environment 'missing-valid-name' not found"}
            {command: "api request show missing-valid-name --collection jsonplaceholder", expected: "Request 'missing-valid-name' not found"}
            {command: "api request update missing-valid-name --collection jsonplaceholder", expected: "Request 'missing-valid-name' not found"}
            {command: "api request delete missing-valid-name --collection jsonplaceholder --force", expected: "Request 'missing-valid-name' not found"}
            {command: "api chain create existing", expected: "Chain 'existing' already exists"}
            {command: "api chain delete missing-valid-name --force", expected: "Chain 'missing-valid-name' not found"}
            {command: "api chain exec missing-valid-name --quiet", expected: "Chain file not found: missing-valid-name"}
            {command: "api history resend missing-valid-name --raw", expected: "History entry 'missing-valid-name' not found"}
            {command: "api auth oauth2 refresh missing-valid-name", expected: "OAuth2 'missing-valid-name' not configured"}
            {command: "api auth oauth2 delete missing-valid-name", expected: "OAuth2 'missing-valid-name' not found"}
        ]

        for case in $cases {
            assert-public-command-error $root $case.command $case.expected
        }
        assert equal (open $server.count_file --raw | str trim) "0" "missing request/config failures must not reach the local endpoint"
        null
    } catch {|error|
        $error
    }

    let stop_failure = try {
        stop-command-error-server $server
        null
    } catch {|error|
        $error
    }
    cleanup $root
    cleanup $infra
    if $failure != null {
        error make {msg: $failure.msg}
    }
    if $stop_failure != null {
        error make {msg: $stop_failure.msg}
    }
}

def test-oauth2-success-streams-and-persistence [] {
    let root = (make-temp-dir "oauth-streams")
    let infra = (make-temp-dir "oauth-server")
    let server_result = try {
        {server: (start-command-error-server $infra), error: null}
    } catch {|error|
        {server: null, error: $error}
    }
    if $server_result.error != null {
        cleanup $root
        cleanup $infra
        error make {msg: $server_result.error.msg}
    }
    let server = $server_result.server
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        api auth oauth2 configure tmpoauth --client-id client-id --client-secret CLIENT-SECRET-SENTINEL --token-url $"http://127.0.0.1:($server.port)/token" | ignore

        let obtained = (run-command-process $root "api auth oauth2 token tmpoauth")
        assert equal $obtained.exit_code 0 "OAuth2 token obtain should exit 0"
        assert equal ($obtained.stderr | str trim) "" "OAuth2 token obtain must keep stderr empty"
        assert (($obtained.stdout | ansi strip) | str contains "OAuth2 token obtained") "OAuth2 token obtain should report safe success on stdout"
        for secret in ["ACCESS-TOKEN-SENTINEL" "REFRESH-TOKEN-SENTINEL" "CLIENT-SECRET-SENTINEL"] {
            assert (not ($obtained.stdout | str contains $secret)) $"OAuth2 token obtain leaked ($secret)"
        }

        let first_secrets = (open ($root | path join "secrets.nuon"))
        assert equal $first_secrets.oauth.tmpoauth.access_token "ACCESS-TOKEN-SENTINEL"
        assert equal $first_secrets.oauth.tmpoauth.refresh_token "REFRESH-TOKEN-SENTINEL"
        assert (($first_secrets.oauth.tmpoauth.expires_at? | default "") | is-not-empty) "OAuth2 expiry should be persisted"
        assert equal (open $server.count_file --raw | str trim) "1"

        let auth_config = (api auth get-config {type: oauth2, ref: tmpoauth})
        assert equal $auth_config.type "bearer"
        assert equal $auth_config.token "ACCESS-TOKEN-SENTINEL"
        assert equal (open $server.count_file --raw | str trim) "1" "valid cached token should not refresh"

        let refreshed = (run-command-process $root "api auth oauth2 refresh tmpoauth")
        assert equal $refreshed.exit_code 0 "OAuth2 refresh should exit 0"
        assert equal ($refreshed.stderr | str trim) "" "OAuth2 refresh must keep stderr empty"
        assert (($refreshed.stdout | ansi strip) | str contains "OAuth2 token refreshed") "OAuth2 refresh should report safe success on stdout"
        for secret in ["ACCESS-TOKEN-REFRESHED-SENTINEL" "REFRESH-TOKEN-REFRESHED-SENTINEL" "CLIENT-SECRET-SENTINEL"] {
            assert (not ($refreshed.stdout | str contains $secret)) $"OAuth2 refresh leaked ($secret)"
        }

        let refreshed_secrets = (open ($root | path join "secrets.nuon"))
        assert equal $refreshed_secrets.oauth.tmpoauth.access_token "ACCESS-TOKEN-REFRESHED-SENTINEL"
        assert equal $refreshed_secrets.oauth.tmpoauth.refresh_token "REFRESH-TOKEN-REFRESHED-SENTINEL"
        assert equal (open $server.count_file --raw | str trim) "2"
        null
    } catch {|error|
        $error
    }

    let stop_failure = try {
        stop-command-error-server $server
        null
    } catch {|error|
        $error
    }
    cleanup $root
    cleanup $infra
    if $failure != null {
        error make {msg: $failure.msg}
    }
    if $stop_failure != null {
        error make {msg: $stop_failure.msg}
    }
}

def run-suite-command-errors []: nothing -> list<record> {
    print $"\n(ansi yellow)── Public command error contracts ──(ansi reset)"
    [
        (run-test "logical duplicate/not-found failures use stderr and nonzero exit" { test-public-command-error-contracts })
        (run-test "OAuth2 obtain/refresh keep stderr clean and persist tokens safely" { test-oauth2-success-streams-and-persistence })
    ]
}
