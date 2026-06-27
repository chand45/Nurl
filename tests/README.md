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

## Network requirements

Many tests exercise live HTTP APIs:

- https://jsonplaceholder.typicode.com — GET/POST tests
- https://httpbin.org — form-encoding, redirect tests
- https://postman-echo.com — redirect tests

If the network is unavailable the runner detects this automatically and skips
the HTTP-dependent tests instead of failing. Offline tests (pure logic, variable
interpolation, history index structure) always run.

## Test isolation

Every test creates its own temporary directory under `$nu.temp-path` and calls
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
