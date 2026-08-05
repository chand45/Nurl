# RFC 9110 request-header identity and curl preview fidelity regressions.

def request-header-python [] {
    if not (which python | is-empty) {
        "python"
    } else if not (which python3 | is-empty) {
        "python3"
    } else {
        error make {msg: "Python is required for the request-header echo server"}
    }
}

def request-header-process-running [pid: int] {
    try {
        (ps | where pid == $pid | length) > 0
    } catch {
        false
    }
}

def start-request-header-server [tmp: string] {
    let python = (request-header-python)
    let server_script = ($tmp | path join "header-server.py")
    let launcher_script = ($tmp | path join "header-launcher.py")
    let port_file = ($tmp | path join "header-port.txt")
    let event_file = ($tmp | path join "header-events.jsonl")
    let token_count_file = ($tmp | path join "header-token-count.txt")
    let stop_file = ($tmp | path join "header-stop.txt")
    let server_source = "import http.server
import json
import os
import sys
import time

port_file, event_file, token_count_file, stop_file = sys.argv[1:5]
token_count = 0

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def emit(self, payload, status=200, head=False, headers=None):
        encoded = json.dumps(payload, separators=(',', ':')).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(encoded)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if not head:
            self.wfile.write(encoded)

    def handle_request(self, head=False):
        global token_count
        if self.path == '/ready':
            self.emit({'ready': True}, head=head)
            return
        length = int(self.headers.get('Content-Length', '0'))
        body_bytes = self.rfile.read(length) if length else b''
        raw_headers = [
            {'name': name, 'value': value}
            for name, value in self.headers.raw_items()
        ]
        event = {
            'method': self.command,
            'path': self.path,
            'headers': raw_headers,
            'body': body_bytes.decode('utf-8'),
        }
        with open(event_file, 'a', encoding='utf-8') as handle:
            handle.write(json.dumps(event, separators=(',', ':')) + '\\n')
        if self.path == '/redirect':
            self.emit({'redirect': True}, status=302, head=head, headers={'Location': '/redirect-final'})
            return
        if self.path.startswith('/token'):
            token_count += 1
            with open(token_count_file, 'w', encoding='utf-8') as handle:
                handle.write(str(token_count))
            self.emit({
                'access_token': 'REQUEST-HEADER-OAUTH-TOKEN-SENTINEL',
                'token_type': 'Bearer',
                'expires_in': 3600,
            }, head=head)
            return
        self.emit(event, status=(204 if self.command == 'OPTIONS' else 200), head=head)

    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()

    def do_PUT(self):
        self.handle_request()

    def do_PATCH(self):
        self.handle_request()

    def do_DELETE(self):
        self.handle_request()

    def do_HEAD(self):
        self.handle_request(head=True)

    def do_OPTIONS(self):
        self.handle_request()

server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
server.timeout = 0.1
with open(port_file, 'w', encoding='utf-8') as handle:
    handle.write(str(server.server_port))
with open(event_file, 'w', encoding='utf-8') as handle:
    handle.write('')
with open(token_count_file, 'w', encoding='utf-8') as handle:
    handle.write('0')
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
        ^$python $launcher_script $python $server_script $port_file $event_file $token_count_file $stop_file
    } | complete))
    assert equal $launched.exit_code 0 $"Request-header server launcher failed: ($launched.stderr)"
    let server_base = {
        pid: ($launched.stdout | str trim | into int)
        port: 0
        port_file: $port_file
        event_file: $event_file
        token_count_file: $token_count_file
        stop_file: $stop_file
        python: $python
    }
    for _ in 1..100 {
        if ($port_file | path exists) and (request-header-process-running $server_base.pid) {
            break
        }
        sleep 50ms
    }
    assert ($port_file | path exists) "Request-header server did not publish its port"
    let server = ($server_base | update port (open $port_file --raw | str trim | into int))
    let ready_url = $"http://127.0.0.1:($server.port)/ready"
    let ready = (test-complete-result (do {
        ^curl -s --max-time 2 $ready_url
    } | complete))
    assert equal $ready.exit_code 0 $"Request-header server readiness failed: ($ready.stderr)"
    $server
}

def stop-request-header-server [server: record] {
    "" | save -f $server.stop_file
    for _ in 1..100 {
        if not (request-header-process-running $server.pid) {
            break
        }
        sleep 50ms
    }
    if (request-header-process-running $server.pid) {
        if $nu.os-info.name == "windows" {
            ^powershell.exe -NoProfile -NonInteractive -Command $"Stop-Process -Id ($server.pid) -Force" | ignore
        } else {
            ^kill -TERM $server.pid | ignore
        }
    }
    assert (not (request-header-process-running $server.pid)) $"Request-header server PID ($server.pid) did not stop"
}

def request-header-events [server: record] {
    if not ($server.event_file | path exists) {
        return []
    }
    open $server.event_file --raw
    | lines
    | where {|line| not ($line | is-empty) }
    | each {|line| $line | from json }
}

def request-header-token-count [server: record] {
    open $server.token_count_file --raw | str trim | into int
}

def request-header-event [server: record, path: string] {
    let matches = (request-header-events $server | where path == $path)
    assert (not ($matches | is-empty)) $"No request reached ($path)"
    $matches | last
}

def request-header-fold [name: string] {
    $name | str upcase
}

def request-header-values [event: record, folded: string] {
    $event.headers | where {|header| (request-header-fold $header.name) == $folded }
}

def assert-request-header-event [event: record, expected_content_type: string = "application/xml"] {
    let content_type = (request-header-values $event "CONTENT-TYPE")
    let accept = (request-header-values $event "ACCEPT")
    let keep = (request-header-values $event "X-KEEP")
    assert equal ($content_type | length) 1 "wire contained duplicate Content-Type variants"
    assert equal ($accept | length) 1 "wire contained duplicate Accept variants"
    assert equal ($keep | length) 1 "wire lost X-Keep"
    assert equal ($content_type | first | get value) $expected_content_type
    assert equal ($accept | first | get value) "text/csv"
    assert equal ($keep | first | get value) "exact"
}

def assert-unique-request-header-record [headers: record] {
    let folded = ($headers | columns | each {|name| request-header-fold $name })
    assert equal ($folded | uniq | length) ($folded | length) "record contained duplicate-case header names"
}

def request-header-history-ids [root: string] {
    let index = ($root | path join "history" "index.nuon")
    if ($index | path exists) {
        try { open $index | get id } catch { [] }
    } else {
        []
    }
}

def request-header-new-history-id [root: string, before: list] {
    let added = (request-header-history-ids $root | where {|id| $id not-in $before })
    assert equal ($added | length) 1 "Expected exactly one new history entry"
    $added | first
}

def request-header-files [root: string] {
    if not ($root | path exists) {
        return []
    }
    ls -a $root | each {|entry|
        if $entry.type == "dir" {
            request-header-files $entry.name
        } else {
            [$entry.name]
        }
    } | flatten
}

def request-header-snapshot [root: string] {
    request-header-files $root | each {|path|
        let kind = ($path | path type | default "")
        {
            path: ($path | path relative-to $root | str replace --all "\\" "/")
            type: $kind
            content: (if $kind == "file" { open $path --raw } else { null })
        }
    } | sort-by path
}

def assert-request-header-command-error [
    root: string
    server: record
    command: string
    expected: string
    secrets: list
] {
    let before_state = (request-header-snapshot $root)
    let before_events = (request-header-events $server | length)
    let before_tokens = (request-header-token-count $server)
    let result = (run-command-process $root $command)
    assert ($result.exit_code != 0) $"Header collision unexpectedly succeeded: ($command)"
    assert equal ($result.stdout | str trim) "" "Header collision wrote stdout"
    assert ($result.stderr | str contains $expected) $"Header collision error was not actionable: ($result.stderr)"
    assert equal $result.stderr ($result.stderr | ansi strip) "Header collision error emitted ANSI"
    for secret in $secrets {
        assert (not ($result.stderr | str contains $secret)) "Header collision error exposed a secret"
    }
    assert equal (request-header-events $server | length) $before_events "Header collision reached the network"
    assert equal (request-header-token-count $server) $before_tokens "Header collision acquired an OAuth token"
    assert equal (request-header-snapshot $root) $before_state "Header collision mutated the workspace"
}

def test-request-header-transferring-surfaces [] {
    let root = (make-temp-dir "request-header-surfaces")
    let infra = (make-temp-dir "request-header-surfaces-server")
    let server = (start-request-header-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let base = $"http://127.0.0.1:($server.port)"
        let headers = {"content-type": "application/xml", "accept": "text/csv", "X-Keep": "exact"}

        let get_result = (api get $"($base)/get" -H $headers --raw --no-history)
        api post $"($base)/post" -H $headers --raw --no-history | ignore
        api put $"($base)/put" -H $headers --raw --no-history | ignore
        api patch $"($base)/patch" -H $headers --raw --no-history | ignore
        api delete $"($base)/delete" -H $headers --raw --no-history | ignore
        api head $"($base)/head" -H $headers --raw --no-history | ignore
        api options $"($base)/options" -H $headers --raw --no-history | ignore
        api request -m POST $"($base)/request" -H $headers --raw --no-history | ignore

        api collection create header-surface | ignore
        api request create saved GET $"($base)/send" -H $headers -c header-surface | ignore
        api send saved -c header-surface --raw --no-history | ignore

        let history_before = (request-header-history-ids $root)
        api get $"($base)/history" -H $headers --raw | ignore
        let history_id = (request-header-new-history-id $root $history_before)
        api history resend $history_id --raw | ignore

        api chain run ([{method: GET, url: $"($base)/chain-run", headers: $headers}]) --quiet | ignore
        mkdir ($root | path join "chains")
        {
            name: "header-exec"
            description: ""
            steps: [{method: GET, url: $"($base)/chain-exec", headers: $headers}]
        } | to nuon --indent 4 | save -f ($root | path join "chains" "header-exec.nuon")
        api chain exec header-exec --quiet | ignore

        let binary_path = ($root | path join "header.bin")
        api get $"($base)/binary" -H $headers --binary-save $binary_path --output none --no-history
        assert ($binary_path | path exists) "Binary path was not exercised"

        assert equal ($get_result.request.headers | columns) ["content-type" "accept" "X-Keep"] "Winning spelling or stable position changed"
        assert-unique-request-header-record $get_result.request.headers
        let history_entry = (api history get $history_id)
        assert equal ($history_entry.request.headers | columns) ["content-type" "accept" "X-Keep"]
        assert-unique-request-header-record $history_entry.request.headers
        for history_file in (
            request-header-files ($root | path join "history")
            | where {|path| ($path | path basename) != "index.nuon" }
        ) {
            let stored = (open $history_file)
            if "request" in ($stored | columns) {
                assert-unique-request-header-record $stored.request.headers
            }
        }

        for path in [
            "/get" "/post" "/put" "/patch" "/delete" "/head" "/options" "/request"
            "/send" "/chain-run" "/chain-exec" "/binary"
        ] {
            assert-request-header-event (request-header-event $server $path)
        }
        let replayed = (request-header-events $server | where path == "/history")
        assert equal ($replayed | length) 2 "History resend did not exercise the wire twice"
        for event in $replayed {
            assert-request-header-event $event
        }
        null
    } catch {|error| $error}
    try { stop-request-header-server $server } catch {}
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
}

def test-request-header-precedence-form-and-history [] {
    let root = (make-temp-dir "request-header-precedence")
    let infra = (make-temp-dir "request-header-precedence-server")
    let server = (start-request-header-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let base = $"http://127.0.0.1:($server.port)"
        let default_result = (api get $"($base)/default" --raw --no-history)
        assert equal ($default_result.request.headers | columns) ["Content-Type" "Accept"]

        let before = (request-header-history-ids $root)
        let caller = (api get $"($base)/caller" -H {"content-type": "application/xml", "accept": "text/csv", "X-Keep": "exact"} --raw)
        assert equal ($caller.request.headers | columns) ["content-type" "accept" "X-Keep"]
        assert equal $caller.request.headers.content-type "application/xml"
        assert-request-header-event (request-header-event $server "/caller")
        let entry = (api history get (request-header-new-history-id $root $before))
        assert equal ($entry.request.headers | columns) ["content-type" "accept" "X-Keep"]

        let exact = (api get $"($base)/exact" -H {"Content-Type": "application/xml", "Accept": "text/csv", "X-Keep": "exact"} --raw --no-history)
        assert equal ($exact.request.headers | columns) ["Content-Type" "Accept" "X-Keep"]

        for form_case in [
            {path: "/form-post", method: "post"}
            {path: "/form-put", method: "put"}
            {path: "/form-patch", method: "patch"}
            {path: "/form-request", method: "request"}
        ] {
            let url = $base + $form_case.path
            if $form_case.method == "post" {
                api post $url -F {a: "1"} -H {"content-type": "text/plain", "accept": "text/csv", "X-Keep": "exact"} --raw --no-history | ignore
            } else if $form_case.method == "put" {
                api put $url -F {a: "1"} -H {"content-type": "text/plain", "accept": "text/csv", "X-Keep": "exact"} --raw --no-history | ignore
            } else if $form_case.method == "patch" {
                api patch $url -F {a: "1"} -H {"content-type": "text/plain", "accept": "text/csv", "X-Keep": "exact"} --raw --no-history | ignore
            } else {
                api request -m POST $url -F {a: "1"} -H {"content-type": "text/plain", "accept": "text/csv", "X-Keep": "exact"} --raw --no-history | ignore
            }
            let event = (request-header-event $server $form_case.path)
            assert-request-header-event $event "application/x-www-form-urlencoded"
            assert equal (request-header-values $event "CONTENT-TYPE" | first | get name) "Content-Type"
        }
        null
    } catch {|error| $error}
    try { stop-request-header-server $server } catch {}
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
}

def test-request-header-auth-collisions [] {
    let root = (make-temp-dir "request-header-auth")
    let infra = (make-temp-dir "request-header-auth-server")
    let server = (start-request-header-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let base = $"http://127.0.0.1:($server.port)"
        api auth bearer set header-bearer "NAMED-BEARER-SECRET" | ignore
        api auth basic set header-basic user "NAMED-BASIC-SECRET" | ignore
        api auth apikey set header-key "NAMED-APIKEY-SECRET" --header "X-Api-Key" | ignore
        api auth oauth2 configure header-oauth --client-id client --client-secret "OAUTH-CLIENT-SECRET" --token-url $"($base)/token" | ignore

        let cases = [
            {label: "bearer-inline", auth: {type: bearer, token: "INLINE-BEARER-SECRET"}, header: "Authorization", secret: "INLINE-BEARER-SECRET"}
            {label: "bearer-ref", auth: {type: bearer, ref: header-bearer}, header: "authorization", secret: "NAMED-BEARER-SECRET"}
            {label: "saml", auth: {type: saml, token: "SAML-SECRET"}, header: "AUTHORIZATION", secret: "SAML-SECRET"}
            {label: "basic-inline", auth: {type: basic, username: user, password: "INLINE-BASIC-SECRET"}, header: "Authorization", secret: "INLINE-BASIC-SECRET"}
            {label: "basic-ref", auth: {type: basic, ref: header-basic}, header: "authorization", secret: "NAMED-BASIC-SECRET"}
            {label: "oauth2", auth: {type: oauth2, ref: header-oauth}, header: "AUTHORIZATION", secret: "OAUTH-CLIENT-SECRET"}
            {label: "apikey-ref", auth: {type: api_key, ref: header-key}, header: "x-api-key", secret: "NAMED-APIKEY-SECRET"}
            {label: "apikey-inline", auth: {type: api_key, key: "INLINE-APIKEY-SECRET", header: "X-Api-Key"}, header: "X-API-KEY", secret: "INLINE-APIKEY-SECRET"}
        ]
        for case in $cases {
            let spellings = if (request-header-fold $case.header) == "AUTHORIZATION" {
                ["Authorization" "authorization" "AUTHORIZATION"]
            } else {
                ["X-Api-Key" "x-api-key" "X-API-KEY"]
            }
            for spelling in ($spellings | enumerate) {
                let instance = $"($case.label)-($spelling.index)"
                let text_path = ($root | path join $"($instance).txt")
                let binary_path = ($root | path join $"($instance).bin")
                let supplied = {$spelling.item: "CALLER-AUTH-VALUE"}
                let command = (
                    "api get " + (($base + "/" + $instance) | to nuon)
                    + " --auth " + ($case.auth | to nuon)
                    + " --headers " + ($supplied | to nuon)
                    + " --save " + ($text_path | to nuon)
                    + " --binary-save " + ($binary_path | to nuon)
                    + " --output none"
                )
                assert-request-header-command-error $root $server $command "Request supplies both --auth and an" [$case.secret "CALLER-AUTH-VALUE" "REQUEST-HEADER-OAUTH-TOKEN-SENTINEL"]
                assert (not ($text_path | path exists)) "Auth collision created a text output file"
                assert (not ($binary_path | path exists)) "Auth collision created a binary output file"
            }
        }

        api collection create auth-collision | ignore
        api request create conflict GET $"($base)/send-conflict" -c auth-collision -H {authorization: "CALLER"} -a {type: bearer, ref: header-bearer} | ignore
        assert-request-header-command-error $root $server "api send conflict -c auth-collision --output none" "Request supplies both --auth and an 'Authorization' header" ["NAMED-BEARER-SECRET" "CALLER"]

        assert-request-header-command-error $root $server (
            "api request -m GET " + (($base + "/request-conflict") | to nuon)
            + " -H {authorization: CALLER} -a {type: bearer, ref: header-bearer} --output none"
        ) "Request supplies both --auth and an 'Authorization' header" ["NAMED-BEARER-SECRET" "CALLER"]

        assert-request-header-command-error $root $server (
            "api chain run ([{method: GET, url: " + (($base + "/chain-conflict") | to nuon)
            + ", headers: {authorization: CALLER}, auth: {type: bearer, ref: header-bearer}}]) --quiet"
        ) "Request supplies both --auth and an 'Authorization' header" ["NAMED-BEARER-SECRET" "CALLER"]

        let auth_history_id = "20260102-000000-000000000-authcollision"
        let auth_history_dir = ($root | path join "history" "2026-01-02")
        mkdir $auth_history_dir
        {
            id: $auth_history_id
            timestamp: "2026-01-02T00:00:00.000000000Z"
            environment: null
            request: {
                method: "GET"
                url: $"($base)/history-auth-conflict"
                headers: {authorization: "CALLER"}
                body: null
                auth: {type: bearer, ref: header-bearer, replayable: true}
            }
            response: {
                status: 200
                status_text: "OK"
                headers: {}
                body: null
                time_ms: 1
                size_bytes: 0
            }
        } | to nuon --indent 4 | save -f ($auth_history_dir | path join $"($auth_history_id).nuon")
        api history rebuild-index | ignore
        assert-request-header-command-error $root $server (
            "api history resend " + $auth_history_id + " --raw"
        ) "Request supplies both --auth and an 'Authorization' header" ["NAMED-BEARER-SECRET" "CALLER"]

        let query_result = (api get $"($base)/query-control" -H {Authorization: "Custom value"} -a {type: api_key, key: "QUERY-KEY-SECRET", query: "api_key"} --raw --no-history)
        assert equal $query_result.response.status 200 "API-key query auth was treated as a header conflict"
        let query_event = (request-header-event $server "/query-control?api_key=QUERY-KEY-SECRET")
        assert equal (request-header-values $query_event "AUTHORIZATION" | length) 1

        let explicit_result = (api get $"($base)/explicit-control" -H {authorization: "Custom value"} --raw --no-history)
        assert equal $explicit_result.request.headers.authorization "******"
        assert equal (request-header-values (request-header-event $server "/explicit-control") "AUTHORIZATION" | length) 1
        null
    } catch {|error| $error}
    try { stop-request-header-server $server } catch {}
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
}

def write-legacy-request-header-history [root: string, base: string] {
    let id = "20260101-000000-000000000-headerlegacy"
    let date_dir = ($root | path join "history" "2026-01-01")
    mkdir $date_dir
    let path = ($date_dir | path join $"($id).nuon")
    {
        id: $id
        timestamp: "2026-01-01T00:00:00.000000000Z"
        environment: null
        request: {
            method: "GET"
            url: $"($base)/legacy-history"
            headers: {"Accept": "application/json", "accept": "text/csv"}
            body: null
        }
        response: {
            status: 200
            status_text: "OK"
            headers: {}
            body: null
            time_ms: 1
            size_bytes: 0
        }
    } | to nuon --indent 4 | save -f $path
    {id: $id, path: $path, bytes: (open $path --raw)}
}

def test-request-header-ambiguous-records-and-legacy-history [] {
    let root = (make-temp-dir "request-header-ambiguous")
    let infra = (make-temp-dir "request-header-ambiguous-server")
    let server = (start-request-header-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let base = $"http://127.0.0.1:($server.port)"

        assert-request-header-command-error $root $server (
            "api get " + (($base + "/direct-ambiguous") | to nuon)
            + " -H {'Accept': a, 'accept': b} --output none"
        ) "Request header record contains both 'Accept' and 'accept'; remove one." []

        let config_path = ($root | path join "config.nuon")
        let original_config = (open $config_path --raw)
        open $config_path
        | upsert default_headers {"Accept": "a", "accept": "b"}
        | to nuon --indent 4
        | save -f $config_path
        assert-request-header-command-error $root $server (
            "api get " + (($base + "/config-ambiguous") | to nuon) + " --output none"
        ) "Request header record contains both 'Accept' and 'accept'; remove one." []
        $original_config | save -f $config_path

        api collection create ambiguous | ignore
        let request_path = ($root | path join "collections" "ambiguous" "requests" "saved.nuon")
        {
            name: "saved"
            collection: "ambiguous"
            method: "GET"
            url: $"($base)/saved-ambiguous"
            headers: {"Accept": "a", "accept": "b"}
            body: null
            auth: null
        } | to nuon --indent 4 | save -f $request_path
        assert-request-header-command-error $root $server "api send saved -c ambiguous --output none" "Request header record contains both 'Accept' and 'accept'; remove one." []

        assert-request-header-command-error $root $server (
            "api chain run ([{method: GET, url: " + (($base + "/chain-ambiguous") | to nuon)
            + ", headers: {'Accept': a, 'accept': b}}]) --quiet"
        ) "Request header record contains both 'Accept' and 'accept'; remove one." []

        let legacy = (write-legacy-request-header-history $root $base)
        api history rebuild-index | ignore
        assert equal (api history list --limit 10 | where id == $legacy.id | length) 1
        assert equal (api history show $legacy.id).id $legacy.id
        assert equal (api history get $legacy.id).id $legacy.id
        assert equal (api history search "legacy-history" | first | get id) $legacy.id
        let export_result = (run-command-process $root "api history export --format json")
        assert equal $export_result.exit_code 0 $"Legacy history export failed: ($export_result.stderr)"
        let exported = ($export_result.stdout | from json)
        assert equal ($exported | where id == $legacy.id | length) 1
        assert equal (open $legacy.path --raw) $legacy.bytes "Legacy history was migrated during reads"

        assert-request-header-command-error $root $server (
            "api history resend " + $legacy.id + " --raw"
        ) "pass --headers to replace them before resending" []
        assert equal (open $legacy.path --raw) $legacy.bytes "Failed resend migrated legacy history"
        api history resend $legacy.id --headers {Accept: "text/csv"} --raw | ignore
        assert equal (request-header-values (request-header-event $server "/legacy-history") "ACCEPT" | length) 1
        null
    } catch {|error| $error}
    try { stop-request-header-server $server } catch {}
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
}

def request-header-preview-rendering [server: record, line: string, tmp: string] {
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

def assert-request-header-preview-case [
    root: string
    server: record
    tmp: string
    label: string
    command: string
    expected_body?: string
] {
    let before = (request-header-events $server | length)
    let preview = (run-command-process $root ($command + " --dry-run"))
    assert equal $preview.exit_code 0 $"($label) preview failed: ($preview.stderr)"
    assert equal ($preview.stderr | str trim) ""
    let line = ($preview.stdout | str trim)
    assert ($line | str starts-with "curl ") $"($label) did not emit curl"
    let rendering = (request-header-preview-rendering $server $line $tmp)
    assert equal $line $rendering.canonical $"($label) used non-canonical or unsafe shell rendering"
    let replay = if $nu.os-info.name == "windows" {
        test-complete-result (do { ^curl ...$rendering.args } | complete)
    } else {
        test-complete-result (do {
            cd $tmp
            ^sh -c $line
        } | complete)
    }
    assert equal $replay.exit_code 0 $"($label) preview curl failed: ($replay.stderr)"
    let execution = (run-command-process $root $command)
    assert equal $execution.exit_code 0 $"($label) execution failed: ($execution.stderr)"
    let events = (request-header-events $server | skip $before)
    assert equal ($events | length) 2 $"($label) did not produce preview and execution requests"
    let preview_event = ($events | first)
    let wire_event = ($events | last)
    assert equal $preview_event.body $wire_event.body $"($label) preview body differed from execution"
    if $expected_body != null {
        assert ($rendering.args | any {|arg| $arg == "--data-raw" }) $"($label) preview omitted --data-raw"
        assert equal $preview_event.body $expected_body $"($label) preview sent the wrong absolute body"
        assert equal $wire_event.body $expected_body $"($label) execution sent the wrong absolute body"
    }
    for folded in ["CONTENT-TYPE" "ACCEPT" "X-KEEP"] {
        assert equal (request-header-values $preview_event $folded) (request-header-values $wire_event $folded) $"($label) preview headers differed from execution"
    }
}

def test-request-header-preview-fidelity [] {
    let root = (make-temp-dir "request-header-preview")
    let infra = (make-temp-dir "request-header-preview-server")
    let scratch = (make-temp-dir "request-header-preview-scratch")
    let server = (start-request-header-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let base = $"http://127.0.0.1:($server.port)"
        let common = " -H {'content-type': 'application/xml', 'accept': 'text/csv', 'X-Keep': exact} --raw --no-history"
        let body_file = ($root | path join "body.txt")
        "body-file=exact&value=1\nsecond line" | save -f $body_file
        let sentinel_file = ($scratch | path join "literal-body-sentinel.txt")
        let sentinel = "NURL-LOCAL-FILE-CONTENTS-MUST-NOT-BE-SENT"
        $sentinel | save -f $sentinel_file
        let literal_path_body = "@" + $sentinel_file
        let at_body_file = ($root | path join "at-body.txt")
        $literal_path_body | save -f $at_body_file
        "" | save -f ($scratch | path join "match.nurlshell")
        let cases = [
            {label: "record", command: ("api post " + (($base + "/preview-record") | to nuon) + " -b {title: t, n: 1}" + $common)}
            {label: "serialized-json", command: ("api post " + (($base + "/preview-json") | to nuon) + " -b " + ('{"title":"t","n":1}' | to nuon) + $common)}
            {label: "plain", command: ("api post " + (($base + "/preview-plain") | to nuon) + " -b " + ("hello world" | to nuon) + $common)}
            {label: "xml", command: ("api post " + (($base + "/preview-xml") | to nuon) + " -b " + ("<a>1</a>" | to nuon) + $common)}
            {label: "operators", command: ("api post " + (($base + "/preview-operators") | to nuon) + " -b " + ("a|b>c" | to nuon) + $common)}
            {label: "substitution", command: ("api post " + (($base + "/preview-substitution") | to nuon) + " -b " + ('$(printf shell-substitution)' | to nuon) + $common)}
            {label: "glob", command: ("api post " + (($base + "/preview-glob") | to nuon) + " -b " + ("*.nurlshell" | to nuon) + $common)}
            {label: "backslash", command: ("api post " + (($base + "/preview-backslash") | to nuon) + " -b " + ('a\b' | to nuon) + $common)}
            {label: "punctuation", command: ("api post " + (($base + "/preview-punctuation") | to nuon) + " -b " + ("#hash !bang [brackets]" | to nuon) + $common)}
            {label: "quote", command: ("api post " + (($base + "/preview-quote") | to nuon) + " -b " + ("it's exact" | to nuon) + $common)}
            {label: "empty", command: ("api post " + (($base + "/preview-empty") | to nuon) + " -b ''" + $common)}
            {label: "multiline", command: ("api post " + (($base + "/preview-multiline") | to nuon) + " -b " + ("line one\nline two" | to nuon) + $common)}
            {label: "form", command: ("api post " + (($base + "/preview-form") | to nuon) + " -F {a: '1', b: '2'} -H {'content-type': text/plain, 'accept': 'text/csv', 'X-Keep': exact} --raw --no-history")}
            {label: "body-file", command: ("api post " + (($base + "/preview-file") | to nuon) + " --body-file " + ($body_file | to nuon) + $common)}
            {label: "at-literal", command: ("api post " + (($base + "/preview-at-literal") | to nuon) + " -b " + ("@everyone please review" | to nuon) + $common), expected_body: "@everyone please review"}
            {label: "at-existing-path", command: ("api post " + (($base + "/preview-at-path") | to nuon) + " -b " + ($literal_path_body | to nuon) + $common), expected_body: $literal_path_body}
            {label: "at-form", command: ("api post " + (($base + "/preview-at-form") | to nuon) + " -F {'@who': team} -H {'content-type': text/plain, 'accept': 'text/csv', 'X-Keep': exact} --raw --no-history"), expected_body: "@who=team"}
            {label: "at-body-file", command: ("api post " + (($base + "/preview-at-file") | to nuon) + " --body-file " + ($at_body_file | to nuon) + $common), expected_body: $literal_path_body}
        ]
        for case in $cases {
            if ($case.expected_body? | default null) == null {
                assert-request-header-preview-case $root $server $scratch $case.label $case.command
            } else {
                assert-request-header-preview-case $root $server $scratch $case.label $case.command $case.expected_body
            }
        }

        api collection create preview-export | ignore
        let export_cases = [
            {label: "compact-json", body: '{"title":"t","n":1}'}
            {label: "xml", body: "<a>1</a>"}
            {label: "operators", body: "a|b>c $(printf export-substitution)"}
            {label: "glob", body: "*.nurlshell"}
            {label: "quote", body: "it's exact"}
            {label: "multiline", body: "line one\nline two"}
            {label: "at-literal", body: "@everyone please review"}
            {label: "at-existing-path", body: $literal_path_body}
            {label: "at-body-file-content", body: (open $at_body_file --raw)}
        ]
        for case in $export_cases {
            let name = "export-" + $case.label
            let url = $base + "/preview-export-" + $case.label
            api request create $name POST $url -c preview-export -H {"content-type": "application/xml", "accept": "text/csv", "X-Keep": "exact"} | ignore
            let export_path = ($root | path join "collections" "preview-export" "requests" $"($name).nuon")
            open $export_path
            | update body {type: "text", content: $case.body}
            | to nuon --indent 4
            | save -f $export_path

            let before = (request-header-events $server | length)
            let exported = (run-command-process $root $"api request export ($name) -c preview-export")
            assert equal $exported.exit_code 0 $"($case.label) export preview failed: ($exported.stderr)"
            let export_line = ($exported.stdout | str trim)
            let rendering = (request-header-preview-rendering $server $export_line $scratch)
            assert equal $export_line $rendering.canonical $"($case.label) export used unsafe shell rendering"
            assert ($rendering.args | any {|arg| $arg == "--data-raw" }) $"($case.label) export omitted --data-raw"
            let replay = if $nu.os-info.name == "windows" {
                test-complete-result (do { ^curl ...$rendering.args } | complete)
            } else {
                test-complete-result (do {
                    cd $scratch
                    ^sh -c $export_line
                } | complete)
            }
            assert equal $replay.exit_code 0 $"($case.label) exported curl failed: ($replay.stderr)"
            let execution = (run-command-process $root $"api send ($name) -c preview-export --raw --no-history")
            assert equal $execution.exit_code 0 $"($case.label) export source execution failed: ($execution.stderr)"
            let events = (request-header-events $server | skip $before)
            assert equal ($events | length) 2
            let expected_body = ($case.body | to json --raw)
            assert equal ($events | first | get body) $expected_body $"($case.label) export did not preserve api send string serialization"
            assert equal ($events | last | get body) $expected_body $"($case.label) api send string serialization changed"
            for folded in ["CONTENT-TYPE" "ACCEPT" "X-KEEP"] {
                assert equal (request-header-values ($events | first) $folded) (request-header-values ($events | last) $folded)
            }
        }

        let no_redirect_preview = (run-command-process $root ("api get " + (($base + "/redirect") | to nuon) + " --raw --no-history --dry-run"))
        assert equal $no_redirect_preview.exit_code 0 $"Non-redirect preview failed: ($no_redirect_preview.stderr)"
        let no_redirect_rendering = (request-header-preview-rendering $server ($no_redirect_preview.stdout | str trim) $scratch)
        assert not ($no_redirect_rendering.args | any {|arg| $arg == "-L" }) "Preview emitted -L without --follow-redirects"

        let redirect_before = (request-header-events $server | length)
        let redirect_preview = (run-command-process $root ("api get " + (($base + "/redirect") | to nuon) + " -L --raw --no-history --dry-run"))
        assert equal $redirect_preview.exit_code 0 $"Redirect preview failed: ($redirect_preview.stderr)"
        let redirect_rendering = (request-header-preview-rendering $server ($redirect_preview.stdout | str trim) $scratch)
        assert ($redirect_rendering.args | any {|arg| $arg == "-L" }) "Redirect preview omitted -L"
        let redirect_replay = (test-complete-result (do { ^curl ...$redirect_rendering.args } | complete))
        assert equal $redirect_replay.exit_code 0 $"Redirect preview replay failed: ($redirect_replay.stderr)"
        let redirect_execution = (run-command-process $root ("api get " + (($base + "/redirect") | to nuon) + " -L --raw --no-history"))
        assert equal $redirect_execution.exit_code 0 $"Redirect execution failed: ($redirect_execution.stderr)"
        let redirect_paths = (request-header-events $server | skip $redirect_before | get path)
        assert equal $redirect_paths ["/redirect" "/redirect-final" "/redirect" "/redirect-final"] "Preview replay and execution did not follow the same redirect"

        let ordered_preview = (run-command-process $root (
            "api post " + (($base + "/redirect") | to nuon)
            + " -b " + ("@ordering" | to nuon) + " -L --raw --no-history --dry-run"
        ))
        assert equal $ordered_preview.exit_code 0 $"Ordered preview failed: ($ordered_preview.stderr)"
        let ordered_args = (request-header-preview-rendering $server ($ordered_preview.stdout | str trim) $scratch | get args)
        let data_position = ($ordered_args | enumerate | where item == "--data-raw" | first | get index)
        let redirect_position = ($ordered_args | enumerate | where item == "-L" | first | get index)
        assert ($data_position < $redirect_position) "Preview placed -L before --data-raw"

        let head_before = (request-header-events $server | length)
        let head_preview = (run-command-process $root ("api head " + (($base + "/preview-head") | to nuon) + " --raw --no-history --dry-run"))
        assert equal $head_preview.exit_code 0 $"HEAD preview failed: ($head_preview.stderr)"
        let head_rendering = (request-header-preview-rendering $server ($head_preview.stdout | str trim) $scratch)
        assert ($head_rendering.args | any {|arg| $arg == "--head" }) "HEAD preview omitted --head"
        assert not (
            $head_rendering.args
            | window 2
            | any {|pair| ($pair | first) == "-X" and ($pair | last) == "HEAD" }
        ) "HEAD preview emitted -X HEAD"
        let head_replay = (test-complete-result (do { ^curl ...$head_rendering.args } | complete))
        assert equal $head_replay.exit_code 0 $"HEAD preview replay failed: ($head_replay.stderr)"
        let head_execution = (run-command-process $root ("api head " + (($base + "/preview-head") | to nuon) + " --raw --no-history"))
        assert equal $head_execution.exit_code 0 $"HEAD execution failed: ($head_execution.stderr)"
        let head_events = (request-header-events $server | skip $head_before)
        assert equal ($head_events | length) 2 "HEAD preview replay and execution did not both reach the endpoint"
        assert ($head_events | all {|event| $event.method == "HEAD" and $event.path == "/preview-head" }) "HEAD preview replay and execution diverged"

        let module_files = (
            ls ($env.NURL_REPO_ROOT | path join "nu_modules")
            | where type == file
            | where name =~ '\.nu$'
            | get name
        )
        let bare_data_flags = ($module_files | where {|path| open $path --raw | str contains '["-d"' })
        assert equal ($bare_data_flags | length) 0 "A bare curl -d body argument remains in nu_modules"
        null
    } catch {|error| $error}
    try { stop-request-header-server $server } catch {}
    cleanup $root
    cleanup $infra
    cleanup $scratch
    if $failure != null { error make {msg: $failure.msg} }
}

def test-request-header-compatibility-subset [] {
    let root = (make-temp-dir "request-header-compat")
    let infra = (make-temp-dir "request-header-compat-server")
    let scratch = (make-temp-dir "request-header-compat-scratch")
    let server = (start-request-header-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let base = $"http://127.0.0.1:($server.port)"
        api get $"($base)/compat-dedup" -H {"content-type": "application/xml", "accept": "text/csv", "X-Keep": "exact"} --raw --no-history | ignore
        assert-request-header-event (request-header-event $server "/compat-dedup")

        api post $"($base)/compat-form" -F {a: "1"} -H {"content-type": "text/plain", "accept": "text/csv", "X-Keep": "exact"} --raw --no-history | ignore
        assert-request-header-event (request-header-event $server "/compat-form") "application/x-www-form-urlencoded"

        assert-request-header-command-error $root $server (
            "api get " + (($base + "/compat-auth") | to nuon)
            + " -H {authorization: caller} -a {type: bearer, token: COMPAT-SECRET} --output none"
        ) "Request supplies both --auth and an 'Authorization' header" ["COMPAT-SECRET" "caller"]

        assert-request-header-preview-case $root $server $scratch "compat-preview" (
            "api post " + (($base + "/compat-preview") | to nuon)
            + " -b " + ("plain body" | to nuon)
            + " -H {'content-type': 'application/xml', 'accept': 'text/csv', 'X-Keep': exact} --raw --no-history"
        )
        let sentinel_file = ($scratch | path join "compat-sentinel.txt")
        "COMPAT-SENTINEL-MUST-NOT-BE-SENT" | save -f $sentinel_file
        let literal_path_body = "@" + $sentinel_file
        let body_file = ($scratch | path join "compat-body.txt")
        $literal_path_body | save -f $body_file
        assert-request-header-preview-case $root $server $scratch "compat-at-literal" (
            "api post " + (($base + "/compat-at-literal") | to nuon)
            + " -b " + ("@everyone please review" | to nuon)
            + " -H {'content-type': 'application/xml', 'accept': 'text/csv', 'X-Keep': exact} --raw --no-history"
        ) "@everyone please review"
        assert-request-header-preview-case $root $server $scratch "compat-at-path" (
            "api post " + (($base + "/compat-at-path") | to nuon)
            + " -b " + ($literal_path_body | to nuon)
            + " -H {'content-type': 'application/xml', 'accept': 'text/csv', 'X-Keep': exact} --raw --no-history"
        ) $literal_path_body
        assert-request-header-preview-case $root $server $scratch "compat-at-body-file" (
            "api post " + (($base + "/compat-at-body-file") | to nuon)
            + " --body-file " + ($body_file | to nuon)
            + " -H {'content-type': 'application/xml', 'accept': 'text/csv', 'X-Keep': exact} --raw --no-history"
        ) $literal_path_body
        null
    } catch {|error| $error}
    try { stop-request-header-server $server } catch {}
    cleanup $root
    cleanup $infra
    cleanup $scratch
    if $failure != null { error make {msg: $failure.msg} }
}

def run-suite-request-headers []: nothing -> list<record> {
    [
        (run-test "request headers: all transferring surfaces deduplicate on wire" { test-request-header-transferring-surfaces })
        (run-test "request headers: precedence, spelling, form, and history stay coherent" { test-request-header-precedence-form-and-history })
        (run-test "request headers: managed auth collisions fail closed" { test-request-header-auth-collisions })
        (run-test "request headers: ambiguous records and legacy history fail safely" { test-request-header-ambiguous-records-and-legacy-history })
        (run-test "request headers: preview and export match execution" { test-request-header-preview-fidelity })
    ]
}

def run-suite-request-headers-compat []: nothing -> list<record> {
    [
        (run-test "request headers: Nushell 0.89 compatibility subset" { test-request-header-compatibility-subset })
    ]
}
