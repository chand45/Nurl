#!/usr/bin/env nu
# Focused offline credential-safety gate for the supported Nushell runtime matrix.

source ../api.nu
$env.NURL_REPO_ROOT = $env.API_ROOT

source helpers.nu
source test_command_errors.nu
source test_auth_replay.nu
source test_credential_boundaries.nu
source test_credential_blackbox.nu
source test_surface_contracts.nu
source test_secure_header_capture.nu

let results = [
    ...(run-suite-auth-replay)
    ...(run-suite-credential-boundaries)
    ...(run-suite-credential-blackbox)
    ...(run-suite-secure-header-capture)
]
let failed = ($results | where status == "fail" | length)
let skipped = ($results | where status == "skip" | length)

print $"Security tests: ($results | length), failed: ($failed), skipped: ($skipped)"
if $failed > 0 or $skipped > 0 {
    exit 1
}
