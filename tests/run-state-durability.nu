#!/usr/bin/env nu
# Cross-platform state durability gate for every supported Nushell runtime.

let repo_root = ($env.FILE_PWD | path join ".." | path expand)
source ../api.nu
$env.NURL_REPO_ROOT = $repo_root
$env.API_ROOT = $repo_root

if ($env.NURL_STATE_SESSION_TOKEN? | default "" | is-empty) {
    error make {msg: "api.nu did not initialize the state-store process token"}
}

source helpers.nu
source test_state_durability.nu

let results = (run-suite-state-durability)
let failed = ($results | where status == "fail" | length)
let skipped = ($results | where status == "skip" | length)

print $"State durability tests: ($results | length), failed: ($failed), skipped: ($skipped)"
if ($failed > 0) or ($skipped > 0) {
    exit 1
}
