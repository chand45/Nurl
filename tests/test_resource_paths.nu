# Resource identifier path-containment regressions.

use ../nu_modules/resource-path.nu [validate-resource-name resolve-under-base]

def expect-resource-error [action: closure, expected: string] {
    let caught = try {
        do $action | ignore
        null
    } catch {|error|
        $error
    }

    assert ($caught != null) "expected resource validation to fail"
    assert ($caught.msg | str contains $expected) $"expected error to contain: ($expected)"
}

def run-module-script [root: string, command: string] {
    let script_path = ($root | path join $"resource-subprocess-(random uuid).nu")
    let module_path = ($env.NURL_REPO_ROOT | path join "nu_modules" "mod.nu")
    [
        $"use ($module_path | to nuon) *"
        $"$env.API_ROOT = ($root | to nuon)"
        $command
    ] | str join "\n" | save -f $script_path

    let result = (^$nu.current-exe $script_path | complete)
    rm -f $script_path
    $result
}

def run-tui-action-script [root: string, command: string] {
    let script_path = ($root | path join $"resource-tui-subprocess-(random uuid).nu")
    let module_path = ($env.NURL_REPO_ROOT | path join "nu_modules" "mod.nu")
    let resource_path = ($env.NURL_REPO_ROOT | path join "nu_modules" "resource-path.nu")
    [
        $"use ($module_path | to nuon) *"
        $"use ($resource_path | to nuon) [run-tui-resource-action]"
        $"$env.API_ROOT = ($root | to nuon)"
        $command
    ] | str join "\n" | save -f $script_path

    let result = (^$nu.current-exe $script_path | complete)
    rm -f $script_path
    $result
}

def assert-invalid-process [root: string, command: string, expected: string] {
    let result = (run-module-script $root $command)
    assert ($result.exit_code != 0) $"invalid command unexpectedly exited 0: ($command)"
    assert equal ($result.stdout | str trim) "" $"invalid command wrote stdout: ($command)"
    assert ($result.stderr | str contains $expected) $"stderr did not contain '($expected)': ($command)"
    assert equal $result.stderr ($result.stderr | ansi strip) "non-TTY stderr must not contain ANSI escapes"
    for forbidden in [" created" " deleted" " updated" " copied" "Switched to environment" "curl " "TEST-SECRET-SENTINEL" "NETWORK-HIT-SENTINEL"] {
        assert (not ($result.stderr | str contains $forbidden)) $"invalid command emitted forbidden text '($forbidden)': ($command)"
    }
    $result
}

def list-workspace-entries [root: string] {
    if not ($root | path exists) {
        return []
    }

    ls -a $root | each {|entry|
        if $entry.type == "dir" {
            [$entry.name] | append (list-workspace-entries $entry.name)
        } else {
            [$entry.name]
        }
    } | flatten
}

def workspace-snapshot [root: string] {
    list-workspace-entries $root | each {|path|
        let path_type = ($path | path type)
        {
            path: ($path | path relative-to $root | str replace --all "\\" "/")
            type: $path_type
            content: (if $path_type == "file" { open $path --raw } else { null })
        }
    } | sort-by path
}

def create-directory-link [link_path: string, target_path: string] {
    if $nu.os-info.name == "windows" {
        let command = $"New-Item -ItemType Junction -Path ($link_path | to nuon) -Target ($target_path | to nuon) | Out-Null"
        let result = (^powershell.exe -NoProfile -NonInteractive -Command $command | complete)
        $result.exit_code == 0
    } else {
        let result = (^ln -s $target_path $link_path | complete)
        $result.exit_code == 0
    }
}

def start-counting-server [tmp: string] {
    if (which node | is-empty) {
        error make {msg: "SKIP: node unavailable for local no-network proof"}
    }

    let counter_file = ($tmp | path join "network-count.txt")
    let port_file = ($tmp | path join "network-port.txt")
    let stop_file = ($tmp | path join "network-stop.txt")
    let server_script = ($tmp | path join "network-server.js")
    "0" | save -f $counter_file

    let js = 'const http=require("http"),fs=require("fs");
const cf=process.argv[2],pf=process.argv[3],sf=process.argv[4];
const srv=http.createServer((req,res)=>{
  let c=parseInt(fs.readFileSync(cf,"utf8").trim()||"0")+1;
  fs.writeFileSync(cf,c.toString());
  res.writeHead(200,{"Content-Type":"application/json"});
  res.end("{\"marker\":\"NETWORK-HIT-SENTINEL\",\"count\":"+c+"}");
});
srv.listen(0,"127.0.0.1",()=>fs.writeFileSync(pf,srv.address().port.toString()));
const watcher=setInterval(()=>{if(fs.existsSync(sf)){clearInterval(watcher);srv.close(()=>process.exit(0));}},50);
setTimeout(()=>process.exit(0),30000);'
    $js | save -f $server_script
    job spawn { ^node $server_script $counter_file $port_file $stop_file }

    mut port = 0
    mut tries = 0
    while ($port == 0 and $tries < 50) {
        sleep 0.1sec
        $tries = $tries + 1
        if ($port_file | path exists) {
            $port = (open $port_file --raw | str trim | into int)
        }
    }
    assert ($port > 0) "local request counter did not start"

    {
        port: $port
        counter_file: $counter_file
        stop_file: $stop_file
    }
}

def network-count [server: record] {
    open $server.counter_file --raw | str trim | into int
}

def stop-counting-server [server: record] {
    "stop" | save -f $server.stop_file
    sleep 0.1sec
}

def test-resource-helper-boundaries [] {
    for name in ["jsonplaceholder" "team api.v1" "hyphen-name" "équipe 世界"] {
        assert equal (validate-resource-name "collection" $name) [$name]
    }

    for name in [
        "" "." ".." "..." "...."
        "a/b" "a\\b" "a/..\\secret" "a\\.\\b"
        "/absolute" "C:\\absolute" "C:relative" "\\\\server\\share"
    ] {
        expect-resource-error {
            validate-resource-name "collection" $name | ignore
        } "Invalid collection name"
    }

    assert equal (
        validate-resource-name "request" "auth/login" --nested --scope "<collection>/requests"
    ) [auth login]
    assert equal (
        validate-resource-name "request" "auth\\login" --nested --scope "<collection>/requests"
    ) [auth login]

    for name in [
        "" "." ".." "..." "/auth" "auth/" "auth//login"
        "auth/./login" "auth/../secret" "auth/.../secret"
        "auth\\..//secret" "auth\\.\\login" "C:\\secret" "\\\\server\\share"
    ] {
        expect-resource-error {
            validate-resource-name "request" $name --nested --scope "<collection>/requests" | ignore
        } "Invalid request name"
    }

    let tmp = (make-temp-dir "resource-helper")
    let base = ($tmp | path join "base")
    mkdir $base
    let resolved = (resolve-under-base $base "auth/login.nuon" "request" --nested --suffix ".nuon" --scope "<collection>/requests")
    assert ($resolved | str ends-with (["auth" "login.nuon"] | path join))
    expect-resource-error {
        resolve-under-base $base "missing/.../outside.nuon" "request" --nested --scope "<collection>/requests"
    } "Invalid request name"
    cleanup $tmp
}

def test-original-attacks-blocked [] {
    let tmp = (make-temp-dir "resource-attacks")
    let root = ($tmp | path join "workspace")
    mkdir $root
    $env.API_ROOT = $root
    api init | ignore
    api collection create demo | ignore

    let root_sentinel = ($root | path join "root-sentinel.txt")
    let secret_file = ($root | path join "secrets.nuon")
    let collection_file = ($root | path join "collections" "demo" "collection.nuon")
    let variables_file = ($root | path join "variables.nuon")
    "ROOT-SENTINEL" | save -f $root_sentinel
    "{sentinel: SECRET-DISCLOSURE}" | save -f $secret_file
    "{sentinel: ENV-SENTINEL}" | save -f $collection_file
    "{sentinel: CHAIN-SENTINEL}" | save -f $variables_file

    let root_before = (open $root_sentinel --raw)
    let secret_before = (open $secret_file --raw)
    let collection_before = (open $collection_file --raw)
    let variables_before = (open $variables_file --raw)

    assert-invalid-process $root "api collection delete '..' --force" "Invalid collection name '..'" | ignore
    assert-invalid-process $root "api request show '..\\..\\..\\secrets' --collection demo" "Invalid request name" | ignore
    assert-invalid-process $root "api collection env delete demo '..\\collection' --force" "Invalid environment name" | ignore
    assert-invalid-process $root "api chain delete '..\\variables' --force" "Invalid chain name" | ignore

    assert equal (open $root_sentinel --raw) $root_before
    assert equal (open $secret_file --raw) $secret_before
    assert equal (open $collection_file --raw) $collection_before
    assert equal (open $variables_file --raw) $variables_before
    cleanup $tmp
}

def test-subprocess-rejection-families [] {
    let tmp = (make-temp-dir "resource-family-contracts")
    let root = ($tmp | path join "workspace with spaces")
    mkdir $root
    $env.API_ROOT = $root
    api init | ignore
    api collection create demo | ignore
    api collection env create demo dev --activate | ignore
    api collection env set demo base_url "http://127.0.0.1:1" | ignore
    api request create safe GET "{{base_url}}/safe" --collection demo | ignore
    api chain create safe | ignore
    {name: "safe", steps: []} | to nuon | save -f ($root | path join "chains" "safe.nuon")
    api chain create malicious | ignore
    {name: "malicious", steps: [{request: "auth/../secret"}]} | to nuon | save -f ($root | path join "chains" "malicious.nuon")

    let outside_sentinel = ($tmp | path join "outside-sentinel.nuon")
    "TEST-SECRET-SENTINEL" | save -f $outside_sentinel
    let outside_before = (open $outside_sentinel --raw)
    let before = (workspace-snapshot $root)

    let cases = [
        {command: "api collection create ''", expected: "Invalid collection name ''"}
        {command: "api collection show '\\\\server\\share'", expected: "Invalid collection name"}
        {command: "api collection delete '...' --force", expected: "Invalid collection name"}
        {command: "api collection copy '../source' target", expected: "Invalid collection name"}
        {command: "api collection copy demo '..\\target'", expected: "Invalid collection name"}

        {command: "api collection env list '..'", expected: "Invalid collection name"}
        {command: "api collection env create '..' dev", expected: "Invalid collection name"}
        {command: "api collection env create demo '../dev'", expected: "Invalid environment name"}
        {command: "api collection env use '..' dev", expected: "Invalid collection name"}
        {command: "api collection env use demo '..\\dev'", expected: "Invalid environment name"}
        {command: "api collection env show '..' dev", expected: "Invalid collection name"}
        {command: "api collection env show demo '...'", expected: "Invalid environment name"}
        {command: "api collection env set '..' key value --target dev", expected: "Invalid collection name"}
        {command: "api collection env set demo key value --target '/dev'", expected: "Invalid environment name"}
        {command: "api collection env unset '..' key --target dev", expected: "Invalid collection name"}
        {command: "api collection env unset demo key --target '\\\\server\\share'", expected: "Invalid environment name"}
        {command: "api collection env delete '..' dev --force", expected: "Invalid collection name"}
        {command: "api collection env delete demo 'a/..\\collection' --force", expected: "Invalid environment name"}

        {command: "api chain create ''", expected: "Invalid chain name ''"}
        {command: "api chain show '...'", expected: "Invalid chain name"}
        {command: "api chain delete '..\\variables' --force", expected: "Invalid chain name"}
        {command: "api chain exec '..'", expected: "Invalid chain name"}
        {command: "api chain exec malicious --quiet", expected: "Invalid request name"}
        {command: "api chain run [{request: 'auth/../secret'}] --quiet", expected: "Invalid request name"}
        {command: "api chain run [] --collection '..' --quiet", expected: "Invalid collection name"}

        {command: "api vars get-merged --collection '..'", expected: "Invalid collection name"}
        {command: "api vars interpolate '{{base_url}}' --collection '...'", expected: "Invalid collection name"}
        {command: "api vars interpolate-record {url: '{{base_url}}'} --collection '..\\demo'", expected: "Invalid collection name"}
    ]

    for case in $cases {
        assert-invalid-process $root $case.command $case.expected | ignore
        assert equal (workspace-snapshot $root) $before $"workspace changed after: ($case.command)"
        assert equal (open $outside_sentinel --raw) $outside_before $"outside sentinel changed after: ($case.command)"
    }

    assert equal (ls $tmp | get name | path basename | sort) ["outside-sentinel.nuon" "workspace with spaces"]
    cleanup $tmp
}

def test-collection-surface [] {
    let tmp = (make-temp-dir "resource-collections")
    let root = ($tmp | path join "workspace with spaces")
    mkdir $root
    $env.API_ROOT = $root
    api init | ignore

    expect-resource-error { api collection create ".." } "Invalid collection name"
    expect-resource-error { api collection show "../outside" } "Invalid collection name"
    expect-resource-error { api collection delete ".." --force } "Invalid collection name"
    expect-resource-error { api collection copy "../outside" target } "Invalid collection name"

    api collection create source | ignore
    expect-resource-error { api collection copy source "..\\outside" } "Invalid collection name"
    assert (not (($root | path join "outside") | path exists))

    let valid = "team api.v1 世界"
    let copied = "copy api.v1 世界"
    api collection create $valid | ignore
    assert (($root | path join "collections" $valid) | path exists)
    assert ((api collection show $valid) | describe | str starts-with "list")
    api collection copy $valid $copied | ignore
    assert (($root | path join "collections" $copied) | path exists)
    api collection delete $copied --force | ignore
    assert (not (($root | path join "collections" $copied) | path exists))

    # Preserve duplicate and not-found behavior (no validation error).
    api collection create $valid | ignore
    assert equal (api collection show "missing-valid-name") null
    cleanup $tmp
}

def test-environment-surface [] {
    let tmp = (make-temp-dir "resource-envs")
    $env.API_ROOT = $tmp
    api init | ignore
    api collection create demo | ignore
    let collection_file = ($tmp | path join "collections" "demo" "collection.nuon")
    let before = (open $collection_file --raw)

    expect-resource-error { api collection env list ".." } "Invalid collection name"
    expect-resource-error { api collection env create demo "../dev" } "Invalid environment name"
    expect-resource-error { api collection env use demo ".." } "Invalid environment name"
    expect-resource-error { api collection env show demo "..\\collection" } "Invalid environment name"
    expect-resource-error { api collection env set demo key value --target ".." } "Invalid environment name"
    expect-resource-error { api collection env unset demo key --target "../dev" } "Invalid environment name"
    expect-resource-error { api collection env delete demo "..\\collection" --force } "Invalid environment name"
    assert equal (open $collection_file --raw) $before

    let environment = "dev team.v1 世界"
    api collection env create demo $environment --activate | ignore
    api collection env set demo base_url "https://example.com" | ignore
    let shown = (api collection env show demo $environment)
    assert equal $shown.environment $environment
    assert equal ($shown.variables | where key == base_url | get value | first) "https://example.com"
    api collection env unset demo base_url | ignore
    api collection env delete demo $environment --force | ignore

    api collection env create demo release | ignore
    api collection env create demo release.nuon | ignore
    assert (($tmp | path join "collections" "demo" "environments" "release.nuon") | path exists)
    assert (($tmp | path join "collections" "demo" "environments" "release.nuon.nuon") | path exists)
    assert equal (api collection env show demo release | get environment) release
    assert equal (api collection env show demo release.nuon | get environment) release.nuon
    api collection env delete demo release --force | ignore
    api collection env delete demo release.nuon --force | ignore
    cleanup $tmp
}

def test-request-lifecycle-and-explicit-body-file [] {
    let tmp = (make-temp-dir "resource-requests")
    let root = ($tmp | path join "workspace with spaces")
    mkdir $root
    $env.API_ROOT = $root
    api init | ignore

    let collection = "team api.v1 世界"
    let request = "auth/login 世界"
    let body_file = ($tmp | path join "outside body.json")
    '{"name":"alice"}' | save -f $body_file
    api request create $request POST "https://example.com/login" --body-file $body_file --collection $collection | ignore

    let request_file = ($root | path join "collections" $collection "requests" "auth" "login 世界.nuon")
    assert ($request_file | path exists)
    let shown = (api request show "auth\\login 世界" --collection $collection)
    assert equal $shown.method "POST"
    assert equal $shown.body.content.name "alice"

    api request update $request --method PUT --url "https://example.com/users/1" --collection $collection | ignore
    assert equal (api request show $request --collection $collection | get method) "PUT"
    let listed = (api request list --collection $collection)
    assert ($request in $listed.name)
    assert equal (api collection list | where name == $collection | get requests | first) 1
    assert equal (api collection show $collection | get name | first) $request

    let request_with_suffix = $"($request).nuon"
    let send_result = (run-module-script $root $"api send ($request_with_suffix | to nuon) --collection ($collection | to nuon) --dry-run")
    assert equal $send_result.exit_code 0
    assert ($send_result.stdout | str contains "curl")
    let export_result = (run-module-script $root $"api request export ($request | to nuon) --collection ($collection | to nuon)")
    assert equal $export_result.exit_code 0
    assert ($export_result.stdout | str contains "curl")

    api request create release GET "https://example.com/release" --collection $collection | ignore
    api request create release.nuon GET "https://example.com/release-nuon" --collection $collection | ignore
    assert (($root | path join "collections" $collection "requests" "release.nuon") | path exists)
    assert (($root | path join "collections" $collection "requests" "release.nuon.nuon") | path exists)
    let exact_storage = (run-module-script $root $"api send 'release.nuon.nuon' --collection ($collection | to nuon) --dry-run")
    assert ($exact_storage.stdout | str contains "release-nuon")

    api request delete "auth\\login 世界" --collection $collection --force | ignore
    assert (not ($request_file | path exists))
    cleanup $tmp
}

def test-request-invalid-command-surface [] {
    let tmp = (make-temp-dir "resource-request-invalid")
    $env.API_ROOT = $tmp
    api init | ignore
    api collection create demo | ignore
    api request create valid GET "https://example.invalid/should-not-run" --collection demo | ignore
    let sentinel = ($tmp | path join "sentinel.nuon")
    "{sentinel: REQUEST-SENTINEL}" | save -f $sentinel
    let before = (open $sentinel --raw)
    let workspace_before = (workspace-snapshot $tmp)

    let commands = [
        "api request create '' GET 'https://example.invalid' --collection demo"
        "api request create '../escape' GET 'https://example.invalid' --collection demo"
        "api request show '..\\escape' --collection demo"
        "api request show '../escape'"
        "api request show 'a/..\\escape' --collection demo"
        "api request show '\\\\server\\share' --collection demo"
        "api request update '../escape' --method POST --collection demo"
        "api request delete '..\\escape' --collection demo --force"
        "api request export '../escape' --collection demo"
        "api send '../escape' --collection demo"
        "api send '..\\escape'"
        "api send '..\\escape' --collection demo --raw"
        "api send '../escape' --collection demo --output pretty"
        "api send '../escape' --collection demo --output body"
        "api send '../escape' --collection demo --output json"
        "api send '../escape' --collection demo --output headers"
        "api send '../escape' --collection demo --output status"
        "api send '../escape' --collection demo --output none"
        "api send '../escape' --collection demo --select body.id"
        "api send '../escape' --collection demo --dry-run"
    ]

    for command in $commands {
        assert-invalid-process $tmp $command "Invalid request name" | ignore
        assert equal (workspace-snapshot $tmp) $workspace_before $"workspace changed after: ($command)"
    }

    let invalid_collection_commands = [
        "api request create valid GET 'https://example.invalid' --collection '..'"
        "api request list --collection '..'"
        "api request show valid --collection '..'"
        "api request update valid --method POST --collection '..'"
        "api request delete valid --collection '..' --force"
        "api request export valid --collection '..'"
        "api send valid --collection '..' --dry-run"
    ]
    for command in $invalid_collection_commands {
        assert-invalid-process $tmp $command "Invalid collection name" | ignore
        assert equal (workspace-snapshot $tmp) $workspace_before $"workspace changed after: ($command)"
    }

    assert equal (open $sentinel --raw) $before
    cleanup $tmp
}

def test-no-network-and-valid_lifecycle [] {
    let tmp = (make-temp-dir "resource-local-network")
    let root = ($tmp | path join "workspace with spaces")
    mkdir $root
    let server = (start-counting-server $tmp)
    let base_url = $"http://127.0.0.1:($server.port)"

    $env.API_ROOT = $root
    api init | ignore
    api collection create "team api.v1 世界" | ignore
    api collection env create "team api.v1 世界" dev --activate | ignore
    api collection env set "team api.v1 世界" base_url $base_url | ignore
    api collection env set "team api.v1 世界" route ping | ignore
    api request create "auth/ping 世界" GET "{{base_url}}/{{route}}" --collection "team api.v1 世界" | ignore

    let outside_request = ($tmp | path join "outside-request.nuon")
    {
        name: "outside-request"
        collection: "demo"
        method: "GET"
        url: $"($base_url)/should-never-run"
        headers: {}
        body: null
        auth: null
    } | to nuon | save -f $outside_request
    let outside_before = (open $outside_request --raw)
    let workspace_before = (workspace-snapshot $root)
    let tmp_before = (workspace-snapshot $tmp)
    let malicious_name = "../../../../outside-request"
    let flag_cases = [
        ""
        "--raw"
        "--output pretty"
        "--output body"
        "--output json"
        "--output headers"
        "--output status"
        "--output none"
        "--select body.marker"
        "--dry-run"
    ]

    for flags in $flag_cases {
        let command = $"api send ($malicious_name | to nuon) --collection 'team api.v1 世界' ($flags)"
        assert-invalid-process $root $command "Invalid request name" | ignore
        assert equal (network-count $server) 0 $"invalid send reached the local server: ($flags)"
        assert equal (workspace-snapshot $root) $workspace_before $"invalid send changed workspace: ($flags)"
        assert equal (open $outside_request --raw) $outside_before $"invalid send changed outside request: ($flags)"
        assert equal (workspace-snapshot $tmp) $tmp_before $"invalid send changed files outside the workspace: ($flags)"
    }

    let dry_run = (run-module-script $root "api send 'auth/ping 世界' --collection 'team api.v1 世界' --vars {route: dry-run} --dry-run")
    assert equal $dry_run.exit_code 0
    assert ($dry_run.stdout | str contains $"($base_url)/dry-run")
    assert equal (network-count $server) 0 "valid dry-run must not reach the local server"

    let sent = (api send "auth/ping 世界" --collection "team api.v1 世界" --vars {route: direct} --raw --no-history)
    assert equal $sent.response.status 200
    assert equal $sent.response.body.marker "NETWORK-HIT-SENTINEL"
    assert equal (network-count $server) 1

    api chain create workflow | ignore
    {
        name: "workflow"
        steps: [{request: "auth/ping 世界"}]
    } | to nuon | save -f ($root | path join "chains" "workflow.nuon")
    let chain_result = (api chain exec workflow --quiet)
    assert $chain_result.success
    assert equal ($chain_result.results | first | get status) 200
    assert equal (network-count $server) 2

    let save_path = ($tmp | path join "explicit saved response.json")
    api send "auth/ping 世界" --collection "team api.v1 世界" --save $save_path --no-history | ignore
    assert ($save_path | path exists)
    assert (open $save_path --raw | str contains "NETWORK-HIT-SENTINEL")
    assert equal (network-count $server) 3

    let binary_path = ($tmp | path join "explicit binary response.bin")
    let binary_result = (api send "auth/ping 世界" --collection "team api.v1 世界" --binary-save $binary_path --raw --no-history)
    assert equal $binary_result.response.status 200
    assert (open $binary_path --raw | str contains "NETWORK-HIT-SENTINEL")
    assert equal (network-count $server) 4

    let history_export = ($tmp | path join "explicit history export.json")
    api history export --output $history_export | ignore
    assert ($history_export | path exists)
    assert ((open $history_export --raw | from json | length) >= 1)

    stop-counting-server $server
    cleanup $tmp
}

def test-chain-surface-and-explicit-path [] {
    let tmp = (make-temp-dir "resource-chains")
    let root = ($tmp | path join "workspace")
    mkdir $root
    $env.API_ROOT = $root
    api init | ignore

    expect-resource-error { api chain create "..\\variables" } "Invalid chain name"
    expect-resource-error { api chain show "../variables" } "Invalid chain name"
    expect-resource-error { api chain delete "..\\variables" --force } "Invalid chain name"

    let chain_name = "chain team.v1 世界"
    api chain create $chain_name | ignore
    let chain_file = ($root | path join "chains" $"($chain_name).nuon")
    {name: $chain_name, description: "", steps: []} | to nuon | save -f $chain_file
    let named = (api chain exec $chain_name --quiet)
    assert $named.success

    api chain create release | ignore
    api chain create release.nuon | ignore
    let release_file = ($root | path join "chains" "release.nuon")
    let release_nuon_file = ($root | path join "chains" "release.nuon.nuon")
    assert ($release_file | path exists)
    assert ($release_nuon_file | path exists)
    {name: "release", steps: []} | to nuon | save -f $release_file
    {name: "release.nuon", steps: []} | to nuon | save -f $release_nuon_file
    assert equal (api chain show release | get name) release
    assert equal (api chain show release.nuon | get name) release.nuon
    assert equal (api chain exec release.nuon --quiet | get results | length) 0
    assert (api chain exec "chains/release.nuon.nuon" --quiet | get success)

    let explicit_file = ($tmp | path join "explicit outside chain.nuon")
    {name: "explicit", steps: []} | to nuon | save -f $explicit_file
    let explicit = (api chain exec $explicit_file --quiet)
    assert $explicit.success

    let nested_chain_dir = ($root | path join "chains" "sub")
    mkdir $nested_chain_dir
    {name: "chains-relative", steps: []} | to nuon | save -f ($nested_chain_dir | path join "workflow.nuon")
    assert (api chain exec "sub/workflow.nuon" --quiet | get success)
    assert (api chain exec "sub/workflow" --quiet | get success)

    assert-invalid-process $root "api chain run [{request: '../variables'}] --quiet" "Invalid request name" | ignore
    assert-invalid-process $root "api chain run [] --collection '..' --quiet" "Invalid collection name" | ignore
    {name: "malicious", steps: [{request: "..\\variables"}]} | to nuon | save -f $explicit_file
    assert-invalid-process $root $"api chain exec ($explicit_file | to nuon)" "Invalid request name" | ignore

    api chain delete $chain_name --force | ignore
    api chain delete release --force | ignore
    api chain delete release.nuon --force | ignore
    cleanup $tmp
}

def test-vars-collection-context [] {
    let tmp = (make-temp-dir "resource-vars")
    $env.API_ROOT = $tmp
    api init | ignore
    api collection create demo | ignore
    api collection env create demo dev --activate | ignore
    api collection env set demo host "example.com" | ignore

    assert equal (api vars interpolate "https://{{host}}" --collection demo) "https://example.com"
    assert equal (
        api vars interpolate-record {url: "https://{{host}}"} --collection demo | get url
    ) "https://example.com"

    expect-resource-error { api vars get-merged --collection ".." } "Invalid collection name"
    expect-resource-error { api vars interpolate "{{host}}" --collection "../secrets" } "Invalid collection name"
    expect-resource-error {
        api vars interpolate "{{host}}" --collection "..\\secrets" --env-vars {host: "ignored"}
    } "Invalid collection name"
    expect-resource-error {
        api vars interpolate-record {host: "{{host}}"} --collection "../secrets" --env-vars {host: "ignored"}
    } "Invalid collection name"
    cleanup $tmp
}

def test-symlink-escapes [] {
    let tmp = (make-temp-dir "resource-links")
    let root = ($tmp | path join "workspace")
    let capability_target = ($tmp | path join "capability-target")
    let capability_link = ($tmp | path join "capability-link")
    let outside_collection = ($tmp | path join "outside-collection")
    let outside_requests = ($tmp | path join "outside-requests")
    let outside_environment = ($tmp | path join "outside-environment")
    let outside_chain = ($tmp | path join "outside-chain")
    let outside_base = ($tmp | path join "outside-base")
    mkdir $root
    mkdir $capability_target
    mkdir $outside_collection
    mkdir $outside_requests
    mkdir $outside_environment
    mkdir $outside_chain
    mkdir $outside_base

    if not (create-directory-link $capability_link $capability_target) {
        cleanup $tmp
        error make {msg: "SKIP: directory symlink/junction creation unavailable"}
    }
    rm $capability_link

    $env.API_ROOT = $root
    api init | ignore
    let contained_collections = ($root | path join "contained-collections")
    mkdir $contained_collections
    rm -rf ($root | path join "collections")
    assert (create-directory-link ($root | path join "collections") $contained_collections) "contained collections link creation failed after capability preflight"

    api collection create demo | ignore
    api collection create real | ignore
    mkdir ($root | path join "chains")
    {name: "secret", method: "GET", url: "https://example.invalid"} | to nuon | save -f ($outside_requests | path join "secret.nuon")
    "TEST-SECRET-SENTINEL" | save -f ($outside_collection | path join "sentinel.txt")
    "TEST-SECRET-SENTINEL" | save -f ($outside_environment | path join "sentinel.txt")
    "TEST-SECRET-SENTINEL" | save -f ($outside_chain | path join "sentinel.txt")

    let contained_request_target = ($contained_collections | path join "demo" "requests" "contained-target")
    mkdir $contained_request_target
    {name: "inside", method: "GET", url: "https://example.invalid/inside"} | to nuon | save -f ($contained_request_target | path join "inside.nuon")

    let collection_link = ($root | path join "collections" "escape")
    let request_link = ($root | path join "collections" "demo" "requests" "escape")
    let contained_request_link = ($root | path join "collections" "demo" "requests" "contained")
    let contained_collection_link = ($root | path join "collections" "alias")
    let environment_link = ($root | path join "collections" "demo" "environments" "escape.nuon")
    let chain_link = ($root | path join "chains" "escape.nuon")
    assert (create-directory-link $collection_link $outside_collection) "escaping collection link creation failed after capability preflight"
    assert (create-directory-link $request_link $outside_requests) "escaping request link creation failed after capability preflight"
    assert (create-directory-link $contained_request_link $contained_request_target) "contained request link creation failed after capability preflight"
    assert (create-directory-link $contained_collection_link ($contained_collections | path join "real")) "contained collection link creation failed after capability preflight"
    assert (create-directory-link $environment_link $outside_environment) "environment link creation failed after capability preflight"
    assert (create-directory-link $chain_link $outside_chain) "chain link creation failed after capability preflight"

    assert (($contained_collections | path join "demo") | path exists) "linked collections base should remain usable"
    assert ((api collection show alias) | describe | str starts-with "list") "contained collection link should be accepted"
    assert equal (api request show "contained/inside" --collection demo | get name) inside
    expect-resource-error { api collection show escape } "existing links cannot escape"
    expect-resource-error { api request show "escape/secret" --collection demo } "existing links cannot escape"
    expect-resource-error { api collection env show demo escape } "existing links cannot escape"
    expect-resource-error { api chain show escape } "existing links cannot escape"

    let escaping_root = ($tmp | path join "escaping-workspace")
    mkdir $escaping_root
    assert (create-directory-link ($escaping_root | path join "collections") $outside_base) "escaping base link creation failed after capability preflight"
    $env.API_ROOT = $escaping_root
    expect-resource-error { api collection list } "existing links cannot escape"

    assert equal (open ($outside_collection | path join "sentinel.txt") --raw) "TEST-SECRET-SENTINEL"
    assert equal (open ($outside_environment | path join "sentinel.txt") --raw) "TEST-SECRET-SENTINEL"
    assert equal (open ($outside_chain | path join "sentinel.txt") --raw) "TEST-SECRET-SENTINEL"
    cleanup $tmp
}

def test-tui-survives-validation-error [] {
    let tmp = (make-temp-dir "resource-tui")
    $env.API_ROOT = $tmp
    api init | ignore
    api collection create demo | ignore

    let result = (run-tui-action-script $tmp '
run-tui-resource-action { api collection env create demo "..\\escape" }
print "TOP_LEVEL_CONTINUED"
api collection env create demo valid-after-error')
    assert equal $result.exit_code 0
    assert equal ($result.stderr | str trim) ""
    let stdout = ($result.stdout | ansi strip)
    assert ($stdout | str contains "Invalid environment name '..\\escape'") "TUI wrapper must surface the validation error"
    assert ($stdout | str contains "TOP_LEVEL_CONTINUED") "TUI wrapper must return to the top-level flow"
    assert (not (($tmp | path join "collections" "demo" "environments" "escape.nuon") | path exists))
    assert (($tmp | path join "collections" "demo" "environments" "valid-after-error.nuon") | path exists)
    cleanup $tmp
}

def run-suite-resource-paths []: nothing -> list<record> {
    print $"\n(ansi yellow)── Resource Path Containment ──(ansi reset)"
    [
        (run-test "resource paths: helper boundaries" { test-resource-helper-boundaries })
        (run-test "resource paths: original attacks blocked" { test-original-attacks-blocked })
        (run-test "resource paths: subprocess contracts for collection, env, chain, and vars" { test-subprocess-rejection-families })
        (run-test "resource paths: collection surface" { test-collection-surface })
        (run-test "resource paths: environment surface" { test-environment-surface })
        (run-test "resource paths: nested request lifecycle and body-file compatibility" { test-request-lifecycle-and-explicit-body-file })
        (run-test "resource paths: request command and output surface" { test-request-invalid-command-surface })
        (run-test "resource paths: invalid sends cannot reach curl or network" { test-no-network-and-valid_lifecycle })
        (run-test "resource paths: chain names, steps, and explicit paths" { test-chain-surface-and-explicit-path })
        (run-test "resource paths: vars collection context" { test-vars-collection-context })
        (run-test "resource paths: symlink and junction escapes" { test-symlink-escapes })
        (run-test "resource paths: TUI catches validation errors" { test-tui-survives-validation-error })
    ]
}
