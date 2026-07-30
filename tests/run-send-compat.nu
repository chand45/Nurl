#!/usr/bin/env nu
# Focused saved-request discovery gate for supported Nushell runtimes.

let repo_root = ($env.FILE_PWD | path join ".." | path expand)
source ../api.nu
$env.NURL_REPO_ROOT = $repo_root

def run-api-command [repo_root: string, root: string, command: string] {
    let script_path = ($root | path join $"send-probe-(random uuid).nu")
    let module_path = ($repo_root | path join "nu_modules" "mod.nu")
    [
        $"use ($module_path | to nuon) *"
        $"$env.API_ROOT = ($root | to nuon)"
        $command
    ] | str join "\n" | save -f $script_path

    let result = (do { ^$nu.current-exe --no-config-file $script_path } | complete)
    rm -f $script_path
    $result
}

def require-check [condition: bool, message: string] {
    if not $condition {
        error make {msg: $message}
    }
}

def compatibility-temp-root [] {
    try { $nu.temp-dir } catch {
        try { $nu.temp-path } catch {
            try { $env.TEMP } catch {
                try { $env.TMPDIR } catch { "/tmp" }
            }
        }
    }
}

let workspace = (compatibility-temp-root | path join $".nurl-send-compat-(random uuid)")
let stop_file = ($workspace | path join "server-stop.txt")
let failure = try {
    mkdir $workspace
    $env.API_ROOT = $workspace
    api init | ignore
    api collection create a-nonmatching | ignore
    api collection create b-target | ignore
    api collection env create b-target default --activate | ignore
    api collection env set b-target base_url "https://discovered.example" | ignore
    api request create discovered-request GET "{{base_url}}/x" --collection b-target | ignore

    let auto = (run-api-command $repo_root $workspace "api send discovered-request --dry-run --no-history")
    let auto_stderr = try { $auto.stderr } catch { "" }
    let auto_stdout = try { $auto.stdout } catch { "" }
    require-check ($auto.exit_code == 0) $"Auto-discovery failed: ($auto_stderr)"
    require-check (($auto_stdout | str contains "https://discovered.example/x")) "Auto-discovery did not use the discovered collection environment"

    let explicit = (run-api-command $repo_root $workspace "api send discovered-request --collection b-target --dry-run --no-history")
    let explicit_stderr = try { $explicit.stderr } catch { "" }
    let explicit_stdout = try { $explicit.stdout } catch { "" }
    require-check ($explicit.exit_code == 0) $"Explicit collection lookup failed: ($explicit_stderr)"
    require-check (($explicit_stdout | str contains "https://discovered.example/x")) "Explicit collection lookup did not interpolate its environment"

    let missing = (run-api-command $repo_root $workspace "api send missing-auto-discovered --dry-run --no-history")
    let missing_stdout = try { $missing.stdout } catch { "" }
    let missing_stderr = try { $missing.stderr } catch { "" }
    require-check ($missing.exit_code != 0) "Missing auto-discovered request unexpectedly exited successfully"
    require-check (($missing_stdout | str trim) == "") "Missing auto-discovered request wrote stdout"
    require-check (($missing_stderr | str contains "Request 'missing-auto-discovered' not found")) "Missing auto-discovered request did not return the expected error"

    require-check (not (which node | is-empty)) "Node.js is required for the local live-transport compatibility check"
    let port_file = ($workspace | path join "server-port.txt")
    let server_script = ($workspace | path join "server.js")
    let launcher_script = ($workspace | path join "server-launcher.js")
    'const http=require("http"),fs=require("fs");
const pf=process.argv[2],sf=process.argv[3];
let stopping=false;
const srv=http.createServer((req,res)=>{
  if(req.url==="/binary"){
    const body=Buffer.from([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a,0xff,0xfe,0x00,0x01]);
    res.writeHead(200,{"Content-Type":"application/octet-stream","Content-Length":String(body.length),"Connection":"close"});
    res.end(body);
    return;
  }
  if(req.url==="/http-prefix"){
    const body="HTTP/1.1 418 Teapot";
    res.writeHead(200,{"Content-Type":"text/plain","Content-Length":String(body.length),"Connection":"close"});
    res.end(body);
    return;
  }
  res.writeHead(200,{"Content-Type":"application/json","Content-Length":"11","Connection":"close"});
  res.end("{\"ok\":true}");
});
const shutdown=()=>{
  if(stopping)return;
  stopping=true;
  clearInterval(watcher);
  srv.close(()=>process.exit(0));
  setTimeout(()=>process.exit(1),1000).unref();
};
const watcher=setInterval(()=>{if(fs.existsSync(sf))shutdown();},50);
srv.listen(0,"127.0.0.1",()=>fs.writeFileSync(pf,srv.address().port.toString()));
setTimeout(shutdown,30000).unref();' | save -f $server_script
    'const {spawn}=require("child_process");
const child=spawn(process.execPath,process.argv.slice(2),{detached:true,stdio:"ignore",windowsHide:true});
child.unref();' | save -f $launcher_script

    let launched = (do { ^node $launcher_script $server_script $port_file $stop_file } | complete)
    require-check ($launched.exit_code == 0) "Local compatibility server launcher failed"
    mut tries = 0
    while (not ($port_file | path exists)) and ($tries < 100) {
        sleep 0.05sec
        $tries = $tries + 1
    }
    require-check ($port_file | path exists) "Local compatibility server did not become ready"
    let port = (open $port_file --raw | str trim)
    api collection env set b-target base_url $"http://127.0.0.1:($port)" | ignore

    let live_json_command = "let result = (api send discovered-request --raw --no-history); let ok = try { $result.response.body.ok } catch { false }; if $ok != true { error make {msg: 'Live JSON body was not parsed'} }; print json-ok"
    let live_json = (run-api-command $repo_root $workspace $live_json_command)
    let live_json_stdout = try { $live_json.stdout } catch { "" }
    let live_json_stderr = try { $live_json.stderr } catch { "" }
    require-check ($live_json.exit_code == 0) $"Live auto-discovered JSON request failed: ($live_json_stderr)"
    require-check (($live_json_stdout | str trim) == "json-ok") $"Live JSON body assertion returned unexpected output: ($live_json_stdout)"

    api request create binary-request GET "{{base_url}}/binary" --collection b-target | ignore
    let binary_path = ($workspace | path join "live-response.bin")
    let binary_command = $"api send binary-request --binary-save ($binary_path | to nuon) --output status --no-history"
    let live_binary = (run-api-command $repo_root $workspace $binary_command)
    let live_binary_stdout = try { $live_binary.stdout } catch { "" }
    let live_binary_stderr = try { $live_binary.stderr } catch { "" }
    require-check ($live_binary.exit_code == 0) $"Live binary request failed: ($live_binary_stderr)"
    require-check (($live_binary_stdout | str trim) == "200") $"Live binary request returned unexpected output: ($live_binary_stdout)"
    require-check ($binary_path | path exists) "Live binary request did not create its output file"
    let binary_body = (open $binary_path)
    require-check (($binary_body | bytes length) == 12) "Live binary response length was not byte-exact"
    require-check ($binary_body == 0x[89504E470D0A1A0AFFFE0001]) "Live binary response content was not byte-exact"

    api request create http-prefix-request GET "{{base_url}}/http-prefix" --collection b-target | ignore
    let http_prefix_command = "let result = (api send http-prefix-request --raw --no-history); let body = try { $result.response.body } catch { '' }; if ($body | str length) != 19 { error make {msg: 'HTTP-prefixed body length was not byte-exact'} }; if $body != 'HTTP/1.1 418 Teapot' { error make {msg: 'HTTP-prefixed body content was not byte-exact'} }; print http-prefix-ok"
    let live_http_prefix = (run-api-command $repo_root $workspace $http_prefix_command)
    let live_http_prefix_stdout = try { $live_http_prefix.stdout } catch { "" }
    let live_http_prefix_stderr = try { $live_http_prefix.stderr } catch { "" }
    require-check ($live_http_prefix.exit_code == 0) $"Live HTTP-prefixed body request failed: ($live_http_prefix_stderr)"
    require-check (($live_http_prefix_stdout | str trim) == "http-prefix-ok") $"Live HTTP-prefixed body assertion returned unexpected output: ($live_http_prefix_stdout)"

    null
} catch {|error| $error }

try { "stop" | save -f $stop_file }
sleep 0.2sec
try { rm -rf $workspace }
if $failure != null {
    let message = try { $failure.msg } catch { $failure | into string }
    print $message
    exit 1
}

print "Send compatibility tests: 6, failed: 0, skipped: 0"
