# Hermetic redirect method, body, timeout, output, and credential-boundary regressions.

use ../nu_modules/string-compat.nu [ascii-upcase]

def redirect-python [] {
    if not (which python | is-empty) {
        "python"
    } else if not (which python3 | is-empty) {
        "python3"
    } else {
        error make {msg: "Python is required for redirect tests"}
    }
}

def redirect-process-running [pid: int] {
    try { (ps | where pid == $pid | length) > 0 } catch { false }
}

def redirect-startup-output [path: string] {
    if not ($path | path exists) {
        return ""
    }
    try { open $path --raw | str trim } catch { "" }
}

def redirect-startup-ports [path: string] {
    if not ($path | path exists) {
        return {ready: false, ports: {}}
    }
    let parsed = try {
        {value: (open $path), error: null}
    } catch {
        {value: null, error: true}
    }
    if $parsed.error != null or (not (($parsed.value | describe) | str starts-with "record")) {
        return {ready: false, ports: {}}
    }
    let a = try { $parsed.value.a? | default 0 | into int } catch { 0 }
    let b = try { $parsed.value.b? | default 0 | into int } catch { 0 }
    let valid = ($a > 0 and $a <= 65535 and $b > 0 and $b <= 65535 and $a != $b)
    {
        ready: $valid
        ports: (if $valid { {a: $a, b: $b} } else { {}})
    }
}

def start-redirect-server [tmp: string] {
    let python = (redirect-python)
    let server_script = ($tmp | path join "redirect-server.py")
    let launcher_script = ($tmp | path join "redirect-launcher.py")
    let ports_file = ($tmp | path join "redirect-ports.json")
    let event_file = ($tmp | path join "redirect-events.jsonl")
    let stop_file = ($tmp | path join "redirect-stop")
    let stdout_file = ($tmp | path join "redirect-server.stdout")
    let stderr_file = ($tmp | path join "redirect-server.stderr")
    let server_source = "import http.server
import json
import os
import sys
import time
import urllib.parse

ports_file, event_file, stop_file = sys.argv[1:4]
counters = {}
servers = {}

def bump(key):
    counters[key] = counters.get(key, 0) + 1
    return counters[key]

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def send_bytes(self, data, status=200, content_type='application/octet-stream'):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(data)

    def redirect(self, status, location=None):
        self.send_response(status)
        if location is not None:
            self.send_header('Location', location)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def handle_request(self):
        parsed = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        label = query.get('case', [''])[0]
        length = int(self.headers.get('Content-Length', '0'))
        body = self.rfile.read(length) if length else b''
        event = {
            'server': self.server.label,
            'method': self.command,
            'path': parsed.path,
            'query': parsed.query,
            'label': label,
            'headers': [{'name': k, 'value': v} for k, v in self.headers.raw_items()],
            'body': body.decode('utf-8'),
        }
        if parsed.path != '/ready':
            with open(event_file, 'a', encoding='utf-8') as handle:
                handle.write(json.dumps(event, separators=(',', ':')) + '\\n')

        if parsed.path == '/ready':
            self.send_bytes(b'{\"ready\":true}', content_type='application/json')
            return
        if parsed.path == '/token':
            self.send_bytes(b'{\"access_token\":\"OAUTH-REDIRECT-SENTINEL\",\"token_type\":\"Bearer\",\"expires_in\":3600}', content_type='application/json')
            return
        if parsed.path.startswith('/r/'):
            _, _, raw_status, target = parsed.path.split('/', 3)
            status = int(raw_status)
            suffix = ('?case=' + urllib.parse.quote(label)) if label else ''
            if target == 'none':
                self.redirect(status)
            elif target == 'same':
                self.redirect(status, '/final' + suffix)
            elif target == 'cross':
                self.redirect(status, 'http://127.0.0.1:%d/final%s' % (servers['b'].server_port, suffix))
            elif target == 'relative':
                self.redirect(status, '../../final' + suffix)
            elif target == 'protocol':
                self.redirect(status, '//127.0.0.1:%d/final%s' % (servers['b'].server_port, suffix))
            elif target == 'absolute':
                self.redirect(status, 'http://127.0.0.1:%d/final%s' % (servers['a'].server_port, suffix))
            elif target == 'bracket':
                self.redirect(status, '/final/[literal]' + suffix)
            elif target == 'file':
                self.redirect(status, 'file:///tmp/nurl-redirect-secret')
            elif target == 'userinfo':
                self.redirect(status, 'http://user:REDIRECT-SECRET@127.0.0.1:%d/final' % servers['b'].server_port)
            elif target == 'credential-query':
                self.redirect(status, '/final?api_key=REDIRECT-QUERY-SECRET')
            elif target == 'inject-quote':
                self.redirect(status, '/final\",\"status\":\"599')
            elif target == 'inject-backslash':
                self.redirect(status, r'/final\\redirect')
            elif target == 'inject-size':
                self.redirect(status, '/final\",\"size_header\":\"9999\",\"size_download\":\"9999')
            elif target == 'bare-quote':
                self.redirect(status, '/final\"')
            else:
                self.redirect(status, '/final' + suffix)
            return
        if parsed.path == '/multi/302-302':
            self.redirect(302, '/multi/302-302-next' + (('?case=' + label) if label else ''))
            return
        if parsed.path == '/multi/302-302-next':
            self.redirect(302, '/final' + (('?case=' + label) if label else ''))
            return
        if parsed.path == '/multi/307-303':
            self.redirect(307, '/multi/307-303-next' + (('?case=' + label) if label else ''))
            return
        if parsed.path == '/multi/307-303-next':
            self.redirect(303, '/final' + (('?case=' + label) if label else ''))
            return
        if parsed.path.startswith('/loop/'):
            index = int(parsed.path.rsplit('/', 1)[1])
            self.redirect(302, '/loop/%d' % (index + 1))
            return
        if parsed.path == '/retry-transport':
            destination = 'http://127.0.0.1:1/final' if bump('retry-transport') == 1 else '/final?case=retry-transport'
            self.redirect(307, destination)
            return
        if parsed.path == '/retry-500':
            bump('retry-source')
            self.redirect(307, '/terminal-500')
            return
        if parsed.path == '/terminal-500':
            if bump('terminal-500') == 1:
                self.send_bytes(b'{\"retry\":true}', status=500, content_type='application/json')
            else:
                self.send_bytes(b'{\"ok\":true}', content_type='application/json')
            return
        if parsed.path == '/slow-start':
            time.sleep(0.12)
            self.redirect(307, '/slow-final')
            return
        if parsed.path == '/slow-final':
            time.sleep(0.12)
            self.send_bytes(b'{\"ok\":true}', content_type='application/json')
            return
        if parsed.path == '/timed-start':
            time.sleep(0.03)
            self.redirect(307, '/timed-final')
            return
        if parsed.path == '/timed-final':
            time.sleep(0.04)
            self.send_bytes(b'123456789', content_type='application/octet-stream')
            return
        if parsed.path == '/binary-start':
            self.redirect(307, '/binary-final')
            return
        if parsed.path == '/binary-final':
            self.send_bytes(b'REDIRECT-BINARY-FINAL')
            return
        payload = json.dumps(event, separators=(',', ':')).encode('utf-8')
        self.send_bytes(payload, content_type='application/json')

    do_GET = handle_request
    do_POST = handle_request
    do_PUT = handle_request
    do_PATCH = handle_request
    do_DELETE = handle_request
    do_HEAD = handle_request
    do_OPTIONS = handle_request

servers['a'] = http.server.HTTPServer(('127.0.0.1', 0), Handler)
servers['b'] = http.server.HTTPServer(('127.0.0.1', 0), Handler)
servers['a'].label = 'a'
servers['b'].label = 'b'
for server in servers.values():
    server.timeout = 0.05
ports_temp = ports_file + '.tmp'
with open(ports_temp, 'w', encoding='utf-8') as handle:
    json.dump({'a': servers['a'].server_port, 'b': servers['b'].server_port}, handle)
    handle.flush()
    os.fsync(handle.fileno())
os.replace(ports_temp, ports_file)
with open(event_file, 'w', encoding='utf-8') as handle:
    handle.write('')
deadline = time.time() + 240
while not os.path.exists(stop_file) and time.time() < deadline:
    servers['a'].handle_request()
    servers['b'].handle_request()
for server in servers.values():
    server.server_close()
"
    let launcher_source = "import os
import subprocess
import sys
stdout_file, stderr_file = sys.argv[1:3]
options = {
    'stdin': subprocess.DEVNULL,
    'stdout': open(stdout_file, 'ab', buffering=0),
    'stderr': open(stderr_file, 'ab', buffering=0),
}
if os.name == 'nt':
    options['creationflags'] = subprocess.CREATE_NO_WINDOW
else:
    options['start_new_session'] = True
process = subprocess.Popen(sys.argv[3:], **options)
print(process.pid)
"
    $server_source | save -f $server_script
    $launcher_source | save -f $launcher_script
    let launched = (test-complete-result (do {
        ^$python $launcher_script $stdout_file $stderr_file $python $server_script $ports_file $event_file $stop_file
    } | complete))
    assert equal $launched.exit_code 0 $"Redirect server launcher failed: ($launched.stderr)"
    let base = {
        pid: ($launched.stdout | str trim | into int)
        ports: {}
        event_file: $event_file
        stop_file: $stop_file
        stdout_file: $stdout_file
        stderr_file: $stderr_file
    }
    mut readiness = {ready: false, ports: {}}
    let startup_deadline = ((date now) + 30sec)
    while (date now) < $startup_deadline {
        if not (redirect-process-running $base.pid) {
            break
        }
        $readiness = (redirect-startup-ports $ports_file)
        if $readiness.ready {
            break
        }
        sleep 100ms
    }
    if not $readiness.ready {
        let running = (redirect-process-running $base.pid)
        let stderr = (redirect-startup-output $stderr_file)
        let reason = if $running {
            "did not publish two valid ports within 30 seconds"
        } else {
            "exited before publishing two valid ports"
        }
        try { stop-redirect-server $base } catch {}
        let detail = if ($stderr | is-empty) { "" } else { $": ($stderr)" }
        error make {msg: $"Redirect server ($reason)($detail)"}
    }
    let server = ($base | update ports $readiness.ports)
    for port in [$server.ports.a $server.ports.b] {
        let ready = (test-complete-result (^curl -s --max-time 2 $"http://127.0.0.1:($port)/ready" | complete))
        assert equal $ready.exit_code 0 $"Redirect server readiness failed: ($ready.stderr)"
    }
    $server
}

def stop-redirect-server [server: record] {
    "" | save -f $server.stop_file
    for _ in 1..100 {
        if not (redirect-process-running $server.pid) { break }
        sleep 50ms
    }
    if (redirect-process-running $server.pid) {
        if $nu.os-info.name == "windows" {
            ^powershell.exe -NoProfile -NonInteractive -Command $"Stop-Process -Id ($server.pid) -Force" | ignore
        } else {
            ^kill -TERM $server.pid | ignore
        }
    }
    assert (not (redirect-process-running $server.pid)) $"Redirect server PID ($server.pid) did not stop"
}

def redirect-events [server: record] {
    open $server.event_file --raw
    | lines
    | where {|line| not ($line | is-empty) }
    | each {|line| $line | from json }
}

def redirect-events-for [server: record, label: string] {
    redirect-events $server | where label == $label
}

def redirect-header-values [event: record, name: string] {
    $event.headers
    | where {|header| ($header.name | ascii-upcase) == ($name | ascii-upcase) }
    | get value
}

def redirect-persisted-text [root: string] {
    if not ($root | path exists) { return "" }
    ls -a $root
    | each {|entry|
        if $entry.type == "dir" {
            redirect-persisted-text $entry.name
        } else {
            try { open $entry.name --raw } catch { "" }
        }
    }
    | str join "\n"
}

def redirect-fixture [prefix: string, test: closure] {
    let root = (make-temp-dir $prefix)
    let infra = (make-temp-dir $"($prefix)-server")
    let server = (start-redirect-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        do $test $root $server
        null
    } catch {|error| $error}
    try { stop-redirect-server $server } catch {}
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
}

def test-redirect-pure-contracts [] {
    assert (same-origin "HTTP://Example.COM/a" "http://example.com:80/b")
    assert (same-origin "https://example.com/a" "https://EXAMPLE.com:443/b")
    assert not (same-origin "http://example.com/a" "https://example.com/a")
    assert not (same-origin "http://example.com:80/a" "http://example.com:81/a")

    let headers = {
        Content-Type: application/json
        content-length: "4"
        Content-Encoding: gzip
        Expect: "100-continue"
        Accept: application/json
        X-Internal-Token: secret
        X-Keep: retained
    }
    for status in [301 302] {
        let post = (redirect-next-request $status POST "http://example.com/a" "http://example.com/b" $headers {kind: text, content: body} {})
        assert equal $post.method GET
        assert equal $post.body.kind none
        assert equal ($post.headers | columns) [Accept X-Internal-Token X-Keep]
        let put = (redirect-next-request $status PUT "http://example.com/a" "http://example.com/b" $headers {kind: text, content: body} {})
        assert equal $put.method PUT
        assert equal $put.body.content body
    }
    let see_other = (redirect-next-request 303 PATCH "http://example.com/a" "http://example.com/b" $headers {kind: text, content: body} {})
    assert equal $see_other.method GET
    assert equal ($see_other.headers | columns) [Accept X-Internal-Token X-Keep]
    let head = (redirect-next-request 303 HEAD "http://example.com/a" "http://example.com/b" $headers {kind: none, content: ""} {})
    assert equal $head.method HEAD
    let cross = (redirect-next-request 307 POST "http://example.com/a" "http://example.com:81/b" $headers {kind: text, content: body} {type: bearer, token: secret})
    assert equal ($cross.headers | columns) [Content-Type content-length Content-Encoding Expect Accept X-Keep]
    assert ($cross.auth | is-empty)
    let downgrade = (redirect-next-request 307 GET "https://example.com/a" "http://example.com/b" {
        X-Hub-Signature: sha1=secret
        X-Amz-Content-Sha256: digest
        X-Internal-Signature: signature
        X-Keep: retained
    } {kind: none, content: ""} {type: bearer, token: secret})
    assert $downgrade.cross_origin
    assert equal $downgrade.headers {X-Keep: retained}
    assert ($downgrade.auth | is-empty)
}

def test-redirect-method-body-matrix [] {
    redirect-fixture "redirect-methods" {|root, server|
        let base = $"http://127.0.0.1:($server.ports.a)"
        for status in [301 302 303 307 308] {
            for method in [POST PUT PATCH DELETE] {
                let label = $"direct-($status)-($method)"
                let url = $"($base)/r/($status)/same?case=($label)"
                if $method == "POST" {
                    api post $url -b $"BODY-($label)" -L --raw --no-history | ignore
                } else if $method == "PUT" {
                    api put $url -b $"BODY-($label)" -L --raw --no-history | ignore
                } else if $method == "PATCH" {
                    api patch $url -b $"BODY-($label)" -L --raw --no-history | ignore
                } else {
                    api delete $url -L --raw --no-history | ignore
                }
                let events = (redirect-events-for $server $label)
                assert equal ($events | length) 2
                let final = ($events | last)
                let drops = (($status in [301 302] and $method == "POST") or $status == 303)
                assert equal $final.method (if $drops { "GET" } else { $method })
                let expected_body = if $method == "DELETE" or $drops { "" } else { $"BODY-($label)" }
                assert equal $final.body $expected_body
            }

            let generic_label = $"generic-($status)"
            api request -m DELETE $"($base)/r/($status)/same?case=($generic_label)" -b $"BODY-($generic_label)" -L --raw --no-history | ignore
            let generic_final = (redirect-events-for $server $generic_label | last)
            assert equal $generic_final.method (if $status == 303 { "GET" } else { "DELETE" })
            assert equal $generic_final.body (if $status == 303 { "" } else { $"BODY-($generic_label)" })
        }

        "FILE-BODY" | save -f ($root | path join "body.txt")
        api put $"($base)/r/307/same?case=body-file" --body-file ($root | path join "body.txt") -L --raw --no-history | ignore
        assert equal (redirect-events-for $server body-file | last | get body) "FILE-BODY"
        api patch $"($base)/r/307/same?case=form" --form {a: "1 2"} -L --raw --no-history | ignore
        assert equal (redirect-events-for $server form | last | get body) "a=1+2"
        let long_body = (0..8200 | each { "x" } | str join)
        api post $"($base)/r/307/same?case=stdin-body" -b $long_body -L --raw --no-history | ignore
        assert equal (redirect-events-for $server stdin-body | get body) [$long_body $long_body]
        api post $"($base)/r/302/same?case=entity-drop" -b body -H {
            Content-Encoding: identity
            Content-Language: en
            Content-Location: /source
            Expect: ""
            X-Keep: retained
        } -L --raw --no-history | ignore
        let dropped = (redirect-events-for $server entity-drop | last)
        for entity in [Content-Type Content-Length Content-Encoding Content-Language Content-Location Transfer-Encoding Expect] {
            assert (redirect-header-values $dropped $entity | is-empty) $"redirect retained dropped entity header: ($entity)"
        }
        assert equal (redirect-header-values $dropped X-Keep) [retained]
        assert (not (redirect-header-values $dropped Accept | is-empty))

        "" | save -f ($root | path join "empty.txt")
        api post $"($base)/r/307/same?case=empty-present" --body-file ($root | path join "empty.txt") -L --raw --no-history | ignore
        let empty_events = (redirect-events-for $server empty-present)
        assert equal ($empty_events | get body) ["" ""]
        assert equal (redirect-header-values ($empty_events | last) Content-Length) ["0"]

        api collection create redirects | ignore
        for status in [301 302 303 307 308] {
            let name = $"saved-($status)"
            api request create $name POST $"($base)/r/($status)/same?case=($name)" --collection redirects --body {saved: true} | ignore
            api send $name --collection redirects -L --raw --no-history | ignore
            let saved = (redirect-events-for $server $name)
            assert equal ($saved | get method) (if $status in [301 302 303] { [POST GET] } else { [POST POST] })
            assert equal (($saved | last | get body) | is-empty) ($status in [301 302 303])
        }

        api post $"($base)/multi/302-302?case=multi-a" -b body -L --raw --no-history | ignore
        assert equal (redirect-events-for $server multi-a | get method) [POST GET GET]
        api post $"($base)/multi/307-303?case=multi-b" -b body -L --raw --no-history | ignore
        let multi_b = (redirect-events-for $server multi-b)
        assert equal ($multi_b | get method) [POST POST GET]
        assert equal ($multi_b | get body) [body body ""]
    }
}

def test-redirect-credential-boundaries [] {
    redirect-fixture "redirect-auth" {|root, server|
        let base = $"http://127.0.0.1:($server.ports.a)"
        api auth bearer set redirect-bearer BEARER-REDIRECT-SENTINEL | ignore
        api auth saml set redirect-saml SAML-REDIRECT-SENTINEL | ignore
        api auth basic set redirect-basic user BASIC-REDIRECT-SENTINEL | ignore
        api auth apikey set redirect-key APIKEY-REDIRECT-SENTINEL --header X-Custom-Key | ignore
        api auth apikey set redirect-query QUERY-REDIRECT-SENTINEL --query api_token | ignore
        api auth oauth2 configure redirect-oauth --client-id client --client-secret OAUTH-CLIENT-SECRET --token-url $"($base)/token" | ignore
        let auth_cases = [
            {name: bearer, auth: {type: bearer, ref: redirect-bearer}, header: Authorization}
            {name: saml, auth: {type: saml, ref: redirect-saml}, header: Authorization}
            {name: basic, auth: {type: basic, ref: redirect-basic}, header: Authorization}
            {name: apikey, auth: {type: api_key, ref: redirect-key}, header: X-Custom-Key}
            {name: oauth, auth: {type: oauth2, ref: redirect-oauth}, header: Authorization}
        ]
        for case in $auth_cases {
            for target in [same cross] {
                let label = $"auth-($case.name)-($target)"
                api get $"($base)/r/307/($target)?case=($label)" --auth $case.auth -L --raw --no-history | ignore
                let final = (redirect-events-for $server $label | last)
                assert equal (redirect-header-values $final $case.header | is-empty) ($target == cross)
                assert equal (redirect-header-values $final X-Keep | is-empty) true
            }
        }
        for target in [same cross] {
            let label = $"query-($target)"
            api get $"($base)/r/307/($target)?case=($label)" --auth {type: api_key, ref: redirect-query} -L --raw --no-history | ignore
            let final = (redirect-events-for $server $label | last)
            assert equal ($final.query | str contains "api_token=") ($target == same)
        }
        for target in [same cross] {
            let label = $"caller-($target)"
            api get $"($base)/r/307/($target)?case=($label)" -H {
                Authorization: "Bearer CALLER-REDIRECT-SENTINEL"
                Cookie: "session=COOKIE-REDIRECT-SENTINEL"
                X-Internal-Token: TOKEN-REDIRECT-SENTINEL
                X-Hub-Signature: HUB-SIGNATURE-SENTINEL
                X-Amz-Content-Sha256: AMZ-SHA-SENTINEL
                X-Internal-Signature: INTERNAL-SIGNATURE-SENTINEL
                X-Keep: KEEP-REDIRECT-SENTINEL
            } -L --raw --no-history | ignore
            let final = (redirect-events-for $server $label | last)
            for sensitive in [
                Authorization
                Cookie
                X-Internal-Token
                X-Hub-Signature
                X-Amz-Content-Sha256
                X-Internal-Signature
            ] {
                assert equal (redirect-header-values $final $sensitive | is-empty) ($target == cross)
            }
            assert equal (redirect-header-values $final X-Keep) [KEEP-REDIRECT-SENTINEL]
        }

        for credentials in [
            {name: ascii, username: "user", password: "p:a ss"}
            {name: utf8, username: "ユーザー", password: "päss:密"}
        ] {
            let expected = $"Basic ($"($credentials.username):($credentials.password)" | encode base64)"
            let direct_label = $"basic-bytes-($credentials.name)"
            api get $"($base)/final?case=($direct_label)" --auth {
                type: basic
                username: $credentials.username
                password: $credentials.password
            } --raw --no-history | ignore
            assert equal (redirect-header-values (redirect-events-for $server $direct_label | last) Authorization) [$expected]
            for status in [301 302 303 307 308] {
                let label = $"basic-($credentials.name)-($status)"
                api get $"($base)/r/($status)/same?case=($label)" --auth {
                    type: basic
                    username: $credentials.username
                    password: $credentials.password
                } -L --raw --no-history | ignore
                assert equal (redirect-header-values (redirect-events-for $server $label | last) Authorization) [$expected]
            }
            let cross_label = $"basic-cross-($credentials.name)"
            api get $"($base)/r/307/cross?case=($cross_label)" --auth {
                type: basic
                username: $credentials.username
                password: $credentials.password
            } -L --raw --no-history | ignore
            assert (redirect-header-values (redirect-events-for $server $cross_label | last) Authorization | is-empty)
        }
        let basic_binary = ($root | path join "basic-binary.bin")
        api get $"($base)/r/307/same?case=basic-binary" --auth {
            type: basic
            username: binary-user
            password: "binary:password"
        } -L --binary-save $basic_binary --output none --no-history
        assert equal (redirect-header-values (redirect-events-for $server basic-binary | last) Authorization) [
            $"Basic ($"binary-user:binary:password" | encode base64)"
        ]
        let basic_preview = (run-command-process $root $"api get (($base + '/final') | to nuon) --auth {type: basic, username: user, password: secret} --dry-run")
        assert equal $basic_preview.exit_code 0
        assert ($basic_preview.stdout | str contains "-u '******:******'")
        assert (not ($basic_preview.stdout | str contains "Basic "))

        let persisted_secret = "CROSS-HISTORY-REDIRECT-SENTINEL"
        let guarded = (run-command-process $root (
            "api get "
            + (($base + "/r/307/cross?case=persisted-boundary") | to nuon)
            + " -H "
            + ({X-Internal-Token: $persisted_secret, X-Keep: retained} | to nuon)
            + " -L --raw"
        ))
        assert equal $guarded.exit_code 0 $"cross-origin history request failed: ($guarded.stderr)"
        assert (not ($guarded.stdout | str contains $persisted_secret))
        assert (not ($guarded.stderr | str contains $persisted_secret))
        let exported = ($root | path join "redirect-history.json")
        api history export --format json --output $exported | ignore
        assert (not ((redirect-persisted-text $root) | str contains $persisted_secret)) "cross-origin credential reached persisted history/export bytes"
    }
}

def test-redirect-safety-limit-and-retries [] {
    redirect-fixture "redirect-safety" {|root, server|
        let base = $"http://127.0.0.1:($server.ports.a)"
        for target in [file userinfo credential-query] {
            let before = (redirect-events $server | length)
            let result = (run-command-process $root $"api get (($base + '/r/302/' + $target) | to nuon) -L --retries 2 --raw --no-history")
            assert ($result.exit_code != 0) $"unsafe redirect target succeeded: ($target)"
            assert equal ($result.stdout | str trim) ""
            assert equal $result.stderr ($result.stderr | ansi strip)
            assert (not ($result.stderr | str contains "REDIRECT-SECRET"))
            assert (not ($result.stderr | str contains "REDIRECT-QUERY-SECRET"))
            let request_count = ((redirect-events $server | length) - $before)
            assert equal $request_count 1 $"fatal redirect refusal was retried: ($target), requests=($request_count)"
        }
        for target in [inject-quote inject-backslash inject-size bare-quote] {
            let before = (redirect-events $server | length)
            let one_hop = (api get $"($base)/r/302/($target)" --retries 1 --raw --no-history)
            assert equal $one_hop.response.status 302 $"metadata injection changed status without follow: ($target)"
            assert equal ((redirect-events $server | length) - $before) 1 $"metadata injection triggered retry: ($target)"
            let followed = (api get $"($base)/r/302/($target)" -L --raw --no-history)
            assert equal $followed.response.status 200 $"escaped redirect target did not follow: ($target)"
            assert equal $followed.request.url $"($base)/r/302/($target)"
        }
        let injected_history = (api get $"($base)/r/302/inject-size" --raw)
        assert equal $injected_history.response.status 302
        assert equal (api history list --limit 1 | first | get status) 302
        let injected_output = (run-command-process $root $"api get (($base + '/r/302/inject-size') | to nuon) --output status --no-history")
        assert equal $injected_output.exit_code 0
        assert equal ($injected_output.stdout | str trim) "302"

        let schemeless_label = "schemeless-cross"
        let schemeless = (api get $"127.0.0.1:($server.ports.a)/r/307/cross?case=($schemeless_label)" -H {
            X-Internal-Token: SCHEMELESS-SECRET
            X-Keep: retained
        } -L --raw --no-history)
        assert equal $schemeless.response.status 200
        let schemeless_final = (redirect-events-for $server $schemeless_label | last)
        assert (redirect-header-values $schemeless_final X-Internal-Token | is-empty)
        assert equal (redirect-header-values $schemeless_final X-Keep) [retained]

        let curl_home = ($root | path join "curl-home")
        mkdir $curl_home
        "location\nlocation-trusted\n" | save -f ($curl_home | path join ".curlrc")
        let config_no_follow = (with-env {CURL_HOME: $curl_home} {
            api get $"($base)/r/302/same?case=curlrc-no-follow" --raw --no-history
        })
        assert equal $config_no_follow.response.status 302
        assert equal (redirect-events-for $server curlrc-no-follow | length) 1
        let config_follow = (with-env {CURL_HOME: $curl_home} {
            api get $"($base)/r/302/cross?case=curlrc-follow" -H {
                X-Internal-Token: CURLRC-SECRET
                X-Keep: retained
            } -L --raw --no-history
        })
        assert equal $config_follow.response.status 200
        let config_final = (redirect-events-for $server curlrc-follow | last)
        assert (redirect-header-values $config_final X-Internal-Token | is-empty)
        assert equal (redirect-header-values $config_final X-Keep) [retained]
        let preview = (run-command-process $root $"api get (($base + '/r/302/same') | to nuon) -L --dry-run")
        assert equal $preview.exit_code 0
        assert (($preview.stdout | str trim) | str starts-with "curl -q ")

        let loop_before = (redirect-events $server | length)
        let loop = (run-command-process $root $"api get (($base + '/loop/1') | to nuon) -L --retries 2 --raw --no-history")
        assert ($loop.exit_code != 0)
        assert ($loop.stderr | str contains "50 requests")
        assert equal ((redirect-events $server | length) - $loop_before) 50

        let transport = (api get $"($base)/retry-transport" -L --retries 1 --raw --no-history)
        assert equal $transport.response.status 200
        assert equal (redirect-events $server | where path == /retry-transport | length) 2

        let retried_5xx = (api get $"($base)/retry-500" -L --retries 1 --raw --no-history)
        assert equal $retried_5xx.response.status 200
        assert equal (redirect-events $server | where path == /retry-500 | length) 2
        assert equal (redirect-events $server | where path == /terminal-500 | length) 2

        api config set timeout_seconds 0.18 | ignore
        let timed_out = (run-command-process $root $"api get (($base + '/slow-start') | to nuon) -L --raw --no-history")
        assert ($timed_out.exit_code != 0)
        assert ($timed_out.stderr | str contains "Curl transport failed with exit code 28")
        api config set timeout_seconds 30 | ignore

        let no_location = (api get $"($base)/r/302/none" -L --raw --no-history)
        assert equal $no_location.response.status 302
        for status in [300 304] {
            let followed = (api get $"($base)/r/($status)/same?case=status-($status)" -L --raw --no-history)
            assert equal $followed.response.status 200
        }
        for target in [relative protocol absolute bracket] {
            let followed = (api get $"($base)/r/302/($target)?case=target-($target)" -L --raw --no-history)
            assert equal $followed.response.status 200 $"curl-resolved redirect target failed: ($target)"
        }
        let one_hop = (api get $"($base)/r/302/same?case=no-follow" --raw --no-history)
        assert equal $one_hop.response.status 302
        assert equal (redirect-events-for $server no-follow | length) 1
    }
}

def test-redirect-results-history-output-and-binary [] {
    redirect-fixture "redirect-results" {|root, server|
        let base = $"http://127.0.0.1:($server.ports.a)"
        let plain = (api get $"($base)/final?case=plain-shape" --raw --no-history)
        assert equal ($plain | columns) [request response timestamp]

        let redirected = (api get $"($base)/r/302/relative?case=result-shape" -L --raw)
        assert equal ($redirected | columns) [request response timestamp redirects effective_url]
        assert equal ($redirected.redirects | get status) [302]
        assert equal ($redirected.redirects | first | get url) $"($base)/r/302/relative?case=result-shape"
        assert equal ($redirected.redirects | first | get method) GET
        assert equal ($redirected.redirects | first | get next_method) GET
        assert equal ($redirected.redirects | first | get target) $redirected.effective_url
        assert ($redirected.effective_url | str contains "/final")
        let history = (open ($root | path join "history" "index.nuon"))
        assert equal ($history | length) 1
        assert equal ($history | first | get url) $"($base)/r/302/relative?case=result-shape"

        api config set timeout_seconds 30 | ignore
        let timed = (api get $"($base)/timed-start" -L --raw --no-history)
        assert ($timed.response.time_ms >= 55) "redirect response time did not include both hops"
        assert equal $timed.response.size_bytes 9

        let binary_path = ($root | path join "redirect.bin")
        let binary = (api get $"($base)/binary-start" -L --binary-save $binary_path --raw --no-history)
        assert equal $binary.response.status 200
        assert equal (open $binary_path --raw) "REDIRECT-BINARY-FINAL"
        let temp_files = (try { ls $root | where {|entry| $entry.name | str contains ".nurl-tmp-" } } catch { [] })
        assert ($temp_files | is-empty) "redirect binary transfer leaked an attempt file"

        let save_path = ($root | path join "saved.json")
        let saved = (run-command-process $root $"api get (($base + '/r/302/same?case=save') | to nuon) -L --output body --save ($save_path | to nuon) --no-history")
        assert equal $saved.exit_code 0 $"redirect --save failed: ($saved.stderr)"
        assert ($save_path | path exists)
        for case in [
            {name: status, options: "--output status", expected: "200"}
            {name: select, options: "--select status", expected: "200"}
            {name: raw-body, options: "--output raw", expected: '"server":"a"'}
            {name: json, options: "--output json", expected: '"effective_url"'}
            {name: include, options: "--include", expected: "/final"}
            {name: verbose, options: "--verbose", expected: "↳ 302"}
        ] {
            let result = (run-command-process $root $"api get (($base + '/r/302/same?case=' + $case.name) | to nuon) -L --no-history ($case.options)")
            assert equal $result.exit_code 0 $"redirect output mode failed: ($case.name)"
            assert ($result.stdout | str contains $case.expected) $"redirect output mode returned the wrong final data: ($case.name)"
        }

        let pretty_plain = (run-command-process $root $"api get (($base + '/final?case=pretty-plain') | to nuon) --no-history")
        assert equal $pretty_plain.exit_code 0
        assert (not ($pretty_plain.stdout | str contains "Redirected:"))
        let pretty_redirect = (run-command-process $root $"api post (($base + '/r/302/same?case=pretty-redirect') | to nuon) -b body -L --no-history")
        assert equal $pretty_redirect.exit_code 0
        assert ($pretty_redirect.stdout | str contains $"Redirected: 1 hop -> ($base)/final?case=pretty-redirect")
        let verbose_redirect = (run-command-process $root $"api post (($base + '/r/302/same?case=verbose-transition') | to nuon) -b body -L --verbose --no-history")
        assert equal $verbose_redirect.exit_code 0
        assert ($verbose_redirect.stdout | str contains $"↳ 302 POST -> GET ($base)/final?case=verbose-transition")
        assert ($verbose_redirect.stdout | str contains $"↳ 200 GET ($base)/final?case=verbose-transition")

        let normalized = (api request -m post $"($base)/final?case=normalized-method" -b body --raw --no-history)
        assert equal $normalized.request.method POST
        assert equal (redirect-events-for $server normalized-method | last | get method) POST

        api collection create preview-methods | ignore
        api request create preview-get GET $"($base)/final" --collection preview-methods | ignore
        api request create preview-post POST $"($base)/final" --collection preview-methods --body {ok: true} | ignore
        let previews = [
            (run-command-process $root $"api get (($base + '/final') | to nuon) --dry-run")
            (run-command-process $root $"api post (($base + '/final') | to nuon) -b body --dry-run")
            (run-command-process $root $"api request -m get (($base + '/final') | to nuon) --dry-run")
            (run-command-process $root $"api request -m post (($base + '/final') | to nuon) -b body --dry-run")
            (run-command-process $root "api request export preview-get --collection preview-methods")
            (run-command-process $root "api request export preview-post --collection preview-methods")
        ]
        for preview in $previews {
            assert equal $preview.exit_code 0
            assert (not ($preview.stdout | str contains "-X GET"))
            assert (not ($preview.stdout | str contains "-X POST"))
        }
    }
}

def test-redirect-head-and-options [] {
    redirect-fixture "redirect-method-surfaces" {|root, server|
        let base = $"http://127.0.0.1:($server.ports.a)"
        for status in [301 302 303 307 308] {
            let head_label = $"head-($status)"
            let head = (api head $"($base)/r/($status)/same?case=($head_label)" -L --raw --no-history)
            assert equal $head.response.status 200
            assert equal $head.response.body null
            assert equal (redirect-events-for $server $head_label | get method) [HEAD HEAD]

            let options_label = $"options-($status)"
            let options = (api options $"($base)/r/($status)/same?case=($options_label)" -L --raw --no-history)
            assert equal $options.response.status 200
            assert equal (redirect-events-for $server $options_label | get method) (
                if $status == 303 { [OPTIONS GET] } else { [OPTIONS OPTIONS] }
            )
        }
        let head_control = (api head $"($base)/r/302/same?case=head-control" --raw --no-history)
        assert equal $head_control.response.status 302
        assert equal (redirect-events-for $server head-control | length) 1
        let options_control = (api options $"($base)/r/302/same?case=options-control" --raw --no-history)
        assert equal $options_control.response.status 302
        assert equal (redirect-events-for $server options-control | length) 1
        let unsafe = (run-command-process $root $"api options (($base + '/r/302/userinfo') | to nuon) -L --raw --no-history")
        assert ($unsafe.exit_code != 0)
        assert equal ($unsafe.stdout | str trim) ""
        assert (not ($unsafe.stderr | str contains "REDIRECT-SECRET"))
    }
}

export def run-suite-redirects []: nothing -> list<record> {
    [
        (run-test "redirect helpers enforce RFC methods, entity headers, and origins" { test-redirect-pure-contracts })
        (run-test "redirect methods and bodies follow 301/302/303/307/308 semantics" { test-redirect-method-body-matrix })
        (run-test "redirect credentials stay same-origin and are stripped cross-origin" { test-redirect-credential-boundaries })
        (run-test "redirect targets, hop limits, retries, and deadlines fail safely" { test-redirect-safety-limit-and-retries })
        (run-test "direct HEAD and OPTIONS expose the managed redirect policy" { test-redirect-head-and-options })
        (run-test "redirect results, history, output modes, timing, and binary saves stay compatible" { test-redirect-results-history-output-and-binary })
    ]
}
