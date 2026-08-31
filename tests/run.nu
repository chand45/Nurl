#!/usr/bin/env nu
# Nurl Test Runner
# Run all test suites and print a PASS/FAIL summary.
#
# Usage:
#   & "C:\Users\cgaddam.REDMOND\AppData\Local\Programs\nu\bin\nu.exe" tests/run.nu
#
# The runner exits with code 0 on all-pass, 1 if any tests failed.
# Network tests are automatically skipped if the internet is unavailable.

# ── Bootstrap (static relative paths required by `source`) ────────────────────

# Load Nurl (sets $env.API_ROOT to repo root via FILE_PWD)
source ../api.nu

# Save repo root so subprocess tests can locate api.nu
# api.nu sets API_ROOT = its own directory (repo root) at source time
$env.NURL_REPO_ROOT = $env.API_ROOT

# Load shared helpers (defines run-test, make-temp-dir, cleanup, network-ok)
source helpers.nu

# Load all test suite files (each defines run-suite-xxx)
source test_reliability.nu
source test_history.nu
source test_output.nu
source test_features.nu
source test_vars.nu
source test_chain.nu
source test_resource_paths.nu
source test_command_errors.nu
source test_auth_replay.nu
source test_credential_boundaries.nu
source test_credential_blackbox.nu
source test_surface_contracts.nu
source test_secure_header_capture.nu
source test_transport_failures.nu
source test_packaging.nu
source test_state_durability.nu
source test_request_headers.nu
source test_request_body.nu

# ── Header ────────────────────────────────────────────────────────────────────

print ""
print $"(ansi blue_bold)╔══════════════════════════════════════╗(ansi reset)"
print $"(ansi blue_bold)║         Nurl Test Suite              ║(ansi reset)"
print $"(ansi blue_bold)╚══════════════════════════════════════╝(ansi reset)"

# ── Network check ─────────────────────────────────────────────────────────────

print "\nChecking network connectivity..."
let net_ok = (network-ok)
if $net_ok {
    print $"(ansi green)✓ Network available — all tests will run(ansi reset)"
} else {
    print $"(ansi yellow)⚠ Network unavailable — HTTP tests will be skipped(ansi reset)"
}

# ── Run all suites ────────────────────────────────────────────────────────────

let all_results = (
    [
        ...(run-suite-vars)            # Offline — runs first (fastest)
        ...(run-suite-status-compatibility)
        ...(run-suite-reliability $net_ok)
        ...(run-suite-history $net_ok)
        ...(run-suite-output $net_ok)
        ...(run-suite-features $net_ok)
        ...(run-suite-chain $net_ok)
        ...(run-suite-resource-paths)
        ...(run-suite-command-errors)
        ...(run-suite-auth-replay)
        ...(run-suite-credential-boundaries)
        ...(run-suite-credential-blackbox)
        ...(run-suite-surface-contracts)
        ...(run-suite-secure-header-capture)
        ...(run-suite-transport-failures)
        ...(run-suite-packaging)
        ...(run-suite-state-durability)
        ...(run-suite-request-headers)
        ...(run-suite-request-body)
    ]
)

# ── Summary ───────────────────────────────────────────────────────────────────

let summary = (summarize-test-results $all_results)
let passed  = $summary.passed
let failed  = $summary.failed
let skipped = $summary.skipped
let total   = $summary.total

print ""
print $"(ansi blue)══════════════════════════════════════(ansi reset)"
print $"(ansi blue)Results(ansi reset)"
print $"(ansi blue)══════════════════════════════════════(ansi reset)"
print $"  Total:   ($total)"
print $"  (ansi green)Passed:  ($passed)(ansi reset)"
if $skipped > 0 {
    print $"  (ansi yellow)Skipped: ($skipped)(ansi reset)"
    print $"  (ansi yellow)Skip reasons:(ansi reset)"
    for reason in $summary.skip_reasons {
        print $"    ($reason.count) x ($reason.reason)"
    }
}
if $failed > 0 {
    print $"  (ansi red)Failed:  ($failed)(ansi reset)"
    print ""
    print $"(ansi red)Failed tests:(ansi reset)"
    for r in ($all_results | where status == "fail") {
        print $"  • ($r.name)"
        print $"    ($r.error)"
    }
    print ""
    exit 1
} else {
    print ""
    if $skipped > 0 {
        print $"(ansi green_bold)✓ All ($passed) tests passed(ansi reset) (ansi yellow)($summary.skip_note)(ansi reset)"
    } else {
        print $"(ansi green_bold)✓ All ($total) tests passed(ansi reset)"
    }
}
