#!/usr/bin/env nu
# Hosted link-capability gate for the dangling contained-alias recovery path.

source ../api.nu
$env.NURL_REPO_ROOT = $env.API_ROOT

source helpers.nu
source test_history.nu

let result = (run-test "B1: exceptional recovery drops dangling contained aliases" {
    test-b1-clear-recovery-drops-dangling-contained-alias
})
if $result.status != "pass" {
    exit 1
}
