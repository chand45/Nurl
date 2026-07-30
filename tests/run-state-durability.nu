#!/usr/bin/env nu
# Focused durability gate for the private native state store, for every
# supported Nushell runtime.

let repo_root = ($env.FILE_PWD | path join ".." | path expand)
source ../api.nu
$env.NURL_REPO_ROOT = $repo_root
$env.API_ROOT = $repo_root

source helpers.nu
source test_state_durability.nu

let expected_names = [
    "SD-R1: compact NUON state is byte-exact with no trailing newline"
    "SD-R1: indented NUON state is byte-exact with no trailing newline"
    "SD-R1: replacement leaves no .<basename>.nurl-*.tmp artifacts"
    "SD-R1: binary state corruption fails closed on read"
    "SD-R2: Windows publish failure preserves prior destination bytes"
    "SD-R3: killing a public create mid-write leaves a partial file and fails closed on show"
    "SD-R4: N=8 barrier-synchronized chain create preserves complete contender payloads"
    "SD-R5: syntax-corrupted state fails closed across every file type"
    "SD-R5: wrong-shape state fails closed across every file type"
    "SD-R5: binary-corrupted state fails closed across every file type"
    "SD-R5: missing state files retain current defaults"
    "SD-R5: genuine I/O read failures propagate distinctly from parse failures"
    "SD-R5: reader I/O boundary is structurally fail-open to native errors"
    "SD-R5: public history config read fails closed without entry/index writes"
    "SD-R6: read-only sweep across state surfaces is byte-stable"
    "SD-R6: credential and secrets key order is preserved"
    "SD-R7: fresh and unrelated same-destination siblings are left untouched"
    "SD-R7: aged, removable same-destination siblings are swept silently"
    "SD-R7: aged, unremovable siblings warn but still commit the requested write"
    "SD-R8: recursive lifecycle (incl. collection copy) leaves zero private artifacts"
    "SD-R8: artifact scanner discriminates exact generated patterns"
    "SD-R8: read-only lifecycle against the bundled tracked workspace leaves git status unchanged"
    "SD-R9: Windows long path and case-alias lifecycle"
    "SD-R9: Windows 8.3 short-name alias lifecycle (best-effort)"
    "SD-R9: POSIX real workspace leaf reached under a symlinked ancestor"
    "SD-R9: POSIX replacement preserves existing mode bits"
    "SD-R9: destination-file symlink replacement preserves the symlink and updates its target"
    "SD-R10: fresh full state lifecycle under PATH='' succeeds with no external-command failures"
    "SD-R11: concurrent first `api init` (N=8) stays clean with no setup artifacts"
    "SD-R12: production source forbids the listed leakage/locking/hardening patterns"
    "SD-R12: state-store.nu is installer-listed but not export-used from mod.nu"
    "SD-R12: no-clobber create is one direct bare save"
    "SD-R13: chain normalization across list/heterogeneous/empty/record shapes"
    "SD-R13: chain exec named+explicit-path normalization; chain show rejects explicit paths"
    "SD-R14: Windows replacement destination inherits directory ACL policy"
]

# Tests that are legitimately OS/capability-gated and are allowed to report
# "skip" without that counting as a regression. Every other skip is treated
# as a failure so real coverage gaps can never pass silently.
let allowed_skip_names = [
    "SD-R2: Windows publish failure preserves prior destination bytes"
    "SD-R3: killing a public create mid-write leaves a partial file and fails closed on show"
    "SD-R5: genuine I/O read failures propagate distinctly from parse failures"
    "SD-R9: Windows long path and case-alias lifecycle"
    "SD-R9: Windows 8.3 short-name alias lifecycle (best-effort)"
    "SD-R9: POSIX real workspace leaf reached under a symlinked ancestor"
    "SD-R9: POSIX replacement preserves existing mode bits"
    "SD-R9: destination-file symlink replacement preserves the symlink and updates its target"
    "SD-R14: Windows replacement destination inherits directory ACL policy"
]

let results = (run-suite-state-durability)
let actual_names = ($results | get name)

if $actual_names != $expected_names {
    error make {msg: $"State durability runner expected ($expected_names | to nuon), got ($actual_names | to nuon)"}
}

let failed = ($results | where status == "fail")
let skipped = ($results | where status == "skip")
let unexpected_skips = ($skipped | where {|r| $r.name not-in $allowed_skip_names })

print $"State durability tests: ($results | length), failed: ($failed | length), skipped: ($skipped | length)"
for s in $skipped {
    print $"  (ansi yellow)⚠(ansi reset) ($s.name): ($s.error)"
}

if ($failed | length) > 0 {
    print ""
    print "Failed tests:"
    for f in $failed {
        print $"  • ($f.name)"
        print $"    ($f.error)"
    }
}

if (($failed | length) > 0) or (($unexpected_skips | length) > 0) {
    if ($unexpected_skips | length) > 0 {
        print ""
        print "Unexpected (non-allow-listed) skips:"
        for s in $unexpected_skips {
            print $"  • ($s.name): ($s.error)"
        }
    }
    exit 1
}
