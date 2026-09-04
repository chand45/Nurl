#!/usr/bin/env nu

let repo_root = ($env.FILE_PWD | path join ".." | path expand)
source ../api.nu
$env.API_ROOT = $repo_root
$env.NURL_REPO_ROOT = $repo_root
source helpers.nu
source test_redirects.nu

let results = (run-suite-redirects)
let failed = ($results | where status == fail)
print $"REDIRECT_COMPAT_TOTAL=($results | length) PASSED=($results | where status == pass | length) FAILED=($failed | length)"
if not ($failed | is-empty) {
    for result in $failed {
        print $"  ($result.name): ($result.error)"
    }
    exit 1
}
