# Structured request-body interpolation and serialization regressions.

def request-body-python [] {
    if not (which python | is-empty) {
        "python"
    } else if not (which python3 | is-empty) {
        "python3"
    } else {
        error make {msg: "Python is required for the request-body echo server"}
    }
}

def request-body-process-running [pid: int] {
    try {
        (ps | where pid == $pid | length) > 0
    } catch {
        false
    }
}

def start-request-body-server [tmp: string] {
    let python = (request-body-python)
    let server_script = ($tmp | path join "body-server.py")
    let launcher_script = ($tmp | path join "body-launcher.py")
    let port_file = ($tmp | path join "body-port.txt")
    let event_file = ($tmp | path join "body-events.jsonl")
    let stop_file = ($tmp | path join "body-stop.txt")
    let server_source = "import http.server
import json
import os
import sys
import time

port_file, event_file, stop_file = sys.argv[1:4]

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def emit(self, payload):
        encoded = json.dumps(payload, separators=(',', ':')).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if self.path == '/ready':
            self.emit({'ready': True})
        else:
            self.emit({'ok': True})

    def handle_body(self):
        length = int(self.headers.get('Content-Length', '0'))
        body_bytes = self.rfile.read(length) if length else b''
        event = {
            'method': self.command,
            'path': self.path,
            'headers': [
                {'name': name, 'value': value}
                for name, value in self.headers.raw_items()
            ],
            'body': body_bytes.decode('utf-8'),
        }
        with open(event_file, 'a', encoding='utf-8') as handle:
            handle.write(json.dumps(event, separators=(',', ':')) + '\\n')
        self.emit({'ok': True})

    def do_POST(self):
        self.handle_body()

    def do_PUT(self):
        self.handle_body()

    def do_PATCH(self):
        self.handle_body()

server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
server.timeout = 0.1
with open(port_file, 'w', encoding='utf-8') as handle:
    handle.write(str(server.server_port))
with open(event_file, 'w', encoding='utf-8') as handle:
    handle.write('')
deadline = time.time() + 180
while not os.path.exists(stop_file) and time.time() < deadline:
    server.handle_request()
server.server_close()
"
    let launcher_source = "import os
import subprocess
import sys

options = {
    'stdin': subprocess.DEVNULL,
    'stdout': subprocess.DEVNULL,
    'stderr': subprocess.DEVNULL,
}
if os.name == 'nt':
    options['creationflags'] = subprocess.CREATE_NO_WINDOW
else:
    options['start_new_session'] = True
process = subprocess.Popen(sys.argv[1:], **options)
print(process.pid)
"
    $server_source | save -f $server_script
    $launcher_source | save -f $launcher_script
    let launched = (test-complete-result (do {
        ^$python $launcher_script $python $server_script $port_file $event_file $stop_file
    } | complete))
    assert equal $launched.exit_code 0 $"Request-body server launcher failed: ($launched.stderr)"
    let server_base = {
        pid: ($launched.stdout | str trim | into int)
        port: 0
        port_file: $port_file
        event_file: $event_file
        stop_file: $stop_file
        python: $python
    }
    for _ in 1..100 {
        if ($port_file | path exists) and (request-body-process-running $server_base.pid) {
            break
        }
        sleep 50ms
    }
    assert ($port_file | path exists) "Request-body server did not publish its port"
    let server = ($server_base | update port (open $port_file --raw | str trim | into int))
    let ready = (test-complete-result (do {
        ^curl -s --max-time 2 $"http://127.0.0.1:($server.port)/ready"
    } | complete))
    assert equal $ready.exit_code 0 $"Request-body server readiness failed: ($ready.stderr)"
    $server
}

def stop-request-body-server [server: record] {
    "" | save -f $server.stop_file
    for _ in 1..100 {
        if not (request-body-process-running $server.pid) {
            break
        }
        sleep 50ms
    }
    if (request-body-process-running $server.pid) {
        if $nu.os-info.name == "windows" {
            ^powershell.exe -NoProfile -NonInteractive -Command $"Stop-Process -Id ($server.pid) -Force" | ignore
        } else {
            ^kill -TERM $server.pid | ignore
        }
    }
    assert (not (request-body-process-running $server.pid)) $"Request-body server PID ($server.pid) did not stop"
}

def request-body-events [server: record] {
    if not ($server.event_file | path exists) {
        return []
    }
    open $server.event_file --raw
    | lines
    | where {|line| not ($line | is-empty) }
    | each {|line| $line | from json }
}

def request-body-event [server: record, path: string] {
    let matches = (request-body-events $server | where path == $path)
    assert (not ($matches | is-empty)) $"No request reached ($path)"
    $matches | last
}

def request-body-history-ids [root: string] {
    let index = ($root | path join "history" "index.nuon")
    if ($index | path exists) {
        try { open $index | get id } catch { [] }
    } else {
        []
    }
}

def request-body-new-history-id [root: string, before: list] {
    let added = (request-body-history-ids $root | where {|id| $id not-in $before })
    assert equal ($added | length) 1 "Expected exactly one new history entry"
    $added | first
}

def request-body-preview-rendering [server: record, line: string, tmp: string] {
    let line_path = ($tmp | path join $"preview-(random uuid).txt")
    $line | save -f $line_path
    let code = "import json, re, shlex, sys
text = open(sys.argv[1], encoding='utf-8').read().strip()
tokens = shlex.split(text)
safe = re.compile(r'^[A-Za-z0-9_@%+:,./-]+$')
def render(value):
    if safe.fullmatch(value):
        return value
    escaped = value.replace(chr(39), chr(39) + chr(92) + chr(39) + chr(39))
    return chr(39) + escaped + chr(39)
print(json.dumps({'args': tokens[1:], 'canonical': ' '.join(render(value) for value in tokens)}))"
    let parsed = (test-complete-result (do { ^$server.python -c $code $line_path } | complete))
    rm -f $line_path
    assert equal $parsed.exit_code 0 $"Preview shell parsing failed: ($parsed.stderr)"
    $parsed.stdout | from json
}

def assert-request-body-preview-case [
    root: string
    server: record
    tmp: string
    command: string
] {
    let before = (request-body-events $server | length)
    let preview = (run-command-process $root ($command + " --dry-run"))
    assert equal $preview.exit_code 0 $"Body preview failed: ($preview.stderr)"
    let line = ($preview.stdout | str trim)
    let rendering = (request-body-preview-rendering $server $line $tmp)
    assert equal $line $rendering.canonical "Body preview used unsafe shell rendering"
    let replay = if $nu.os-info.name == "windows" {
        test-complete-result (do { ^curl ...$rendering.args } | complete)
    } else {
        test-complete-result (do {
            cd $tmp
            ^sh -c $line
        } | complete)
    }
    assert equal $replay.exit_code 0 $"Body preview curl failed: ($replay.stderr)"
    let execution = (run-command-process $root $command)
    assert equal $execution.exit_code 0 $"Body execution failed: ($execution.stderr)"
    let events = (request-body-events $server | skip $before)
    assert equal ($events | length) 2 "Preview and execution did not each reach the endpoint"
    assert equal ($events | first | get body) ($events | last | get body) "Preview body differed from execution"
}

def test-request-body-json-boundary [] {
    let root = (make-temp-dir "request-body-json")
    let infra = (make-temp-dir "request-body-json-server")
    let server = (start-request-body-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let base = $"http://127.0.0.1:($server.port)"
        let cases = [
            {name: "safe", value: "baseline"}
            {name: "quote", value: "say \"hello\""}
            {name: "backslash", value: 'C:\temp\new'}
            {name: "controls", value: "line one\nline two\tend"}
            {name: "injection", value: 'x","admin":true,"other":"y'}
            {name: "utf8", value: "café 東京"}
            {name: "empty", value: ""}
            {name: "open-braces", value: "literal {{ marker"}
        ]
        for case in $cases {
            api vars set payload $case.value | ignore
            let path = $"/json-($case.name)"
            let result = (api post $"($base)($path)" -b {value: "{{payload}}", numeric_text: "5"} --raw --no-history)
            let wire = (request-body-event $server $path).body | from json
            assert equal $wire.value $case.value $"($case.name): wire value changed"
            assert equal $wire.numeric_text "5" $"($case.name): string type changed"
            assert equal $result.request.body.value $case.value $"($case.name): result.request.body changed"
            assert equal $result.request.body.numeric_text "5" $"($case.name): result.request.body type changed"
        }

        api vars set k realkey | ignore
        api vars set v realval | ignore
        let keyed = (api post $"($base)/key" -b {"{{k}}": "{{v}}"} --raw --no-history)
        assert equal ((request-body-event $server "/key").body | from json | get realkey) "realval"
        assert equal $keyed.request.body.realkey "realval"

        let before_collision = (request-body-events $server | length)
        let collision = try {
            api post $"($base)/collision" -b {"{{k}}": first, realkey: second} --raw --no-history | ignore
            null
        } catch {|error| $error}
        assert ($collision != null) "Interpolated key collision unexpectedly succeeded"
        assert ($collision.msg | str contains "duplicate key 'realkey'") "Collision error was not actionable"
        assert equal (request-body-events $server | length) $before_collision "Collision sent an endpoint request"

        api vars set payload "string-body" | ignore
        let string_result = (api post $"($base)/string" -b '{"value":"{{payload}}"}' --raw --no-history)
        assert equal ((request-body-event $server "/string").body | from json | get value) "string-body"
        assert equal $string_result.request.body.value "string-body"

        let body_file = ($root | path join "body.json")
        "{\n  \"value\": \"{{payload}}\"\n}\n" | save -f $body_file
        let file_result = (api post $"($base)/file" --body-file $body_file --raw --no-history)
        assert equal ((request-body-event $server "/file").body | from json | get value) "string-body"
        assert equal $file_result.request.body.value "string-body"

        api vars set payload surface-value | ignore
        api put $"($base)/put" -b {value: "{{payload}}"} --raw --no-history | ignore
        api patch $"($base)/patch" -b {value: "{{payload}}"} --raw --no-history | ignore
        api request -m POST $"($base)/request" -b {value: "{{payload}}"} --raw --no-history | ignore
        for path in ["/put" "/patch" "/request"] {
            assert equal ((request-body-event $server $path).body | from json | get value) "surface-value" $"($path): structured body was not resolved"
        }

        for case in [
            {path: "/history-json-string", body: '"hello"'}
            {path: "/history-plain-string", body: "hello"}
        ] {
            let before_history = (request-body-history-ids $root)
            api post $"($base)($case.path)" -b $case.body --raw | ignore
            let history_id = (request-body-new-history-id $root $before_history)
            let history_entry = (api history get $history_id)
            assert equal $history_entry.request.body $case.body $"($case.path): history did not retain exact body bytes"
            api history resend $history_id --raw | ignore
            let events = (request-body-events $server | where path == $case.path)
            assert equal ($events | length) 2 $"($case.path): history resend did not reach the endpoint"
            assert equal ($events | first | get body) ($events | last | get body) $"($case.path): history resend changed body bytes"
        }
        null
    } catch {|error| $error}
    try { stop-request-body-server $server } catch {}
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
}

def test-request-body-form-boundary [] {
    let root = (make-temp-dir "request-body-form")
    let infra = (make-temp-dir "request-body-form-server")
    let server = (start-request-body-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        api vars set payload "alpha&admin=true" | ignore
        let result = (api post $"http://127.0.0.1:($server.port)/form" -F {note: "{{payload}}", empty: ""} --raw --no-history)
        let event = (request-body-event $server "/form")
        assert equal $event.body "note=alpha%26admin%3Dtrue&empty=" "Form value injected an extra parameter"
        assert equal $result.request.body $event.body "Form result.request.body differed from wire bytes"
        let base = $"http://127.0.0.1:($server.port)"
        api put $"($base)/form-put" -F {note: "{{payload}}"} --raw --no-history | ignore
        api patch $"($base)/form-patch" -F {note: "{{payload}}"} --raw --no-history | ignore
        api request -m POST $"($base)/form-request" -F {note: "{{payload}}"} --raw --no-history | ignore
        for path in ["/form-put" "/form-patch" "/form-request"] {
            assert equal (request-body-event $server $path).body "note=alpha%26admin%3Dtrue" $"($path): form body was not encoded safely"
        }
        null
    } catch {|error| $error}
    try { stop-request-body-server $server } catch {}
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
}

def test-request-body-table-flows [] {
    let root = (make-temp-dir "request-body-table")
    let infra = (make-temp-dir "request-body-table-server")
    let server = (start-request-body-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        api vars set payload table-value | ignore
        let base = $"http://127.0.0.1:($server.port)"
        let uniform = [
            {name: "{{payload}}", n: 1}
            {name: "{{payload}}", n: 2}
        ]
        let heterogeneous = [
            {name: "{{payload}}"}
            {other: "{{payload}}"}
        ]
        let nested = (api vars interpolate-record {uniform: $uniform, heterogeneous: $heterogeneous})
        assert equal $nested.uniform.0.name "table-value"
        assert equal $nested.uniform.1.name "table-value"
        assert equal $nested.heterogeneous.0.name "table-value"
        assert equal $nested.heterogeneous.1.other "table-value"

        let before_history = (request-body-history-ids $root)
        let direct = (api post $"($base)/history-table" -b $uniform --raw)
        let history_id = (request-body-new-history-id $root $before_history)
        let history_entry = (api history get $history_id)
        assert equal $direct.request.body.0.name "table-value"
        assert equal $history_entry.request.body.1.name "table-value"
        api history resend $history_id --raw | ignore
        let history_events = (request-body-events $server | where path == "/history-table")
        assert equal ($history_events | length) 2 "History resend did not replay the table body"
        assert equal (($history_events | first | get body | from json)) (($history_events | last | get body | from json))

        let before_hetero_history = (request-body-history-ids $root)
        let hetero_result = (api post $"($base)/heterogeneous" -b $heterogeneous --raw)
        let hetero_history_id = (request-body-new-history-id $root $before_hetero_history)
        let hetero_wire = (request-body-event $server "/heterogeneous").body | from json
        assert equal $hetero_wire.0.name "table-value"
        assert equal $hetero_wire.1.other "table-value"
        assert equal $hetero_result.request.body.1.other "table-value"
        api history resend $hetero_history_id --raw | ignore
        let hetero_history_events = (request-body-events $server | where path == "/heterogeneous")
        assert equal ($hetero_history_events | length) 2 "History resend did not replay the heterogeneous table body"
        assert equal (($hetero_history_events | first | get body | from json)) (($hetero_history_events | last | get body | from json))

        let chain = (api chain run ([
            {
                method: POST
                url: $"($base)/chain-uniform"
                use: {payload: "chain-value"}
                body: {content: $uniform}
            }
            {
                method: POST
                url: $"($base)/chain-heterogeneous"
                use: {payload: "chain-value"}
                body: {content: $heterogeneous}
            }
        ]) --quiet)
        assert equal $chain.success true "Chain table request failed"
        let chain_uniform_wire = (request-body-event $server "/chain-uniform").body | from json
        assert equal $chain_uniform_wire.0.name "chain-value"
        assert equal $chain_uniform_wire.1.name "chain-value"
        let chain_heterogeneous_wire = (request-body-event $server "/chain-heterogeneous").body | from json
        assert equal $chain_heterogeneous_wire.0.name "chain-value"
        assert equal $chain_heterogeneous_wire.1.other "chain-value"
        null
    } catch {|error| $error}
    try { stop-request-body-server $server } catch {}
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
}

def test-request-body-preview-history-and-masking [] {
    let root = (make-temp-dir "request-body-preview")
    let infra = (make-temp-dir "request-body-preview-server")
    let scratch = (make-temp-dir "request-body-preview-scratch")
    let server = (start-request-body-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        api vars set payload 'preview "quoted" \ value' | ignore
        let base = $"http://127.0.0.1:($server.port)"
        api collection create body-preview | ignore
        let request_path = ($root | path join "collections" "body-preview" "requests" "saved.nuon")
        {
            name: "saved"
            collection: "body-preview"
            method: "POST"
            url: $"($base)/preview"
            headers: {}
            body: {type: "json", content: {value: "{{payload}}"}}
            auth: null
        } | to nuon --indent 4 | save -f $request_path
        let send_command = "api send saved -c body-preview --raw --no-history"
        assert-request-body-preview-case $root $server $scratch $send_command
        let exported = (run-command-process $root "api request export saved -c body-preview")
        let preview = (run-command-process $root ($send_command + " --dry-run"))
        assert equal $exported.exit_code 0 $"Request export failed: ($exported.stderr)"
        assert equal ($exported.stdout | str trim) ($preview.stdout | str trim) "Request export differed from send preview"

        let secret = "BODY-CREDENTIAL-SENTINEL"
        let before_history = (request-body-history-ids $root)
        let result = (api post $"($base)/credential" -b {ok: true} -a {type: bearer, token: $secret} --raw)
        let history_id = (request-body-new-history-id $root $before_history)
        let history_entry = (api history get $history_id)
        assert (not (($result | to nuon) | str contains $secret)) "Result exposed the credential"
        assert (not (($history_entry | to nuon) | str contains $secret)) "History exposed the credential"
        let auth_headers = (
            (request-body-event $server "/credential").headers
            | where {|header| $header.name == "Authorization" }
        )
        assert equal ($auth_headers | length) 1 "Credential was not sent exactly once"
        assert equal ($auth_headers | first | get value) $"Bearer ($secret)"
        null
    } catch {|error| $error}
    try { stop-request-body-server $server } catch {}
    cleanup $root
    cleanup $infra
    cleanup $scratch
    if $failure != null { error make {msg: $failure.msg} }
}

def run-suite-request-body []: nothing -> list<record> {
    [
        (run-test "request body: JSON interpolation precedes serialization" { test-request-body-json-boundary })
        (run-test "request body: form interpolation precedes URL encoding" { test-request-body-form-boundary })
        (run-test "request body: tables survive vars, history, and chain flows" { test-request-body-table-flows })
        (run-test "request body: preview, history, and masking stay coherent" { test-request-body-preview-history-and-masking })
    ]
}

def run-suite-request-body-compat []: nothing -> list<record> {
    run-suite-request-body
}
