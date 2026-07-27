#!/usr/bin/env nu

source ../api.nu
$env.NURL_REPO_ROOT = $env.API_ROOT
source helpers.nu
source test_packaging.nu

let results = (run-suite-packaging)
let failed = ($results | where status == "fail")
let skipped = ($results | where status == "skip")
print $"Packaging results: total=($results | length) passed=($results | where status == 'pass' | length) skipped=($skipped | length) failed=($failed | length)"
if ($failed | is-not-empty) {
    exit 1
}
