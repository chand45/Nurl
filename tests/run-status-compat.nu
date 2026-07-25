#!/usr/bin/env nu
# Focused api status contract gate for every supported Nushell runtime.

let repo_root = ($env.FILE_PWD | path join ".." | path expand)
source ../api.nu
$env.NURL_REPO_ROOT = $repo_root
$env.API_ROOT = $repo_root

source helpers.nu
source test_reliability.nu

let expected_names = [
    "V1: api status reports typed unset context"
    "V1: api status reports configured collection and environment"
    "V1: api status rejects invalid configured context"
]
let results = (run-suite-status-compatibility)
let actual_names = ($results | get name)
let failed = ($results | where status == "fail" | length)
let skipped = ($results | where status == "skip" | length)

if $actual_names != $expected_names {
    error make {msg: $"Status compatibility runner expected ($expected_names | to nuon), got ($actual_names | to nuon)"}
}

print $"Status compatibility tests: ($results | length), failed: ($failed), skipped: ($skipped)"
if ($failed > 0) or ($skipped > 0) {
    exit 1
}
