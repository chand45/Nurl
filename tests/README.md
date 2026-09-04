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

The runner prints a colour-coded PASS/FAIL summary with deterministic counts for
each recorded skip reason. It exits with code 0 (all passed) or 1 (one or more
failures).

Credential-safety gates can also run independently without external services:

```powershell
# Current Nushell: exhaustive auth plus focused boundary/security suites
nu --no-config-file tests/run-security.nu

# Documented minimum Nushell 0.89-compatible boundary and black-box suites
nu --no-config-file tests/run-security-compat.nu

# Deterministic Nushell 0.89 request-header identity and preview subset
nu --no-config-file tests/run-header-compat.nu

# Structured request-body serialization, replay, chain, and injection regressions
nu --no-config-file tests/run-body-compat.nu

# Best-effort native state replacement, final-state detector, reader, lifecycle, and compatibility gates
nu --no-config-file tests/run-state-durability.nu

# Redirect method/body, credential-boundary, retry, output, and binary compatibility
nu --no-config-file tests/run-redirect-compat.nu
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
| `test_command_errors.nu` | Public error streams plus exact OAuth client-credentials and refresh form bodies |
| `test_auth_replay.nu` | Credential-safe previews, canonical history auth metadata, replay rotation, URL/header policy, and OAuth failures |
| `test_credential_boundaries.nu` | Live response-header and config/environment/extra-variable interpolation boundaries |
| `test_credential_blackbox.nu` | Nine independent public-CLI reproductions with literal policy tables and byte/network mutation checks |
| `test_secure_header_capture.nu` | Fileless curl response parsing, sensitive live response masking, trailers, redirects, and transport artifacts |
| `test_state_durability.nu` | Best-effort sibling-temp replacement, raw-byte final-state detection, Windows sharing/byte-lock and POSIX sticky-directory fallback characterization, observational concurrent-reader evidence, persistence inventory, main-parity creates, fail-closed readers, runtime-qualified stale cleanup streams, copy fidelity, path aliases, and chain shapes |
| `test_request_headers.nu` | ASCII case-insensitive request-header identity, stable precedence/order, byte-exact UTF-8 form encoding/validation, managed-auth and ambiguous-record preflights, legacy history, and preview/export wire fidelity |
| `test_request_body.nu` | Dependency-resolved trusted maps shared across URL/headers/structured JSON/forms, null preservation, body-file injection safety, literal-brace URL transport, typed opaque extracts through run/exec, table replay/chains, literal header names, preview/export fidelity, and credential masking |
| `test_redirects.nu` | Hermetic two-port redirect method/body, origin credential, target safety, retry/deadline, result/history/output, and binary contracts |
| `run-security.nu` | Current-runtime focused security runner |
| `run-security-compat.nu` | Minimum-runtime 13-test hermetic boundary and black-box runner |
| `run-header-compat.nu` | Minimum-runtime deterministic request-header dedup, form, auth-collision, and preview subset |
| `run-body-compat.nu` | Minimum/current-runtime structured body, replay, chain, and injection regression runner |
| `run-state-durability.nu` | Cross-runtime durability runner with auditable OS-specific executed/skipped evidence |
| `run-send-compat.nu` | Minimum/current-runtime hermetic `api send` discovery and byte-exact transport runner |
| `run-redirect-compat.nu` | Minimum/current-runtime hermetic redirect compatibility runner |
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
checksums for Windows and Linux. It runs the minimum-compatible security, request-header, and request-body gates
on 0.89.0, the broader focused security gate on the current runtime, and the durability runner on
all four Windows/Ubuntu runtime cells. Linux logs include the non-root uid and explicit execution
markers for the permission-denied reader fixtures and the Nu 0.89 sticky-directory
destructive-fallback counterfixture. The full suite and command discovery remain separate
current-runtime jobs.

`.github/workflows/send-compatibility.yml` pins verified Nushell 0.89.0 and 0.114.1 artifacts
for Windows and Linux and runs the hermetic saved-request and byte-exact transport gate.
