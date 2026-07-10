# Resource identifier path-containment regressions.

use ../nu_modules/resource-path.nu [validate-resource-name resolve-under-base run-tui-resource-action]

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

def assert-invalid-process [root: string, command: string, expected: string] {
    let result = (run-module-script $root $command)
    assert ($result.exit_code != 0) $"invalid command unexpectedly exited 0: ($command)"
    assert equal ($result.stdout | str trim) "" $"invalid command wrote stdout: ($command)"
    assert ($result.stderr | str contains $expected) $"stderr did not contain '($expected)': ($command)"
    assert equal $result.stderr ($result.stderr | ansi strip) "non-TTY stderr must not contain ANSI escapes"
    $result
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

def test-resource-helper-boundaries [] {
    for name in ["jsonplaceholder" "team api.v1" "hyphen-name" "équipe 世界"] {
        assert equal (validate-resource-name "collection" $name) [$name]
    }

    for name in ["" "." ".." "..." "...." "a/b" "a\\b" "/absolute" "C:\\absolute" "C:relative"] {
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

    for name in ["" "." ".." "..." "/auth" "auth/" "auth//login" "auth/../secret" "auth/.../secret" "auth\\.\\login" "C:\\secret"] {
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

    let commands = [
        "api request create '../escape' GET 'https://example.invalid' --collection demo"
        "api request show '..\\escape' --collection demo"
        "api request show '../escape'"
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
    }

    assert equal (open $sentinel --raw) $before
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
    let outside_collection = ($tmp | path join "outside-collection")
    let outside_requests = ($tmp | path join "outside-requests")
    mkdir $root
    mkdir $outside_collection
    mkdir $outside_requests
    $env.API_ROOT = $root
    api init | ignore
    api collection create demo | ignore
    {name: "secret", method: "GET", url: "https://example.invalid"} | to nuon | save -f ($outside_requests | path join "secret.nuon")

    let collection_link = ($root | path join "collections" "escape")
    let request_link = ($root | path join "collections" "demo" "requests" "escape")
    if not (create-directory-link $collection_link $outside_collection) {
        cleanup $tmp
        error make {msg: "SKIP: directory symlink/junction creation unavailable"}
    }
    if not (create-directory-link $request_link $outside_requests) {
        cleanup $tmp
        error make {msg: "SKIP: directory symlink/junction creation unavailable"}
    }

    expect-resource-error { api collection show escape } "existing links cannot escape"
    expect-resource-error { api request show "escape/secret" --collection demo } "existing links cannot escape"
    cleanup $tmp
}

def test-tui-survives-validation-error [] {
    let tmp = (make-temp-dir "resource-tui")
    $env.API_ROOT = $tmp
    api init | ignore
    api collection create demo | ignore

    run-tui-resource-action {
        api collection env create demo "..\\escape"
    }
    api collection env create demo valid-after-error | ignore
    assert (($tmp | path join "collections" "demo" "environments" "valid-after-error.nuon") | path exists)
    cleanup $tmp
}

def run-suite-resource-paths []: nothing -> list<record> {
    print $"\n(ansi yellow)── Resource Path Containment ──(ansi reset)"
    [
        (run-test "resource paths: helper boundaries" { test-resource-helper-boundaries })
        (run-test "resource paths: original attacks blocked" { test-original-attacks-blocked })
        (run-test "resource paths: collection surface" { test-collection-surface })
        (run-test "resource paths: environment surface" { test-environment-surface })
        (run-test "resource paths: nested request lifecycle and body-file compatibility" { test-request-lifecycle-and-explicit-body-file })
        (run-test "resource paths: request command and output surface" { test-request-invalid-command-surface })
        (run-test "resource paths: chain names, steps, and explicit paths" { test-chain-surface-and-explicit-path })
        (run-test "resource paths: vars collection context" { test-vars-collection-context })
        (run-test "resource paths: symlink and junction escapes" { test-symlink-escapes })
        (run-test "resource paths: TUI catches validation errors" { test-tui-survives-validation-error })
    ]
}
