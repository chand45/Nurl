# Public command error and OAuth2 stream-contract regressions.

def run-command-process [root: string, command: string] {
    let script_path = (test-temp-dir | path join $"nurl-command-error-(random uuid).nu")
    let config_path = (test-temp-dir | path join $"nurl-command-config-(random uuid).nu")
    let env_config_path = (test-temp-dir | path join $"nurl-command-env-(random uuid).nu")
    let module_path = ($env.NURL_REPO_ROOT | path join "nu_modules" "mod.nu")
    [
        $"use ($module_path | to nuon) *"
        $"$env.API_ROOT = ($root | to nuon)"
        "$env.NO_COLOR = '1'"
        $command
    ] | str join "\n" | save -f $script_path
    "$env.config.use_ansi_coloring = false" | save -f $config_path
    "# Isolated test environment." | save -f $env_config_path

    let result = (test-complete-result (do {
        ^$nu.current-exe --config $config_path --env-config $env_config_path $script_path
    } | complete))
    rm -f $script_path $config_path $env_config_path
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
    let wire_file = ($tmp | path join "oauth-wire.txt")
    let stop_file = ($tmp | path join "oauth-stop.txt")

    let server_source = "param($PortFile, $CountFile, $WireFile, $StopFile)
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
[System.IO.File]::WriteAllText($PortFile, [string]$port)
[System.IO.File]::WriteAllText($CountFile, '0')
[System.IO.File]::WriteAllText($WireFile, '')
$clock = [System.Diagnostics.Stopwatch]::StartNew()
try {
    while (-not (Test-Path -LiteralPath $StopFile) -and $clock.Elapsed.TotalSeconds -lt 180) {
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
            $authorization = ''
            $authorizationCount = 0
            $apiKey = ''
            $trace = ''
            $password = ''
            while (($line = $reader.ReadLine()) -ne '') {
                if ($line -match '(?i)^Content-Length:\\s*(\\d+)') {
                    $contentLength = [int]$Matches[1]
                }
                if ($line -match '(?i)^Authorization:\\s*(.*)$') {
                    $authorization = $Matches[1]
                    $authorizationCount++
                }
                if ($line -match '(?i)^(?:X-API-Key|X[.]Nurl[+]Key):\\s*(.*)$') {
                    $apiKey = $Matches[1]
                }
                if ($line -match '(?i)^X-Safe-Trace:\\s*(.*)$') {
                    $trace = $Matches[1]
                }
                if ($line -match '(?i)^(?:Password|Passwd|Pwd|X-Password|X-Passwd|X-Pwd):\\s*(.*)$') {
                    $password = $Matches[1]
                }
            }
            $body = ''
            if ($contentLength -gt 0) {
                $buffer = New-Object char[] $contentLength
                $read = $reader.ReadBlock($buffer, 0, $contentLength)
                $body = -join $buffer[0..($read - 1)]
            }

            $requestPath = ''
            if ($requestLine -match ' /ready ') {
                $payload = 'ready'
                $contentType = 'text/plain'
            } elseif ($requestLine -match ' /token(?:-[a-z0-9-]+)? ') {
                $requestPath = ($requestLine -split ' ')[1]
                $count = [int]([System.IO.File]::ReadAllText($CountFile)) + 1
                [System.IO.File]::WriteAllText($CountFile, [string]$count)
                $tokenStatus = 200
                if ($requestPath -eq '/token-error-initial') {
                    $tokenStatus = 400
                    $response = @{
                        error = 'invalid_client'
                        error_description = 'CLIENT-SECRET-ERROR-SENTINEL'
                    }
                } elseif ($requestPath -eq '/token-error-refresh') {
                    $tokenStatus = 400
                    $response = @{
                        error = 'invalid_grant'
                        error_description = 'CLIENT-SECRET-REFRESH-ERROR-SENTINEL ACCESS-TOKEN-ERROR-SENTINEL REFRESH-TOKEN-ERROR-SENTINEL'
                    }
                } elseif ($requestPath -in @('/token-status-302', '/token-status-400', '/token-status-500')) {
                    $tokenStatus = [int](($requestPath -split '-')[-1])
                    $response = @{
                        access_token = 'FAILED-ACCESS-SENTINEL'
                        refresh_token = 'FAILED-REFRESH-SENTINEL'
                        expires_in = 3600
                    }
                } elseif ($requestPath -eq '/token-description-only') {
                    $tokenStatus = 400
                    $response = @{
                        error_description = 'DESCRIPTION-ONLY-SENTINEL'
                    }
                } elseif ($requestPath -eq '/token-unsafe-code') {
                    $tokenStatus = 400
                    $response = @{
                        error = 'UNSAFE-ERROR-CODE-SENTINEL'
                    }
                } elseif ($requestPath -eq '/token-malformed-json') {
                    $payload = '{\"access_token\":\"MALFORMED-OAUTH-SENTINEL\"'
                    $response = $null
                } elseif ($requestPath -eq '/token-non-record') {
                    $payload = '[\"NONRECORD-OAUTH-SENTINEL\"]'
                    $response = $null
                } elseif ($requestPath -eq '/token-missing-access') {
                    $response = @{
                        refresh_token = 'MISSING-ACCESS-REFRESH-SENTINEL'
                        expires_in = 3600
                    }
                } elseif ($requestPath -eq '/token-empty-access') {
                    $response = @{
                        access_token = ''
                        refresh_token = 'EMPTY-ACCESS-REFRESH-SENTINEL'
                        expires_in = 3600
                    }
                } elseif ($requestPath -eq '/token-nonstring-access') {
                    $response = @{
                        access_token = @('NONSTRING-ACCESS-SENTINEL')
                        expires_in = 3600
                    }
                } elseif ($requestPath -eq '/token-invalid-refresh') {
                    $response = @{
                        access_token = 'INVALID-REFRESH-ACCESS-SENTINEL'
                        refresh_token = 42
                        expires_in = 3600
                    }
                } elseif ($requestPath -eq '/token-invalid-type') {
                    $response = @{
                        access_token = 'INVALID-TYPE-ACCESS-SENTINEL'
                        token_type = @('Bearer')
                        expires_in = 3600
                    }
                } elseif ($requestPath -eq '/token-unsupported-type') {
                    $response = @{
                        access_token = 'UNSUPPORTED-TYPE-ACCESS-SENTINEL'
                        token_type = 'mac'
                        expires_in = 3600
                    }
                } elseif ($requestPath -eq '/token-invalid-expiry') {
                    $response = @{
                        access_token = 'INVALID-EXPIRY-ACCESS-SENTINEL'
                        expires_in = 0
                    }
                } elseif ($requestPath -eq '/token-invalid-expiry-type') {
                    $response = @{
                        access_token = 'INVALID-EXPIRY-TYPE-ACCESS-SENTINEL'
                        expires_in = '3600'
                    }
                } elseif ($requestPath -eq '/token-invalid-expiry-high') {
                    $response = @{
                        access_token = 'INVALID-EXPIRY-HIGH-ACCESS-SENTINEL'
                        expires_in = 315360001
                    }
                } elseif ($requestPath -eq '/token-valid-shaped') {
                    $response = @{
                        access_token = 'VALID-SHAPED-ACCESS'
                        refresh_token = 'VALID-SHAPED-REFRESH'
                        token_type = 'Bearer'
                        expires_in = 1800
                    }
                } elseif ($body -match 'grant_type=refresh_token') {
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
                if ($null -ne $response) {
                    $payload = $response | ConvertTo-Json -Compress
                }
                $contentType = 'application/json'
            } else {
                $requestPath = ($requestLine -split ' ')[1]
                [System.IO.File]::AppendAllText($WireFile, $requestPath + \"`t\" + $authorization + \"`t\" + $apiKey + \"`t\" + $trace + \"`t\" + $password + \"`t\" + $authorizationCount + [Environment]::NewLine)
                if ($requestPath -eq '/slow') {
                    Start-Sleep -Seconds 3
                }
                if ($requestPath -eq '/timeout') {
                    Start-Sleep -Seconds 3
                }
                if ($requestPath -eq '/acl-slow') {
                    Start-Sleep -Seconds 8
                }
                switch ($requestPath) {
                    '/array' {
                        $payload = '[{\"id\":1}]'
                        $contentType = 'application/json'
                    }
                    '/text' {
                        $payload = 'plain-text-response'
                        $contentType = 'text/plain'
                    }
                    '/padded' {
                        $payload = '  padded text  '
                        $contentType = 'text/plain'
                    }
                    '/sentinel' {
                        $payload = 'prefix---RESPONSE_META---suffix'
                        $contentType = 'text/plain'
                    }
                    '/http-like-text' {
                        $payload = \"prefix`r`n`r`nHTTP/1.1 200 OK`r`n`r`nsuffix\"
                        $contentType = 'text/plain'
                    }
                    '/json-string' {
                        $payload = '\"json-string-response\"'
                        $contentType = 'application/json'
                    }
                    '/json-null' {
                        $payload = 'null'
                        $contentType = 'application/json'
                    }
                    '/empty' {
                        $payload = ''
                        $contentType = 'text/plain'
                    }
                    default {
                        $payload = '{\"ok\":true}'
                        $contentType = 'application/json'
                    }
                }
            }

            $bytes = if ($requestPath -eq '/binary-body') {
                [byte[]](0, 255, 1, 128, 65, 66)
            } else {
                [System.Text.Encoding]::UTF8.GetBytes($payload)
            }
            $crlf = \"`r`n\"
            $statusLine = if ($requestPath -like '/token*') { 'HTTP/1.1 ' + $tokenStatus + ' OAuth Response' } elseif ($requestPath -eq '/http-error') { 'HTTP/1.1 503 Service Unavailable' } elseif ($requestPath -eq '/redirect') { 'HTTP/1.1 302 Found' } elseif ($requestPath -eq '/empty-headers') { 'HTTP/1.1 204 No Content' } else { 'HTTP/1.1 200 OK' }
            $extraHeaders = if ($requestPath -eq '/sensitive-headers') {
                'Set-Cookie: session=RESPONSE-COOKIE-SENTINEL; HttpOnly' + $crlf +
                'X-Session-Token: RESPONSE-TOKEN-SENTINEL' + $crlf +
                'X-Debug-Auth: Bearer RESPONSE-BEARER-SENTINEL' + $crlf
            } elseif ($requestPath -eq '/password-response-headers') {
                'Password: RESPONSE-PASSWORD-SENTINEL' + $crlf +
                'Passwd: RESPONSE-PASSWD-SENTINEL' + $crlf +
                'Pwd: RESPONSE-PWD-SENTINEL' + $crlf +
                'X-Password: RESPONSE-X-PASSWORD-SENTINEL' + $crlf +
                'X-Passwd: RESPONSE-X-PASSWD-SENTINEL' + $crlf +
                'X-Pwd: RESPONSE-X-PWD-SENTINEL' + $crlf +
                'Password-Hint: safe-password-hint' + $crlf +
                'X-Pwd-Reset-Status: safe-pwd-reset' + $crlf +
                'Bypass-Word: safe-bypass-word' + $crlf +
                'X-Control-Header: exact-control-value' + $crlf
            } elseif ($requestPath -eq '/duplicate-headers') {
                'X-Duplicate: first' + $crlf +
                'X-Duplicate: second' + $crlf +
                'X-Mixed-Dupe: first' + $crlf +
                'x-mIxEd-DuPe: second' + $crlf +
                'X.Trace+ID: first' + $crlf +
                'XxTraceeID: distinct' + $crlf +
                'x.tRACE+id: second' + $crlf +
                'X-Marker-Like: NURL_RESPONSE_META_static_BEGIN' + $crlf
            } elseif ($requestPath -eq '/redirect') {
                'Location: /sensitive-headers' + $crlf
            } elseif ($requestPath -eq '/early-hints') {
                'X-Final: final-value' + $crlf
            } elseif ($requestPath -eq '/case-headers') {
                'ETag: \"case-etag\"' + $crlf +
                'WWW-Authenticate: Bearer realm=\"nurl\"' + $crlf +
                'X-RateLimit-Remaining: 42' + $crlf +
                'x-CuStOm-AcRoNyM: mixed-value' + $crlf +
                'X-Empty-Value:' + $crlf
            } else { '' }
            if ($requestPath -eq '/early-hints') {
                $early = [System.Text.Encoding]::ASCII.GetBytes(
                    'HTTP/1.1 103 Early Hints' + $crlf +
                    'Link: </style.css>; rel=preload' + $crlf + $crlf
                )
                $stream.Write($early, 0, $early.Length)
                $stream.Flush()
            }
            if ($requestPath -eq '/trailers') {
                $trailerHeader = [System.Text.Encoding]::ASCII.GetBytes(
                    $statusLine + $crlf +
                    'Content-Type: text/plain' + $crlf +
                    'Transfer-Encoding: chunked' + $crlf +
                    'Trailer: x-TrAiLeR-CaSe, Set-Cookie' + $crlf + $crlf
                )
                $chunked = [System.Text.Encoding]::ASCII.GetBytes(
                    '4' + $crlf + 'BODY' + $crlf + '0' + $crlf +
                    'X-Mixed-Trailer: first' + $crlf +
                    'x-MiXeD-TrAiLeR: second' + $crlf +
                    'x-TrAiLeR-CaSe: trailer-value' + $crlf +
                    'Set-Cookie: trailer-secret-sentinel' + $crlf + $crlf
                )
                $stream.Write($trailerHeader, 0, $trailerHeader.Length)
                $stream.Write($chunked, 0, $chunked.Length)
                $stream.Flush()
                continue
            }
            $header = if ($requestPath -eq '/empty-headers') {
                $statusLine + $crlf + $crlf
            } else {
                $statusLine + $crlf +
                    'Content-Type: ' + $contentType + $crlf +
                    $extraHeaders +
                    'Content-Length: ' + $bytes.Length + $crlf +
                    'Connection: close' + $crlf + $crlf
            }
            $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
            if ($requestPath -eq '/malformed-header') {
                $headerBytes = [System.Text.Encoding]::ASCII.GetBytes(
                    'HTTP/1.1 200 OK' + $crlf + 'X-Malformed: '
                ) + [byte[]](255) + [System.Text.Encoding]::ASCII.GetBytes(
                    $crlf + 'Content-Type: application/json' + $crlf +
                    'Content-Length: ' + $bytes.Length + $crlf + 'Connection: close' + $crlf + $crlf
                )
            }
            $stream.Write($headerBytes, 0, $headerBytes.Length)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        } catch {
            # Clients intentionally disconnect in timeout/interruption regressions.
        } finally {
            $client.Dispose()
        }
    }
} finally {
    $listener.Stop()
}"
    let launcher_source = "param($ServerScript, $PortFile, $CountFile, $WireFile, $StopFile)
$arguments = @(
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    ('\"{0}\"' -f $ServerScript),
    ('\"{0}\"' -f $PortFile),
    ('\"{0}\"' -f $CountFile),
    ('\"{0}\"' -f $WireFile),
    ('\"{0}\"' -f $StopFile)
)
$process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -PassThru -WindowStyle Hidden
$process.Id"
    $server_source | save -f $server_script
    $launcher_source | save -f $launcher_script

    let launched = (test-complete-result (do { ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcher_script $server_script $port_file $count_file $wire_file $stop_file } | complete))
    assert equal $launched.exit_code 0 $"OAuth server launcher failed: ($launched.stderr)"
    {
        pid: ($launched.stdout | str trim | into int)
        port: 0
        port_file: $port_file
        count_file: $count_file
        wire_file: $wire_file
        stop_file: $stop_file
    }
}

def start-posix-oauth-server [tmp: string] {
    let server_script = ($tmp | path join "oauth-server.py")
    let launcher_script = ($tmp | path join "oauth-launcher.py")
    let port_file = ($tmp | path join "oauth-port.txt")
    let count_file = ($tmp | path join "oauth-count.txt")
    let wire_file = ($tmp | path join "oauth-wire.txt")
    let stop_file = ($tmp | path join "oauth-stop.txt")
    let python = if not (which python3 | is-empty) {
        "python3"
    } else if not (which python | is-empty) {
        "python"
    } else {
        error make {msg: "Python is required for the POSIX OAuth2 test endpoint"}
    }

    let server_source = "import http.server
import json
import os
import sys
import time

port_file, count_file, wire_file, stop_file = sys.argv[1:5]
count = 0

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        if self.path == '/ready':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'ready')
        else:
            self.send_protected()

    def do_POST(self):
        if self.path != '/token' and not self.path.startswith('/token-'):
            self.send_protected()
            return
        global count
        length = int(self.headers.get('Content-Length', '0'))
        body = self.rfile.read(length).decode('utf-8')
        count += 1
        with open(count_file, 'w', encoding='utf-8') as handle:
            handle.write(str(count))
        status = 200
        raw_payload = None
        if self.path == '/token-error-initial':
            status = 400
            payload = {
                'error': 'invalid_client',
                'error_description': 'CLIENT-SECRET-ERROR-SENTINEL',
            }
        elif self.path == '/token-error-refresh':
            status = 400
            payload = {
                'error': 'invalid_grant',
                'error_description': 'CLIENT-SECRET-REFRESH-ERROR-SENTINEL ACCESS-TOKEN-ERROR-SENTINEL REFRESH-TOKEN-ERROR-SENTINEL',
            }
        elif self.path in ('/token-status-302', '/token-status-400', '/token-status-500'):
            status = int(self.path.rsplit('-', 1)[1])
            payload = {
                'access_token': 'FAILED-ACCESS-SENTINEL',
                'refresh_token': 'FAILED-REFRESH-SENTINEL',
                'expires_in': 3600,
            }
        elif self.path == '/token-description-only':
            status = 400
            payload = {'error_description': 'DESCRIPTION-ONLY-SENTINEL'}
        elif self.path == '/token-unsafe-code':
            status = 400
            payload = {'error': 'UNSAFE-ERROR-CODE-SENTINEL'}
        elif self.path == '/token-malformed-json':
            payload = None
            raw_payload = b'{\"access_token\":\"MALFORMED-OAUTH-SENTINEL\"'
        elif self.path == '/token-non-record':
            payload = None
            raw_payload = b'[\"NONRECORD-OAUTH-SENTINEL\"]'
        elif self.path == '/token-missing-access':
            payload = {
                'refresh_token': 'MISSING-ACCESS-REFRESH-SENTINEL',
                'expires_in': 3600,
            }
        elif self.path == '/token-empty-access':
            payload = {
                'access_token': '',
                'refresh_token': 'EMPTY-ACCESS-REFRESH-SENTINEL',
                'expires_in': 3600,
            }
        elif self.path == '/token-nonstring-access':
            payload = {
                'access_token': ['NONSTRING-ACCESS-SENTINEL'],
                'expires_in': 3600,
            }
        elif self.path == '/token-invalid-refresh':
            payload = {
                'access_token': 'INVALID-REFRESH-ACCESS-SENTINEL',
                'refresh_token': 42,
                'expires_in': 3600,
            }
        elif self.path == '/token-invalid-type':
            payload = {
                'access_token': 'INVALID-TYPE-ACCESS-SENTINEL',
                'token_type': ['Bearer'],
                'expires_in': 3600,
            }
        elif self.path == '/token-unsupported-type':
            payload = {
                'access_token': 'UNSUPPORTED-TYPE-ACCESS-SENTINEL',
                'token_type': 'mac',
                'expires_in': 3600,
            }
        elif self.path == '/token-invalid-expiry':
            payload = {
                'access_token': 'INVALID-EXPIRY-ACCESS-SENTINEL',
                'expires_in': 0,
            }
        elif self.path == '/token-invalid-expiry-type':
            payload = {
                'access_token': 'INVALID-EXPIRY-TYPE-ACCESS-SENTINEL',
                'expires_in': '3600',
            }
        elif self.path == '/token-invalid-expiry-high':
            payload = {
                'access_token': 'INVALID-EXPIRY-HIGH-ACCESS-SENTINEL',
                'expires_in': 315360001,
            }
        elif self.path == '/token-valid-shaped':
            payload = {
                'access_token': 'VALID-SHAPED-ACCESS',
                'refresh_token': 'VALID-SHAPED-REFRESH',
                'token_type': 'Bearer',
                'expires_in': 1800,
            }
        elif 'grant_type=refresh_token' in body:
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
        encoded = raw_payload if raw_payload is not None else json.dumps(payload).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_PUT(self):
        self.send_protected()

    def send_protected(self):
        authorizations = self.headers.get_all('Authorization', [])
        authorization = authorizations[-1] if authorizations else ''
        api_key = self.headers.get('X.Nurl+Key', self.headers.get('X-API-Key', ''))
        trace = self.headers.get('X-Safe-Trace', '')
        password = ''
        for name in ('Password', 'Passwd', 'Pwd', 'X-Password', 'X-Passwd', 'X-Pwd'):
            if self.headers.get(name) is not None:
                password = self.headers.get(name, '')
                break
        with open(wire_file, 'a', encoding='utf-8') as handle:
            handle.write(self.path + '\\t' + authorization + '\\t' + api_key + '\\t' + trace + '\\t' + password + '\\t' + str(len(authorizations)) + '\\n')
        if self.path in ('/slow', '/timeout'):
            time.sleep(3)
        if self.path == '/acl-slow':
            time.sleep(8)
        if self.path == '/array':
            encoded = b'[{\"id\":1}]'
            content_type = 'application/json'
        elif self.path == '/text':
            encoded = b'plain-text-response'
            content_type = 'text/plain'
        elif self.path == '/padded':
            encoded = b'  padded text  '
            content_type = 'text/plain'
        elif self.path == '/sentinel':
            encoded = b'prefix---RESPONSE_META---suffix'
            content_type = 'text/plain'
        elif self.path == '/http-like-text':
            encoded = b'prefix\\r\\n\\r\\nHTTP/1.1 200 OK\\r\\n\\r\\nsuffix'
            content_type = 'text/plain'
        elif self.path == '/json-string':
            encoded = b'\"json-string-response\"'
            content_type = 'application/json'
        elif self.path == '/json-null':
            encoded = b'null'
            content_type = 'application/json'
        elif self.path == '/empty':
            encoded = b''
            content_type = 'text/plain'
        elif self.path == '/binary-body':
            encoded = bytes([0, 255, 1, 128, 65, 66])
            content_type = 'application/octet-stream'
        else:
            encoded = b'{\"ok\":true}'
            content_type = 'application/json'
        if self.path == '/malformed-header':
            self.connection.sendall(
                b'HTTP/1.1 200 OK\\r\\nX-Malformed: \\xff\\r\\n'
                b'Content-Type: application/json\\r\\n'
                + ('Content-Length: ' + str(len(encoded)) + '\\r\\n').encode('ascii')
                + b'Connection: close\\r\\n\\r\\n'
                + encoded
            )
            return
        if self.path == '/trailers':
            self.connection.sendall(
                b'HTTP/1.1 200 OK\\r\\n'
                b'Content-Type: text/plain\\r\\n'
                b'Transfer-Encoding: chunked\\r\\n'
                b'Trailer: x-TrAiLeR-CaSe, Set-Cookie\\r\\n\\r\\n'
                b'4\\r\\nBODY\\r\\n0\\r\\n'
                b'X-Mixed-Trailer: first\\r\\n'
                b'x-MiXeD-TrAiLeR: second\\r\\n'
                b'x-TrAiLeR-CaSe: trailer-value\\r\\n'
                b'Set-Cookie: trailer-secret-sentinel\\r\\n\\r\\n'
            )
            return
        if self.path == '/early-hints':
            self.connection.sendall(
                b'HTTP/1.1 103 Early Hints\\r\\n'
                b'Link: </style.css>; rel=preload\\r\\n\\r\\n'
            )
        if self.path == '/empty-headers':
            self.connection.sendall(b'HTTP/1.1 204 No Content\\r\\n\\r\\n')
            return
        status = 503 if self.path == '/http-error' else (302 if self.path == '/redirect' else 200)
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        if self.path == '/duplicate-headers':
            self.send_header('X-Duplicate', 'first')
            self.send_header('X-Duplicate', 'second')
            self.send_header('X-Mixed-Dupe', 'first')
            self.send_header('x-mIxEd-DuPe', 'second')
            self.send_header('X.Trace+ID', 'first')
            self.send_header('XxTraceeID', 'distinct')
            self.send_header('x.tRACE+id', 'second')
            self.send_header('X-Marker-Like', 'NURL_RESPONSE_META_static_BEGIN')
        elif self.path == '/redirect':
            self.send_header('Location', '/sensitive-headers')
        elif self.path == '/early-hints':
            self.send_header('X-Final', 'final-value')
        elif self.path == '/case-headers':
            self.send_header('ETag', '\"case-etag\"')
            self.send_header('WWW-Authenticate', 'Bearer realm=\"nurl\"')
            self.send_header('X-RateLimit-Remaining', '42')
            self.send_header('x-CuStOm-AcRoNyM', 'mixed-value')
            self.send_header('X-Empty-Value', '')
        if self.path == '/sensitive-headers':
            self.send_header('Set-Cookie', 'session=RESPONSE-COOKIE-SENTINEL; HttpOnly')
            self.send_header('X-Session-Token', 'RESPONSE-TOKEN-SENTINEL')
            self.send_header('X-Debug-Auth', 'Bearer RESPONSE-BEARER-SENTINEL')
        if self.path == '/password-response-headers':
            self.send_header('Password', 'RESPONSE-PASSWORD-SENTINEL')
            self.send_header('Passwd', 'RESPONSE-PASSWD-SENTINEL')
            self.send_header('Pwd', 'RESPONSE-PWD-SENTINEL')
            self.send_header('X-Password', 'RESPONSE-X-PASSWORD-SENTINEL')
            self.send_header('X-Passwd', 'RESPONSE-X-PASSWD-SENTINEL')
            self.send_header('X-Pwd', 'RESPONSE-X-PWD-SENTINEL')
            self.send_header('Password-Hint', 'safe-password-hint')
            self.send_header('X-Pwd-Reset-Status', 'safe-pwd-reset')
            self.send_header('Bypass-Word', 'safe-bypass-word')
            self.send_header('X-Control-Header', 'exact-control-value')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
server.timeout = 0.1
with open(port_file, 'w', encoding='utf-8') as handle:
    handle.write(str(server.server_port))
with open(count_file, 'w', encoding='utf-8') as handle:
    handle.write('0')
with open(wire_file, 'w', encoding='utf-8') as handle:
    handle.write('')
deadline = time.time() + 180
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

    let launched = (test-complete-result (do { ^$python $launcher_script $python $server_script $port_file $count_file $wire_file $stop_file } | complete))
    assert equal $launched.exit_code 0 $"OAuth server launcher failed: ($launched.stderr)"
    {
        pid: ($launched.stdout | str trim | into int)
        port: 0
        port_file: $port_file
        count_file: $count_file
        wire_file: $wire_file
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
    let ready_url = $"http://127.0.0.1:($server.port)/ready"
    mut ready_ok = false
    mut ready_stderr = ""
    for _ in 1..40 {
        let ready = (test-complete-result (do { ^curl -s --max-time 2 $ready_url } | complete))
        $ready_stderr = $ready.stderr
        if $ready.exit_code == 0 and ($ready.stdout | str trim) == "ready" {
            $ready_ok = true
            break
        }
        sleep 50ms
    }
    if not $ready_ok {
        try { stop-command-error-server $server } catch {}
        error make {msg: $"OAuth test server readiness check failed: ($ready_stderr)"}
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

def command-error-wire-events [server: record] {
    if not ($server.wire_file | path exists) {
        return []
    }
    open $server.wire_file --raw
    | lines
    | where {|line| not ($line | is-empty) }
    | parse --regex '^(?<path>[^\t]+)\t(?<authorization>[^\t]*)\t(?<api_key>[^\t]*)\t(?<trace>[^\t]*)\t(?<password>[^\t]*)\t(?<authorization_count>\d+)$'
}

def assert-no-auth-leak [result: record, secrets: list<string>, label: string] {
    assert equal ($result.stderr | str trim) "" $"($label) wrote unexpected stderr"
    let combined = $"($result.stdout)\n($result.stderr)"
    for secret in $secrets {
        assert (not ($combined | str contains $secret)) $"($label) exposed an authentication value"
    }
}

def test-authentication-wire-and-redaction [] {
    let root = (make-temp-dir "auth-wire")
    let infra = (make-temp-dir "auth-wire-server")
    let binary_path = ($root | path join "wire-download.bin")
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
        let base_url = $"http://127.0.0.1:($server.port)"
        let bearer_token = $"wire-(random uuid)"
        let prefixed_token = $"prefixed-(random uuid)"
        let client_secret = $"client-(random uuid)"
        let basic_password = $"basic-(random uuid)"
        api auth bearer set wire-bearer $bearer_token | ignore
        api auth bearer set wire-prefixed $"Bearer ($prefixed_token)" | ignore
        api auth basic set wire-basic wire-user $basic_password | ignore
        api collection create wire | ignore
        api request create wire-saved GET $"($base_url)/saved" --collection wire --auth {type: bearer, token_ref: wire-bearer} | ignore
        api request create wire-chain-request GET $"($base_url)/chain-named" --collection wire --auth {type: bearer, token_ref: wire-bearer} | ignore
        api chain create wire-chain | ignore
        {
            name: "wire-chain"
            description: ""
            steps: [{request: "wire-chain-request"}]
        } | to nuon --indent 4 | save -f ($root | path join "chains" "wire-chain.nuon")
        api auth oauth2 configure wire-oauth --client-id wire-client --client-secret $client_secret --token-url $"($base_url)/token" | ignore

        mut secrets = [$bearer_token $prefixed_token $client_secret $basic_password]
        let direct = (run-command-process $root $"api request -m GET (($base_url + '/direct') | to nuon) -a {type: bearer, token_ref: wire-bearer} --raw --no-history")
        assert equal $direct.exit_code 0 "direct authenticated request failed"
        assert-no-auth-leak $direct $secrets "direct authenticated request"

        let prefixed = (run-command-process $root $"api request -m GET (($base_url + '/prefixed') | to nuon) -a {type: bearer, token_ref: wire-prefixed} --raw --no-history")
        assert equal $prefixed.exit_code 0 "prefixed bearer request failed"
        assert-no-auth-leak $prefixed $secrets "prefixed bearer request"

        let basic = (run-command-process $root $"api request -m GET (($base_url + '/basic') | to nuon) -a {type: basic, creds_ref: wire-basic} --raw --no-history")
        assert equal $basic.exit_code 0 "basic-auth regression request failed"
        assert-no-auth-leak $basic $secrets "basic-auth regression request"

        let debugged = (run-command-process $root $"api request -m GET (($base_url + '/debug') | to nuon) -a {type: bearer, token_ref: wire-bearer} --debug --raw --no-history")
        assert equal $debugged.exit_code 0 "debug authenticated request failed"
        assert-no-auth-leak $debugged $secrets "debug diagnostics"

        let output_cases = [
            {label: "default", options: ""}
            {label: "raw flag", options: "--raw"}
            {label: "pretty output", options: "--output pretty"}
            {label: "body output", options: "--output body"}
            {label: "raw output", options: "--output raw"}
            {label: "json output", options: "--output json"}
            {label: "headers output", options: "--output headers"}
            {label: "status output", options: "--output status"}
            {label: "none output", options: "--output none"}
            {label: "selected output", options: "--select response.status"}
        ]
        for case in $output_cases {
            let sent = (run-command-process $root $"api send wire-saved --collection wire --no-history ($case.options)")
            assert equal $sent.exit_code 0 $"saved request ($case.label) failed"
            assert-no-auth-leak $sent $secrets $"saved request ($case.label)"
        }

        let wire_before_display = (command-error-wire-events $server | length)
        let dry_run = (run-command-process $root "api send wire-saved --collection wire --dry-run --no-history")
        assert equal $dry_run.exit_code 0 "saved request dry-run failed"
        assert-no-auth-leak $dry_run $secrets "saved request dry-run"
        assert (($dry_run.stdout | ansi strip) | str contains "Authorization: ******") "dry-run must display a redacted Authorization header"
        assert equal (command-error-wire-events $server | length) $wire_before_display "dry-run must not reach the protected endpoint"

        let exported = (run-command-process $root "api request export wire-saved --collection wire")
        assert equal $exported.exit_code 0 "request export failed"
        assert-no-auth-leak $exported $secrets "request export"
        assert (($exported.stdout | ansi strip) | str contains "Authorization: ******") "request export must display a redacted Authorization header"
        assert equal (command-error-wire-events $server | length) $wire_before_display "request export must not reach the protected endpoint"

        let inline_steps = ([{
            method: "GET"
            url: $"($base_url)/chain-inline"
            auth: {type: bearer, token_ref: wire-bearer}
        }] | to nuon)
        let inline_chain = (run-command-process $root $"api chain run ($inline_steps) --collection wire")
        assert equal $inline_chain.exit_code 0 "inline authenticated chain failed"
        assert-no-auth-leak $inline_chain $secrets "inline chain output"

        let named_chain = (run-command-process $root "api chain exec wire-chain")
        assert equal $named_chain.exit_code 0 "named authenticated chain failed"
        assert-no-auth-leak $named_chain $secrets "named chain output"

        let binary = (run-command-process $root $"api get (($base_url + '/binary') | to nuon) -a {type: bearer, token_ref: wire-bearer} --binary-save ($binary_path | to nuon) --raw --no-history")
        assert equal $binary.exit_code 0 "binary authenticated request failed"
        assert-no-auth-leak $binary $secrets "binary request output"
        assert ($binary_path | path exists) "binary request did not write its explicit output path"
        assert ((open $binary_path --raw) | str contains '"ok":true') "binary response body was not written"

        let oauth_obtain = (run-command-process $root $"api request -m GET (($base_url + '/oauth-obtain') | to nuon) -a {type: oauth2, ref: wire-oauth} --raw --no-history")
        assert equal $oauth_obtain.exit_code 0 "internally obtained OAuth2 request failed"
        let first_oauth = (open ($root | path join "secrets.nuon"))
        let first_access = $first_oauth.oauth.wire-oauth.access_token
        let first_refresh = $first_oauth.oauth.wire-oauth.refresh_token
        $secrets = ($secrets | append [$first_access $first_refresh])
        assert-no-auth-leak $oauth_obtain $secrets "internally obtained OAuth2 request"

        let oauth_refresh = (run-command-process $root "api auth oauth2 refresh wire-oauth")
        assert equal $oauth_refresh.exit_code 0 "OAuth2 refresh failed"
        let refreshed_oauth = (open ($root | path join "secrets.nuon"))
        let refreshed_access = $refreshed_oauth.oauth.wire-oauth.access_token
        let refreshed_refresh = $refreshed_oauth.oauth.wire-oauth.refresh_token
        $secrets = ($secrets | append [$refreshed_access $refreshed_refresh])
        assert-no-auth-leak $oauth_refresh $secrets "OAuth2 refresh output"

        let oauth_refreshed_request = (run-command-process $root $"api request -m GET (($base_url + '/oauth-refresh') | to nuon) -a {type: oauth2, ref: wire-oauth} --raw --no-history")
        assert equal $oauth_refreshed_request.exit_code 0 "refreshed OAuth2 request failed"
        assert-no-auth-leak $oauth_refreshed_request $secrets "refreshed OAuth2 request"
        assert equal (open $server.count_file --raw | str trim) "2" "OAuth2 obtain and refresh must each call the token endpoint once"

        let before_malformed = (command-error-wire-events $server | length)
        let malformed = (run-command-process $root $"api request -m GET (($base_url + '/malformed') | to nuon) -a {type: bearer} --raw --no-history")
        assert ($malformed.exit_code != 0) "missing bearer token must fail"
        assert equal ($malformed.stdout | str trim) "" "missing bearer token must keep stdout empty"
        assert (($malformed.stderr | ansi strip) | str contains "Bearer token is missing") "missing bearer token must have an actionable diagnostic"
        assert equal $malformed.stderr ($malformed.stderr | ansi strip) "missing bearer token stderr must not contain ANSI"
        assert-no-auth-leak {stdout: $malformed.stdout, stderr: ""} $secrets "missing bearer token diagnostic"
        for secret in $secrets {
            assert (not ($malformed.stderr | str contains $secret)) "missing bearer token diagnostic exposed an authentication value"
        }
        assert equal (command-error-wire-events $server | length) $before_malformed "missing bearer token must fail before network access"

        let events = (command-error-wire-events $server)
        assert equal ($events | length) 19 "protected endpoint request count did not match executed cases"
        let bearer_header = $"Bearer ($bearer_token)"
        let prefixed_header = $"Bearer ($prefixed_token)"
        for path in ["/direct" "/prefixed" "/basic" "/debug" "/chain-inline" "/chain-named" "/binary" "/oauth-obtain" "/oauth-refresh"] {
            assert equal ($events | where path == $path | length) 1 $"expected exactly one protected request for ($path)"
        }
        assert (($events | where path == "/direct" | all {|event| $event.authorization == $bearer_header })) "direct request did not carry the configured bearer value"
        assert (($events | where path == "/prefixed" | all {|event| $event.authorization == $prefixed_header })) "prefixed bearer value was changed or double-prefixed"
        assert (($events | where path == "/basic" | all {|event| $event.authorization | str starts-with "Basic " })) "basic authentication regression request did not carry a Basic header"
        for path in ["/debug" "/saved" "/chain-inline" "/chain-named" "/binary"] {
            let path_events = ($events | where path == $path)
            assert (($path_events | length) > 0) $"wire capture for ($path) was vacuous"
            assert ($path_events | all {|event| $event.authorization == $bearer_header }) $"wire capture for ($path) did not carry the configured bearer value"
        }
        assert (($events | where path == "/saved" | length) == ($output_cases | length)) "not every saved-request output mode reached the protected endpoint"
        assert (($events | where path == "/oauth-obtain" | all {|event| $event.authorization == $"Bearer ($first_access)" })) "obtained OAuth2 token was not used on wire"
        assert (($events | where path == "/oauth-refresh" | all {|event| $event.authorization == $"Bearer ($refreshed_access)" })) "refreshed OAuth2 token was not used on wire"

        let public_snapshot = (
            command-error-snapshot $root
            | where {|entry| not ($entry.path | str ends-with "secrets.nuon") }
            | get content
            | compact
            | str join "\n"
        )
        for secret in $secrets {
            assert (not ($public_snapshot | str contains $secret)) "public workspace records persisted an authentication value"
        }
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
    assert (not ($root | path exists)) "auth wire test leaked its workspace"
    assert (not ($infra | path exists)) "auth wire test leaked its server files"
}

def run-suite-command-errors []: nothing -> list<record> {
    print $"\n(ansi yellow)── Public command error contracts ──(ansi reset)"
    [
        (run-test "logical duplicate/not-found failures use stderr and nonzero exit" { test-public-command-error-contracts })
        (run-test "OAuth2 obtain/refresh keep stderr clean and persist tokens safely" { test-oauth2-success-streams-and-persistence })
        (run-test "execution sends real auth while output, exports, and records stay redacted" { test-authentication-wire-and-redaction })
    ]
}
