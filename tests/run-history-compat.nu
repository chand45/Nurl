#!/usr/bin/env nu
# Focused history equivalence gate for every supported Nushell runtime.

let repo_root = ($env.FILE_PWD | path join ".." | path expand)
source ../api.nu
$env.NURL_REPO_ROOT = $repo_root
$env.API_ROOT = $repo_root

source helpers.nu
source test_history.nu

let expected_names = [
    "B1: canonical, reverse, and shuffled indexes preserve read surfaces"
    "B1: legacy, offset, tied, and malformed timestamps preserve fallback order"
    "B1: unusable index shapes rebuild equivalently"
    "B1: workspace-derived ID resolution preserves exact, ambiguity, stale, and case behavior"
    "B1: unsorted indexes retain monotonic persistence"
    "B1: history save loads the index exactly once"
    "B1: history locks support percent-bearing roots and index-free rebuilds"
]
let results = (run-suite-history-compatibility)
let actual_names = ($results | get name)
let failed = ($results | where status == "fail" | length)
let skipped = ($results | where status == "skip" | length)

if $actual_names != $expected_names {
    error make {msg: $"History compatibility runner expected ($expected_names | to nuon), got ($actual_names | to nuon)"}
}

print $"History compatibility tests: ($results | length), failed: ($failed), skipped: ($skipped)"
if ($failed > 0) or ($skipped > 0) {
    exit 1
}
