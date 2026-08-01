#!/usr/bin/env nu
# Structured request-body compatibility gate for supported Nushell runtimes.

let repo_root = ($env.FILE_PWD | path join ".." | path expand)
source ../api.nu
$env.NURL_REPO_ROOT = $repo_root
$env.API_ROOT = $repo_root

source helpers.nu
source test_request_body.nu

let results = (run-suite-request-body-compat)
let failed = ($results | where status == "fail" | length)
let skipped = ($results | where status == "skip" | length)

print $"Request-body compatibility tests: ($results | length), failed: ($failed), skipped: ($skipped)"
if ($failed > 0) or ($skipped > 0) {
    exit 1
}
