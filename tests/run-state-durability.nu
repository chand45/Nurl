#!/usr/bin/env nu

let repo_root = ($env.FILE_PWD | path join ".." | path expand)
source ../api.nu
$env.NURL_REPO_ROOT = $repo_root
$env.API_ROOT = $repo_root

source helpers.nu
source test_state_durability.nu

let results = (run-suite-state-durability)
let failed = ($results | where status == fail)
let skipped = ($results | where status == skip)
let allowed_skips = [
    "SD16 POSIX I/O propagation"
    "SD16 Windows I/O propagation"
    "SD17 POSIX present unreadable never defaults"
    "SD17 Windows present unreadable never defaults"
    "SD13 POSIX symlink ancestor and mode"
    "SD14 Windows alias paths"
    "SD20 Windows inherited state ACL"
    "SD25 Windows native fallback characterization"
    "SD24 POSIX native fallback counterfixtures"
]
let unexpected_skips = ($skipped | where {|result| $result.name not-in $allowed_skips })

print $"State durability tests: ($results | length), failed: ($failed | length), skipped: ($skipped | length)"
if ($failed | length) > 0 {
    for failure in $failed {
        print $"FAIL ($failure.name): ($failure.error)"
    }
}
if ($unexpected_skips | length) > 0 {
    for skip in $unexpected_skips {
        print $"UNEXPECTED SKIP ($skip.name): ($skip.error)"
    }
}
if (($failed | length) > 0) or (($unexpected_skips | length) > 0) {
    exit 1
}
