# Nurl Test Suite

This directory contains the comprehensive test suite for Nurl.

## Running the tests

```powershell
& "C:\Users\cgaddam.REDMOND\AppData\Local\Programs\nu\bin\nu.exe" tests/run.nu
```

Or from a Nushell session:

```nu
source tests/run.nu
```

The runner prints a colour-coded PASS/FAIL summary and exits with code 0 (all
passed) or 1 (one or more failures).

Credential-safety gates can also run independently without external services:

```powershell
# Current Nushell: exhaustive auth plus focused boundary/security suites
nu --no-config-file tests/run-security.nu

# Documented minimum Nushell 0.89-compatible boundary and black-box suites
nu --no-config-file tests/run-security-compat.nu
```

## Network requirements

Many tests exercise live HTTP APIs:

- https://jsonplaceholder.typicode.com — GET/POST tests
- https://httpbin.org — form-encoding, redirect tests
- https://postman-echo.com — redirect tests

If the network is unavailable the runner detects this automatically and skips
the HTTP-dependent tests instead of failing. Offline tests (pure logic, variable
interpolation, history index structure) always run.

## Test isolation

Every test creates its own runtime temporary directory and calls
`api init` there. No test ever writes to the user's real `~/.nurl` directory,
the repo's `collections/`, or the project `history/`. Temp directories are
cleaned up after each test.

## Test files

| File | Coverage |
|------|----------|
| `helpers.nu` | Shared infrastructure: `make-temp-dir`, `cleanup`, `init-workspace`, `run-test`, `skip-test`, `network-ok` |
| `test_reliability.nu` | A1-A7: Display output contract, history resend, status codes, OS paths, `--no-history` |
| `test_history.nu` | B1: History index — append, sort, list, search, rebuild |
| `test_output.nu` | C1-C3: `--raw`, `--output` modes, `--select` path normalization, `--verbose`, `--include` |
| `test_features.nu` | C4-C11: `--form`, `--save`, `--follow-redirects`, saved-request tests, `--retries`, content-type, `api head`/`api options`, `api request export` |
| `test_vars.nu` | Vars: `{{var}}` interpolation, builtins (`{{$uuid}}`, `{{$timestamp}}`), `api vars extract` dot-path, precedence |
| `test_chain.nu` | Chain: POST+GET, string body, variable extraction, `--stop-on-error` |
| `test_auth_replay.nu` | Credential-safe previews, canonical history auth metadata, replay rotation, URL/header policy, and OAuth failures |
| `test_credential_boundaries.nu` | Live response-header and config/environment/extra-variable interpolation boundaries |
| `test_credential_blackbox.nu` | Nine independent public-CLI reproductions with literal policy tables and byte/network mutation checks |
| `test_secure_header_capture.nu` | Fileless curl response parsing, sensitive live response masking, trailers, redirects, and transport artifacts |
| `test_state_durability.nu` | Atomic state bytes, genuine failure preservation, corruption/shape/I/O errors, record-or-list chains, protected temp DACL/mode behavior, stale lock cleanup, no-clobber, and read-only byte stability |
| `run-security.nu` | Current-runtime focused security runner |
| `run-security-compat.nu` | Minimum-runtime 13-test hermetic boundary and black-box runner |
| `run-state-durability.nu` | Cross-platform state durability gate for Nushell 0.89.0 and current |
| `run.nu` | Main runner — sources all suites, prints summary, exits non-zero on failure |

## Adding a new test

1. Pick the appropriate `test_*.nu` file (or create a new one for a new area).
2. Write a `def test-xxx-description []` function that:
   - Calls `make-temp-dir "prefix"` and sets `$env.API_ROOT = $tmp`
   - Calls `cleanup $tmp` at the end (even on error paths, if practical)
   - Uses `assert` / `assert equal` from `use std assert`
3. Add it to the suite's `run-suite-xxx` function with a call to `run-test "description" { test-xxx-description }`.
4. If the test requires network, guard the suite with `if not $net_ok { return [...] }` (already done in all network suites).

## Continuous integration

Because the runner exits non-zero on any failure, you can gate CI on it:

```powershell
& "C:\Users\cgaddam.REDMOND\AppData\Local\Programs\nu\bin\nu.exe" tests/run.nu
if ($LASTEXITCODE -ne 0) { throw "Tests failed" }
```

`.github/workflows/security-compatibility.yml` pins official Nushell release artifacts and
checksums for Windows and Linux. It runs the minimum-compatible security gate on 0.89.0, the
broader focused security gate on the current runtime, and keeps the full suite and command
discovery as separate current-runtime jobs.
