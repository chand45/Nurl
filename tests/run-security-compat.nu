#!/usr/bin/env nu
# Minimum-runtime credential-safety gate using Nushell 0.89-compatible test syntax.

let repo_root = ($env.FILE_PWD | path join ".." | path expand)
source ../api.nu
$env.NURL_REPO_ROOT = $repo_root
$env.API_ROOT = $repo_root

source helpers.nu
source test_command_errors.nu
source test_credential_boundaries.nu
source test_credential_blackbox.nu

let results = [
    ...(run-suite-credential-boundaries)
    ...(run-suite-credential-blackbox)
]
let failed = ($results | where status == "fail" | length)
let skipped = ($results | where status == "skip" | length)

print $"Compatibility security tests: ($results | length), failed: ($failed), skipped: ($skipped)"
if ($failed > 0) or ($skipped > 0) {
    exit 1
}
