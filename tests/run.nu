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

let report = (render-test-summary $all_results)
for line in $report.lines {
    print $line
}
if $report.exit_code != 0 {
    exit $report.exit_code
}
