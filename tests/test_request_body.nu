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
        elif self.path == '/chain-source':
            self.emit({
                'next': 'ZZ{{late}}ZZ',
                'id': '101',
                'opaque_url': 'T{{late}}/Q{{c}}',
                'number': 42,
                'flag': True,
                'none': None,
                'items': [1, 'L{{late}}'],
                'record': {'inner': 'R{{c}}'},
                'sentinel': '__NURL_CHAIN_OPAQUE_fake__',
                'duplicate_a': 'D{{late}}',
                'duplicate_b': 'D{{late}}',
            })
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

        api vars set a "{{c}}" | ignore
        api vars set b B | ignore
        api vars set c C | ignore
        api vars set selfref "{{selfref}}x" | ignore
        api vars set p "{{q}}" | ignore
        api vars set q "{{p}}" | ignore
        let variables_path = ($root | path join "variables.nuon")
        let unused_vars = (0..299 | reduce -f {} {|index, vars|
            $vars | merge {($"unused_($index)"): $"{{unused_($index)}}x"}
        })
        open $variables_path | merge $unused_vars | to nuon | save -f $variables_path
        api post $"($base)/unused-cycles" -b {value: static} --raw --no-history | ignore
        assert equal ((request-body-event $server "/unused-cycles").body | from json | get value) "static" "Unused variable cycles affected an unrelated request"
        let before_referenced_cycle = (request-body-events $server | length)
        let referenced_cycle = try {
            api post $"($base)/referenced-cycle" -b {value: "{{selfref}}"} --raw --no-history | ignore
            null
        } catch {|error| $error}
        assert ($referenced_cycle != null) "Referenced trusted-variable cycle unexpectedly succeeded"
        assert ($referenced_cycle.msg | str contains "Variable interpolation cycle detected at 'selfref'") "Referenced cycle error was not actionable"
        assert equal (request-body-events $server | length) $before_referenced_cycle "Referenced cycle reached the endpoint"
        let trusted_result = (api post $"($base)/trusted-layer" -b {value: "{{a}}/{{b}}"} --raw --no-history)
        assert equal $trusted_result.request.body.value "C/B" "Direct structured body did not pre-resolve trusted variables"
        assert equal ((request-body-event $server "/trusted-layer").body | from json | get value) "C/B"

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

        api vars set inj 'x","admin":true,"other":"y' | ignore
        let malicious_file = ($root | path join "malicious.json")
        '{"v":"{{inj}}"}' | save -f $malicious_file
        let malicious_result = (api post $"($base)/file-injection" --body-file $malicious_file --raw --no-history)
        let malicious_wire = ((request-body-event $server "/file-injection").body | from json)
        assert equal ($malicious_wire | columns) ["v"] "JSON body-file interpolation injected a field"
        assert equal $malicious_wire.v 'x","admin":true,"other":"y'
        assert equal $malicious_result.request.body $malicious_wire

        api vars set payload file-text | ignore
        let text_file = ($root | path join "body.txt")
        'raw={{payload}}&x=1' | save -f $text_file
        let text_file_result = (api post $"($base)/file-text" --body-file $text_file --raw --no-history)
        assert equal (request-body-event $server "/file-text").body "raw=file-text&x=1"
        assert equal $text_file_result.request.body "raw=file-text&x=1"

        let json_string_file = ($root | path join "body-string.json")
        '"{{payload}}"' | save -f $json_string_file
        api post $"($base)/file-json-string" --body-file $json_string_file --raw --no-history | ignore
        assert equal (request-body-event $server "/file-json-string").body '"file-text"'

        let json_null_file = ($root | path join "body-null.json")
        "null" | save -f $json_null_file
        let before_null_history = (request-body-history-ids $root)
        api post $"($base)/file-json-null" --body-file $json_null_file --raw | ignore
        let null_history_id = (request-body-new-history-id $root $before_null_history)
        assert equal (request-body-event $server "/file-json-null").body "null"
        assert equal (api history get $null_history_id).request.body "null" "JSON null was indistinguishable from an absent history body"
        api history resend $null_history_id --raw | ignore
        assert equal (request-body-events $server | where path == "/file-json-null" | get body) ["null" "null"] "JSON null history replay lost its body"

        for case in [
            {name: "object", content: "{}"}
            {name: "array", content: "[]"}
        ] {
            let empty_file = ($root | path join $"body-empty-($case.name).json")
            $case.content | save -f $empty_file
            let before_empty_history = (request-body-history-ids $root)
            api post $"($base)/file-json-empty-($case.name)" --body-file $empty_file --raw | ignore
            let empty_history_id = (request-body-new-history-id $root $before_empty_history)
            api history resend $empty_history_id --raw | ignore
            assert equal (
                request-body-events $server
                | where path == $"/file-json-empty-($case.name)"
                | get body
            ) [$case.content $case.content] $"Empty JSON ($case.name) history replay lost its body"
        }

        let nested_nulls = {items: [1, null, 3], keep: null}
        let nested_null_result = (api post $"($base)/null-nested" -b $nested_nulls --raw --no-history)
        let nested_null_wire = ((request-body-event $server "/null-nested").body | from json)
        assert equal ($nested_null_wire.items | length) 3 "Nested list lost a null element"
        assert ($nested_null_wire.items.1 == null) "Nested list changed its null element"
        assert ("keep" in ($nested_null_wire | columns)) "Record lost its null field"
        assert ($nested_null_wire.keep == null) "Record null field changed"
        assert equal $nested_null_result.request.body $nested_null_wire

        let top_null_result = (api post $"($base)/null-top" -b [1, null, 3] --raw --no-history)
        let top_null_wire = ((request-body-event $server "/null-top").body | from json)
        assert equal ($top_null_wire | length) 3 "Top-level list lost a null element"
        assert ($top_null_wire.1 == null) "Top-level list changed its null element"
        assert equal $top_null_result.request.body $top_null_wire

        let unresolved = (api post $"($base)/unresolved-spacing" -b {
            first: "{{ missing }}"
            second: "before {{ other }} after {{ third }}"
        } --raw --no-history)
        assert equal $unresolved.request.body.first "{{ missing }}"
        assert equal $unresolved.request.body.second "before {{ other }} after {{ third }}" "Unresolved placeholders lost their original spacing"
        assert equal (
            api vars interpolate "before {{ missing }} after {{ other }}" -e {} --resolved --single-pass
        ) "before {{ missing }} after {{ other }}" "Foreign template placeholders were rewritten"
        api post $"($base)/literal-url/{{foreign}}" -b {ok: true} --raw --no-history | ignore
        assert equal (request-body-event $server "/literal-url/{{foreign}}").path "/literal-url/{{foreign}}" "Literal URL braces were treated as curl glob syntax"

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

        let before_literal_history = (request-body-history-ids $root)
        api post $"($base)/history-literal" -b "literal={{late}}" --raw | ignore
        let literal_history_id = (request-body-new-history-id $root $before_literal_history)
        api vars set late SHOULD-NOT-APPEAR | ignore
        api history resend $literal_history_id --raw | ignore
        let literal_events = (request-body-events $server | where path == "/history-literal")
        assert equal ($literal_events | length) 2
        assert equal ($literal_events | get body) ["literal={{late}}" "literal={{late}}"] "History replay re-interpolated exact stored text"

        let long_body = (0..39999 | each { "x" } | str join)
        let long_history_id = (api history save {
            method: "POST"
            url: $"($base)/history-large"
            headers: {"Content-Type": "text/plain"}
            body: $long_body
        } {
            status: 200
            status_text: "OK"
            headers: {}
            body: null
            time_ms: 0
            size_bytes: 0
        })
        api history resend $long_history_id --raw | ignore
        assert equal ((request-body-event $server "/history-large").body | str length) 40000 "Large exact replay did not use stdin transport"

        let config_path = ($root | path join "config.nuon")
        open $config_path
        | update default_headers {"Authorization": "NEW-DEFAULT-CREDENTIAL"}
        | to nuon --indent 4
        | save -f $config_path
        let replay = (api history resend $literal_history_id --raw)
        let replay_event = (request-body-events $server | where path == "/history-literal" | last)
        assert equal ($replay_event.headers | where name == "Authorization" | length) 0 "Exact history replay added a new default credential"
        assert (not (($replay | to nuon) | str contains "NEW-DEFAULT-CREDENTIAL")) "Exact history replay exposed a new default credential"
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
        api vars set form_key note | ignore
        api vars set a "{{c}}" | ignore
        api vars set b B | ignore
        api vars set c C | ignore
        let result = (api post $"http://127.0.0.1:($server.port)/form" -F {"{{form_key}}": "{{payload}}", empty: ""} --raw --no-history)
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
        api post $"($base)/form-trusted" -F {value: "{{a}}/{{b}}"} --raw --no-history | ignore
        let trusted_form_body = (request-body-event $server "/form-trusted").body
        assert equal $trusted_form_body "value=C/B" $"Direct form did not pre-resolve trusted variables: ($trusted_form_body)"
        api vars set dynamic_id "{{$uuid}}" | ignore
        api vars set layered_dynamic "{{dynamic_id}}" | ignore
        api request -m POST $"($base)/form-dynamic/{{dynamic_id}}" -F {id: "{{dynamic_id}}"} --raw --no-history | ignore
        let dynamic_event = (request-body-events $server | where {|event| $event.path | str starts-with "/form-dynamic/" } | last)
        assert equal (
            $dynamic_event.path | str replace "/form-dynamic/" ""
        ) ($dynamic_event.body | str replace "id=" "") "Form body and URL did not share one trusted variable map"
        api request -m POST $"($base)/form-dynamic-layered/{{dynamic_id}}" -F {id: "{{layered_dynamic}}"} --raw --no-history | ignore
        let layered_dynamic_event = (request-body-events $server | where {|event| $event.path | str starts-with "/form-dynamic-layered/" } | last)
        assert equal (
            $layered_dynamic_event.path | str replace "/form-dynamic-layered/" ""
        ) ($layered_dynamic_event.body | str replace "id=" "") "Layered dynamic alias was evaluated more than once"
        let large_form_value = (0..39999 | each { "x" } | str join)
        api request -m POST $"($base)/form-large" -F {value: $large_form_value} --raw --no-history | ignore
        assert equal ((request-body-event $server "/form-large").body | str length) 40006 "Large form did not use stdin transport"
        api request -m POST $"($base)/form-literal" -F {"{{form_key}}": "{{payload}}"} --no-interpolate --raw --no-history | ignore
        let literal_form_body = (request-body-event $server "/form-literal" | get body)
        assert equal (
            $literal_form_body
        ) "{{form_key}}={{payload}}" $"--no-interpolate changed literal form content: ($literal_form_body)"
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

        let null_body = {items: [1, null, "{{payload}}"], keep: null}
        let interpolated_nulls = (api vars interpolate-record $null_body)
        assert equal ($interpolated_nulls.items | length) 3 "interpolate-record dropped a null list element"
        assert ($interpolated_nulls.items.1 == null)
        assert equal $interpolated_nulls.items.2 "table-value"
        assert ("keep" in ($interpolated_nulls | columns))
        assert ($interpolated_nulls.keep == null)

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

        api collection create body-null | ignore
        let saved_path = ($root | path join "collections" "body-null" "requests" "nulls.nuon")
        {
            name: "nulls"
            collection: "body-null"
            method: "POST"
            url: $"($base)/saved-nulls"
            headers: {"{{saved_header}}": "{{saved_header_value}}"}
            body: {type: "json", content: $null_body}
            auth: null
        } | to nuon --indent 4 | save -f $saved_path
        let saved_result = (api send nulls -c body-null --raw)
        let saved_wire = ((request-body-event $server "/saved-nulls").body | from json)
        assert equal ($saved_wire.items | length) 3 "Saved request dropped a null list element"
        assert ($saved_wire.items.1 == null)
        assert ("keep" in ($saved_wire | columns))
        assert ($saved_wire.keep == null)
        assert equal $saved_result.request.body $saved_wire
        let saved_history_id = (request-body-history-ids $root | first)
        api history resend $saved_history_id --raw | ignore
        let saved_events = (request-body-events $server | where path == "/saved-nulls")
        assert equal ($saved_events | length) 2 "Saved-request history replay did not reach the endpoint"
        assert equal (($saved_events | first | get body | from json)) (($saved_events | last | get body | from json))

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
            {
                method: POST
                url: $"($base)/chain-nulls"
                use: {payload: "chain-value"}
                body: {content: $null_body}
            }
        ]) --quiet)
        assert equal $chain.success true "Chain table request failed"
        let chain_uniform_wire = (request-body-event $server "/chain-uniform").body | from json
        assert equal $chain_uniform_wire.0.name "chain-value"
        assert equal $chain_uniform_wire.1.name "chain-value"
        let chain_heterogeneous_wire = (request-body-event $server "/chain-heterogeneous").body | from json
        assert equal $chain_heterogeneous_wire.0.name "chain-value"
        assert equal $chain_heterogeneous_wire.1.other "chain-value"
        let chain_null_wire = (request-body-event $server "/chain-nulls").body | from json
        assert equal ($chain_null_wire.items | length) 3 "Chain dropped a null list element"
        assert ($chain_null_wire.items.1 == null)
        assert equal $chain_null_wire.items.2 "chain-value"
        assert ("keep" in ($chain_null_wire | columns))
        assert ($chain_null_wire.keep == null)
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
        api vars set saved_header X-Saved-Expanded | ignore
        api vars set saved_header_value saved-value | ignore
        let base = $"http://127.0.0.1:($server.port)"
        api vars set saved_host $base | ignore
        api vars set saved_url "{{saved_host}}/preview" | ignore
        api vars set saved_prefix trusted | ignore
        api vars set saved_title "{{saved_prefix}}" | ignore
        api vars set saved_suffix body | ignore
        assert-request-body-preview-case $root $server $scratch (
            "api post " + (($base + "/preview-literal/{{foreign}}") | to nuon)
            + " -b {ok: true} --raw --no-history"
        )
        assert equal (request-body-events $server | where path == "/preview-literal/{{foreign}}" | length) 2 "Dry-run and execution did not preserve literal URL braces"
        api collection create body-preview | ignore
        let request_path = ($root | path join "collections" "body-preview" "requests" "saved.nuon")
        {
            name: "saved"
            collection: "body-preview"
            method: "POST"
            url: "{{saved_url}}"
            headers: {"{{saved_header}}": "{{saved_header_value}}"}
            body: {type: "json", content: {value: "{{payload}}", layered: "{{saved_title}}/{{saved_suffix}}"}}
            auth: null
        } | to nuon --indent 4 | save -f $request_path
        let send_command = "api send saved -c body-preview --raw --no-history"
        assert-request-body-preview-case $root $server $scratch $send_command
        let exported = (run-command-process $root "api request export saved -c body-preview")
        let preview = (run-command-process $root ($send_command + " --dry-run"))
        assert equal $exported.exit_code 0 $"Request export failed: ($exported.stderr)"
        assert equal ($exported.stdout | str trim) ($preview.stdout | str trim) "Request export differed from send preview"
        let saved_event = (request-body-event $server "/preview")
        assert equal (($saved_event.body | from json).layered) "trusted/body" "Saved request body did not pre-resolve trusted variables"
        let literal_saved_headers = ($saved_event.headers | where name == "{{saved_header}}")
        assert equal ($literal_saved_headers | length) 1 $"Saved-request literal header missing: ($saved_event.headers | to nuon)"
        assert equal ($literal_saved_headers | first | get value) "saved-value" "Saved-request header value did not interpolate"
        assert equal ($saved_event.headers | where name == "X-Saved-Expanded" | length) 0 "Saved-request header name was unexpectedly interpolated"

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

def test-request-body-chain-single-pass [] {
    let root = (make-temp-dir "request-body-chain-pass")
    let infra = (make-temp-dir "request-body-chain-pass-server")
    let server = (start-request-body-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        api vars set late GLOBALLEAK | ignore
        api vars set chain_header_name X-Expanded | ignore
        let base = $"http://127.0.0.1:($server.port)"
        api vars set chain_server $base | ignore
        api vars set chain_base "{{chain_server}}/chain-use" | ignore
        api vars set static_prefix STATIC | ignore
        api vars set static_header "{{static_prefix}}-resolved" | ignore
        api vars set static_suffix tail | ignore
        api vars set dynamic_id "{{$uuid}}" | ignore
        api vars set shadow_cycle "{{shadow_cycle}}" | ignore
        api vars set global_var test_value | ignore
        let secret = "CHAIN-BODY-CREDENTIAL-SENTINEL"
        let config_path = ($root | path join "config.nuon")
        open $config_path
        | update default_headers {"X-Default-Chain": "{{bound}}/{{static_header}}"}
        | to nuon --indent 4
        | save -f $config_path
        let large_scalar = (0..39999 | each { "x" } | str join)
        let steps = [
            {
                method: GET
                url: $"($base)/chain-source"
                extract: {
                    captured: "body.next"
                    source_id: "body.id"
                    opaque_url: "body.opaque_url"
                    opaque_number: "body.number"
                    opaque_flag: "body.flag"
                    opaque_none: "body.none"
                    opaque_items: "body.items"
                    opaque_record: "body.record"
                    opaque_sentinel: "body.sentinel"
                    opaque_duplicate_a: "body.duplicate_a"
                    opaque_duplicate_b: "body.duplicate_b"
                    unused_record: "body"
                    missing_extract: "body.does_not_exist"
                }
            }
            {
                method: POST
                url: "{{chain_base}}/{{route}}/{{static_suffix}}"
                use: {route: "{{source_id}}", bound: "{{captured}}"}
                headers: {"{{chain_header_name}}": "literal-key", "X-Chain-Value": "{{bound}}/{{static_header}}"}
                auth: {type: bearer, token: $secret}
                body: {content: {value: "{{bound}}/{{static_header}}", static: "{{chain_base}}/{{static_suffix}}"}}
            }
            {
                method: POST
                url: $"($base)/chain-json-string"
                use: {bound: "{{captured}}"}
                body: {type: "json", content: "{{bound}}/{{static_suffix}}"}
            }
            {
                method: POST
                url: $"($base)/chain-json-null"
                body: {type: "json", content: null}
            }
            {
                method: POST
                url: $"($base)/chain-raw"
                body: "raw text"
            }
            {
                method: POST
                url: $"($base)/chain-raw-large"
                body: $large_scalar
            }
            {
                method: POST
                url: $"($base)/opaque-url/{{opaque_path}}/{{static_header}}"
                use: {opaque_path: "{{opaque_url}}"}
                body: "opaque-url"
            }
            {
                method: POST
                url: $"($base)/chain-typed"
                use: {a: "{{c}}", b: "B", c: "C"}
                body: {
                    type: "json"
                    content: {
                        number: "{{opaque_number}}"
                        flag: "{{opaque_flag}}"
                        none: "{{opaque_none}}"
                        items: "{{opaque_items}}"
                        record: "{{opaque_record}}"
                        sentinel: "{{opaque_sentinel}}"
                        duplicate_a: "{{opaque_duplicate_a}}"
                        duplicate_b: "{{opaque_duplicate_b}}"
                        trusted: "{{a}}/{{b}}"
                    }
                }
            }
            {
                method: POST
                url: $"($base)/chain-extracted-extension"
                use: {captured: "{{captured}}/extra"}
                body: {type: json, content: {value: "{{captured}}"}}
            }
        ]
        let chain = (api chain run $steps --quiet)
        assert equal $chain.success true "Single-pass chain failed"
        assert (not (($chain | to nuon) | str contains $secret)) "Chain result exposed its credential"
        let event = (request-body-event $server "/chain-use/101/tail")
        assert equal ($event.headers | where name == "X-Chain-Value" | first | get value) "ZZ{{late}}ZZ/STATIC-resolved" "Chain header did not resolve static templates around an opaque extract"
        assert equal ($event.headers | where name == "{{chain_header_name}}" | first | get value) "literal-key" "Chain header name was unexpectedly interpolated"
        assert equal ($event.headers | where name == "X-Expanded" | length) 0 "Chain header variable changed the header name"
        assert equal ($event.headers | where name == "X-Default-Chain" | first | get value) "ZZ{{late}}ZZ/STATIC-resolved" "Chain default header did not preserve opaque extracts while resolving static variables"
        assert equal (($event.body | from json).value) "ZZ{{late}}ZZ/STATIC-resolved" "Chain body did not resolve static templates around an opaque extract"
        assert equal (($event.body | from json).static) $"($base)/chain-use/tail" "Chain structured body did not recursively resolve static variables"
        assert equal ($event.headers | where name == "Authorization" | length) 1 "Chain credential header was not sent exactly once"
        assert equal (request-body-event $server "/chain-json-string").body '"ZZ{{late}}ZZ/tail"' "Chain JSON string did not combine opaque and recursively resolved static values"
        assert equal (request-body-event $server "/chain-json-null").body "null" "Chain JSON null was treated as an absent body"
        assert equal (request-body-event $server "/chain-raw").body "raw text" "Chain scalar body did not retain raw text"
        assert equal ((request-body-event $server "/chain-raw-large").body | str length) 40000 "Large chain scalar did not use stdin transport"
        assert equal (
            request-body-event $server "/opaque-url/T{{late}}/Q{{c}}/STATIC-resolved" | get path
        ) "/opaque-url/T{{late}}/Q{{c}}/STATIC-resolved" "Opaque URL braces did not reach the endpoint literally"
        let typed_body = (request-body-event $server "/chain-typed").body | from json
        assert equal $typed_body.number 42 "Opaque numeric extract became a string"
        assert equal $typed_body.flag true "Opaque boolean extract lost its type"
        assert ("none" in ($typed_body | columns)) "Opaque null extract was dropped"
        assert ($typed_body.none == null) "Opaque null extract did not remain null"
        assert equal $typed_body.items [1 "L{{late}}"] "Opaque list extract lost type or expanded nested braces"
        assert equal $typed_body.record {inner: "R{{c}}"} "Opaque record extract lost type or expanded nested braces"
        assert equal $typed_body.sentinel "__NURL_CHAIN_OPAQUE_fake__" "Sentinel-like attacker text aliased an internal token"
        assert equal $typed_body.duplicate_a "D{{late}}"
        assert equal $typed_body.duplicate_b "D{{late}}" "Identical extracted values confused token restoration"
        assert equal $typed_body.trusted "C/B" "Trusted placeholders beside opaque nodes did not resolve"
        assert ("opaque_none" in ($chain.context | columns)) "Null extract was not retained in chain context"
        assert ($chain.context.opaque_none == null)
        assert ("missing_extract" not-in ($chain.context | columns)) "Missing extract was incorrectly stored as null"
        assert equal (
            request-body-event $server "/chain-extracted-extension" | get body | from json | get value
        ) "ZZ{{late}}ZZ/extra" "Same-name use binding did not extend opaque extracted context"

        let chain_path = ($root | path join "chains" "use-binding.nuon")
        if not (($root | path join "chains") | path exists) {
            mkdir ($root | path join "chains")
        }
        {name: "use-binding", steps: $steps} | to nuon --indent 4 | save -f $chain_path
        let exec_result = (api chain exec use-binding --quiet)
        assert equal $exec_result.success true "api chain exec did not resolve step.use"
        let exec_events = (request-body-events $server | where path == "/chain-use/101/tail")
        assert equal ($exec_events | length) 2 "api chain run and exec did not both resolve the use-bound URL"
        let exec_event = ($exec_events | last)
        assert equal ($exec_event.headers | where name == "X-Chain-Value" | first | get value) "ZZ{{late}}ZZ/STATIC-resolved" "api chain exec did not preserve opaque extracts around static values"
        assert equal (($exec_event.body | from json).value) "ZZ{{late}}ZZ/STATIC-resolved"
        assert equal (request-body-events $server | where path == "/chain-raw" | get body) ["raw text" "raw text"] "api chain run/exec changed scalar raw bodies"
        assert equal (
            request-body-events $server | where path == "/chain-raw-large" | get body | each {|body| $body | str length }
        ) [40000 40000] "api chain run/exec did not preserve large scalar bodies"
        assert equal (request-body-events $server | where path == "/opaque-url/T{{late}}/Q{{c}}/STATIC-resolved" | length) 2
        let typed_exec_body = (request-body-events $server | where path == "/chain-typed" | last | get body | from json)
        assert equal $typed_exec_body.items [1 "L{{late}}"]
        assert equal $typed_exec_body.record {inner: "R{{c}}"}
        assert equal $typed_exec_body.number 42
        assert ($typed_exec_body.none == null)
        assert equal $typed_exec_body.sentinel "__NURL_CHAIN_OPAQUE_fake__"
        assert equal (
            request-body-events $server | where path == "/chain-extracted-extension" | last | get body | from json | get value
        ) "ZZ{{late}}ZZ/extra"

        let invalid_steps = [
            {
                method: GET
                url: $"($base)/chain-source"
                extract: {opaque_items: "body.items"}
            }
            {
                method: POST
                url: $"($base)/must-not-send-embedded-record"
                body: "items={{opaque_items}}"
            }
        ]
        let invalid = try {
            api chain run $invalid_steps --quiet | ignore
            null
        } catch {|error| $error}
        assert ($invalid != null) "Embedded structured opaque value unexpectedly succeeded"
        assert (
            $invalid.msg | str contains "Extracted chain value 'opaque_items' cannot be interpolated into text"
        ) $"Embedded structured opaque error was not actionable: ($invalid.msg)"
        assert equal (request-body-events $server | where path == "/must-not-send-embedded-record" | length) 0 "Embedded structured opaque value reached the endpoint"
        let exact_invalid_steps = [
            {
                method: GET
                url: $"($base)/chain-source"
                extract: {opaque_record: "body.record"}
            }
            {
                method: POST
                url: $"($base)/must-not-send-exact-record"
                body: "{{opaque_record}}"
            }
        ]
        let exact_invalid = try {
            api chain run $exact_invalid_steps --quiet | ignore
            null
        } catch {|error| $error}
        assert ($exact_invalid != null) "Exact structured opaque value unexpectedly entered a text body"
        assert ($exact_invalid.msg | str contains "Extracted chain value 'opaque_record' cannot be interpolated into text")
        assert equal (request-body-events $server | where path == "/must-not-send-exact-record" | length) 0

        let host = $"127.0.0.1:($server.port)"
        let trusted_use = {
            base: "http://{{host}}"
            host: $host
            id: "{{c}}"
            a: "{{c}}"
            b: "B"
            c: "C"
        }
        open $config_path
        | update default_headers {"X-Default-Trusted": "{{a}}/{{b}}"}
        | to nuon --indent 4
        | save -f $config_path
        let trusted_steps = [
            {
                method: POST
                url: "{{base}}/trusted-text/{{id}}"
                use: $trusted_use
                headers: {"X-Provenance": "{{a}}/{{b}}"}
                body: "{{a}}/{{b}}"
            }
            {
                method: POST
                url: "{{base}}/trusted-structured/{{id}}"
                use: $trusted_use
                headers: {"X-Provenance": "{{a}}/{{b}}"}
                body: {type: "json", content: {value: "{{a}}/{{b}}"}}
            }
        ]
        let trusted_run = (api chain run $trusted_steps --quiet)
        assert equal ($trusted_run.results | get status) [200 200] "Trusted layered chain run did not return [200, 200]"
        let trusted_text_event = (request-body-event $server "/trusted-text/C")
        assert equal ($trusted_text_event.headers | where name == "X-Provenance" | first | get value) "C/B"
        assert equal ($trusted_text_event.headers | where name == "X-Default-Trusted" | first | get value) "C/B"
        assert equal $trusted_text_event.body "C/B"
        let trusted_structured_event = (request-body-event $server "/trusted-structured/C")
        assert equal ($trusted_structured_event.headers | where name == "X-Provenance" | first | get value) "C/B"
        assert equal ($trusted_structured_event.headers | where name == "X-Default-Trusted" | first | get value) "C/B"
        assert equal (($trusted_structured_event.body | from json).value) "C/B"

        let trusted_chain_path = ($root | path join "chains" "trusted-validation.nuon")
        {name: "trusted-validation", steps: $trusted_steps} | to nuon --indent 4 | save -f $trusted_chain_path
        let trusted_exec = (api chain exec trusted-validation --quiet)
        assert equal ($trusted_exec.results | get status) [200 200] "Trusted layered chain exec did not return [200, 200]"
        assert equal (request-body-events $server | where path == "/trusted-text/C" | length) 2
        assert equal (request-body-events $server | where path == "/trusted-structured/C" | length) 2

        api vars set B beta | ignore
        api vars set C "{{B}}-c" | ignore
        let use_order_steps = [
            {
                method: POST
                url: $"($base)/use-self-extension"
                use: {C: "{{C}}/extra"}
                body: {type: json, content: {value: "{{C}}"}}
            }
            {
                method: POST
                url: $"($base)/use-order"
                use: {shown: "{{C}}", C: "override"}
                body: {type: json, content: {shown: "{{shown}}", current: "{{C}}"}}
            }
            {
                method: POST
                url: $"($base)/use-dynamic"
                use: {first: "{{dynamic_id}}", second: "{{dynamic_id}}"}
                body: {type: json, content: {first: "{{first}}", second: "{{second}}"}}
            }
            {
                method: POST
                url: $"($base)/use-shadow-cycle/{{shadow_cycle}}"
                use: {shadow_cycle: "override"}
                body: "shadow"
            }
            {
                method: POST
                url: $"($base)/use-forward-order"
                use: {
                    global_var: "{{global_var}}/extra"
                    x: "{{b}}"
                    b: "{{global_var}}"
                }
                body: {type: json, content: {global_var: "{{global_var}}", x: "{{x}}", b: "{{b}}"}}
            }
        ]
        let use_order_run = (api chain run $use_order_steps --quiet)
        assert equal ($use_order_run.results | get status) [200 200 200 200 200]
        assert equal ((request-body-event $server "/use-self-extension").body | from json | get value) "beta-c/extra" "Same-name use binding did not extend the prior trusted value"
        let use_order_body = (request-body-event $server "/use-order").body | from json
        assert equal $use_order_body.shown "beta-c" "Earlier use binding did not see the prior trusted value"
        assert equal $use_order_body.current "override" "Later use binding did not override for the request"
        let dynamic_use_body = (request-body-event $server "/use-dynamic").body | from json
        assert equal $dynamic_use_body.first $dynamic_use_body.second "Dynamic trusted value was re-evaluated per use binding"
        assert equal (request-body-event $server "/use-shadow-cycle/override").body "shadow" "Use override did not shadow an unused trusted cycle"
        let forward_body = (request-body-event $server "/use-forward-order").body | from json
        assert equal $forward_body.global_var "test_value/extra"
        assert equal $forward_body.x "test_value/extra" "Forward use dependency ignored an earlier override"
        assert equal $forward_body.b "test_value/extra"
        let use_order_path = ($root | path join "chains" "use-order.nuon")
        {name: "use-order", steps: $use_order_steps} | to nuon --indent 4 | save -f $use_order_path
        let use_order_exec = (api chain exec use-order --quiet)
        assert equal ($use_order_exec.results | get status) [200 200 200 200 200]
        assert equal (request-body-events $server | where path == "/use-self-extension" | length) 2
        assert equal (request-body-events $server | where path == "/use-order" | length) 2
        assert equal (request-body-events $server | where path == "/use-dynamic" | length) 2
        assert equal (request-body-events $server | where path == "/use-shadow-cycle/override" | length) 2
        assert equal (request-body-events $server | where path == "/use-forward-order" | length) 2

        api post $"($base)/direct-header" -H {"X-Direct": "{{late}}"} -b {ok: true} --raw --no-history | ignore
        assert equal ((request-body-event $server "/direct-header").headers | where name == "X-Direct" | first | get value) "GLOBALLEAK" "Ordinary request header interpolation changed"
        assert equal (api vars interpolate "{{late}}/{{late}}") "GLOBALLEAK/GLOBALLEAK" "Repeated placeholders were not all restored"
        assert equal (
            api vars interpolate "{{outer}}" -e {outer: "{{inner}}", inner: resolved}
        ) "resolved" "Ordinary recursive interpolation changed"
        let cycle = try {
            api vars interpolate "{{a}}" -e {a: "{{a}}x"} | ignore
            null
        } catch {|error| $error}
        assert ($cycle != null) "Self-referential interpolation unexpectedly succeeded"
        assert ($cycle.msg | str contains "exceeded 32 expansion steps") "Self-referential interpolation error was not actionable"
        null
    } catch {|error| $error}
    try { stop-request-body-server $server } catch {}
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
}

def test-request-body-interpolated-header-safety [] {
    let root = (make-temp-dir "request-body-header-safety")
    let infra = (make-temp-dir "request-body-header-safety-server")
    let server = (start-request-body-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let base = $"http://127.0.0.1:($server.port)"
        api vars set bad_header "X-Good\r\nX-Evil" | ignore
        api post $"($base)/literal-header-name" -H {"{{bad_header}}": value} -b {ok: true} --raw --no-history | ignore
        let literal_event = (request-body-event $server "/literal-header-name")
        assert equal ($literal_event.headers | where name == "{{bad_header}}" | first | get value) "value" "Header name variable did not remain literal"
        assert equal ($literal_event.headers | where name == "X-Good" | length) 0 "CR/LF entered a header name through variable expansion"
        assert equal ($literal_event.headers | where name == "X-Evil" | length) 0 "Header-name variable injected a second header"

        api vars set bad_value "safe\r\nX-Evil: injected" | ignore
        let before_value = (request-body-events $server | length)
        let invalid_value = try {
            api post $"($base)/invalid-header-value" -H {"X-Good": "{{bad_value}}"} -b {ok: true} --raw --no-history | ignore
            null
        } catch {|error| $error}
        assert ($invalid_value != null) "Interpolated CR/LF header value unexpectedly succeeded"
        assert ($invalid_value.msg | str contains "Request header 'X-Good' must not contain carriage returns or newlines") "Interpolated header-value error was not actionable"
        assert equal (request-body-events $server | length) $before_value "Invalid interpolated header value reached the endpoint"

        let before_auth = (request-body-events $server | length)
        let invalid_auth = try {
            api post $"($base)/invalid-auth-value" -a {type: bearer, token: "safe\r\nX-Evil: injected"} -b {ok: true} --raw --no-history | ignore
            null
        } catch {|error| $error}
        assert ($invalid_auth != null) "CR/LF auth-generated header unexpectedly succeeded"
        assert ($invalid_auth.msg | str contains "Request header 'Authorization' must not contain carriage returns or newlines") "Auth-generated header error was not actionable"
        assert equal (request-body-events $server | length) $before_auth "Invalid auth-generated header reached the endpoint"

        let invalid_preview_auth = try {
            api post $"($base)/invalid-preview-auth" -a {type: api_key, key: secret, header: "X-Good\r\nX-Evil"} -b {ok: true} --dry-run | ignore
            null
        } catch {|error| $error}
        assert ($invalid_preview_auth != null) "Dry-run CR/LF auth header name unexpectedly succeeded"
        assert ($invalid_preview_auth.msg | str contains "Request header names must not contain carriage returns or newlines") "Dry-run auth header error was not actionable"

        let before_collision = (request-body-events $server | length)
        let collision = try {
            api post $"($base)/header-collision" -H {"X-Same": first, "x-same": second} -b {ok: true} --raw --no-history | ignore
            null
        } catch {|error| $error}
        assert ($collision != null) "Interpolated header-name collision unexpectedly succeeded"
        assert ($collision.msg | str contains "contains both 'X-Same' and 'x-same'") "Header collision did not use the dedicated request-header error"
        assert equal (request-body-events $server | length) $before_collision "Header collision reached the endpoint"

        api vars set header_cycle "{{header_cycle}}" | ignore
        let config_path = ($root | path join "config.nuon")
        open $config_path
        | update default_headers {"X-Cycle": "{{header_cycle}}"}
        | to nuon --indent 4
        | save -f $config_path
        api post $"($base)/override-cyclic-default" -H {"x-cycle": fixed} -b {ok: true} --raw --no-history | ignore
        assert equal (
            request-body-event $server "/override-cyclic-default" | get headers | where name == "x-cycle" | first | get value
        ) "fixed" "Overridden cyclic default header was still resolved"
        let chain_override = (api chain run ([{
            method: POST
            url: $"($base)/chain-override-cyclic-default"
            headers: {"x-cycle": fixed}
            body: {content: {ok: true}}
        }]) --quiet)
        assert equal $chain_override.success true "Chain resolved an overridden cyclic default header"
        assert equal (
            request-body-event $server "/chain-override-cyclic-default" | get headers | where name == "x-cycle" | first | get value
        ) "fixed"
        null
    } catch {|error| $error}
    try { stop-request-body-server $server } catch {}
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
}

def run-suite-request-body []: nothing -> list<record> {
    [
        (run-test "request body: JSON interpolation precedes serialization" { test-request-body-json-boundary })
        (run-test "request body: form interpolation precedes URL encoding" { test-request-body-form-boundary })
        (run-test "request body: tables survive vars, history, and chain flows" { test-request-body-table-flows })
        (run-test "request body: chain headers and bodies interpolate once" { test-request-body-chain-single-pass })
        (run-test "request body: interpolated header names fail safely" { test-request-body-interpolated-header-safety })
        (run-test "request body: preview, history, and masking stay coherent" { test-request-body-preview-history-and-masking })
    ]
}

def run-suite-request-body-compat []: nothing -> list<record> {
    run-suite-request-body
}
