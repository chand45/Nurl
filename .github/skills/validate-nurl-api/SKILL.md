---
name: validate-nurl-api
description: >-
  Validate every Nurl `api ...` command against the bundled `jsonplaceholder`
  collection. Use when verifying the Nurl CLI end-to-end, after adding or
  changing `api` commands, when running a regression pass on the command
  surface, or when you need to detect coverage gaps between the code and the
  test matrix. Includes a discovery script that auto-detects new/renamed/removed
  commands so the process stays correct as Nurl grows.
---

# Validate Nurl API commands

Nurl is a Nushell-based terminal API client ("curl + nushell Postman replacement"). Its
user-facing surface is the set of `api ...` commands exported from `nu_modules/*.nu`. This
skill is the repeatable process for exercising **all** of them against the example
`jsonplaceholder` collection, plus the tooling to keep that process in sync as commands change.

## When to use
- Full end-to-end validation / regression of the Nurl CLI.
- After adding, renaming, or removing any `api` command (run the discovery step first).
- When a request-building, variable-interpolation, or `.nuon`-persisting change could regress
  multiple commands at once.

## What's in this skill
| File | Purpose |
|---|---|
| `SKILL.md` | This methodology. |
| `coverage.nuon` | Manifest of every `api *` export, classified `command` / `internal` / `tui`, each mapped to a test. The extensibility engine. |
| `scripts/discover-commands.nu` | Parses module exports and diffs them against the manifest; reports uncovered/stale/help-drift; non-zero exit on gaps (CI-gateable). |
| `references/command-matrix.md` | Per-group, per-command runnable test + expected result. |
| `references/known-issues.md` | Failure patterns to watch for (3 fixed bugs + behavioral/harness gotchas). |

Throughout, `<repo>` is the Nurl repo root and `nu` is the Nushell binary (resolve its path first).

---

## Environment setup
1. **Find `nu`.** It may not be on PATH. Common location on Windows:
   `C:\Users\<you>\AppData\Local\Programs\nu\bin\nu.exe`. Invoke it by full path if needed.
2. **Source Nurl with an absolute path** so `API_ROOT` resolves to the repo (api.nu derives it
   from `FILE_PWD`): `source C:\path\to\Nurl\api.nu`.
3. **Verify it loaded:** `api help` prints the curated command groups.
4. **Network check** (validation hits the live mock API):
   `curl -s -o NUL -w "%{http_code}" https://jsonplaceholder.typicode.com/posts/1` → `200`.
   Offline? Add `-d` / `--dry-run` to request commands to print the curl instead of executing.
5. **Harness note:** PowerShell expands `$x` before nu sees it. For anything containing nu
   variables, write a `.nu` script and run `nu script.nu` instead of `nu -c "...$x..."`.

## Validation workflow

### 1. Enumerate the command surface (and close gaps first)
Run the discovery script — this is the authoritative list of what exists and whether the test
matrix covers it:
```
nu .github/skills/validate-nurl-api/scripts/discover-commands.nu --check-help
```
- **PASS / exit 0** → manifest is in sync; proceed.
- **UNCOVERED** → a command exists in code but not in `coverage.nuon`. **Extend before testing**
  (see "Extending"). 
- **STALE** → a manifest entry no longer exists in code; remove/rename it.
- **HELP DRIFT** → `api help` advertises a command that isn't defined; fix help or code.

### 2. Build/refresh the test matrix
For each `command`-kind entry, use the concrete invocation in `references/command-matrix.md`
(grouped: setup, variables, collections, collection-env, auth, requests, saved-requests,
history, chaining, tui). The manifest's `test` field is the short form; the matrix has expected
results and cleanup steps.

### 3. Execute by group, capture results
- Run **one nu script per group** (sourcing api.nu once), not many `-c` one-liners.
- **Idempotent** commands (list/show/get/status, GET): run directly.
- **Mutating** commands (create/set/update/delete, collections/envs/requests/auth/chains): use a
  temp name (`tmp-*`) and clean up in the same script.
- Assert on HTTP results with `-r` / `--raw` then `.response.status` (200/201/...).

### 4. Validate side-effecting & chained flows
These exercise the internal helpers and the trickiest code paths:
- `api send <name> -c jsonplaceholder -r` for **every** saved request — checks `{{base_url}}`
  interpolation from the active env.
- `api chain exec example-workflow` and the list form `api chain run (open chains/example-workflow.nuon | get steps)`
  — checks request loading, `vars extract`, and value passing. (Step-2 404 is expected, see
  known-issues #7.)
- `api history resend <id>` — especially a **POST** (guards against body double-encoding).
- Apply auth to a live request: add `-a {type: bearer, token_ref: tmpcred}` and confirm the
  header is sent.

### 5. Smoke-test the TUI
`api tui` and its sub-views are interactive; in a non-tty harness confirm each **loads and
renders its first menu without throwing**, then move on. Full interaction needs a real terminal
(known-issues #4).

### 6. Keep the tree clean, fix gaps, regress
- Restore re-serialized files: `git checkout -- config.nuon collections/**/meta.nuon ...`
  (`secrets.nuon` and `history/` are gitignored).
- For each failure: locate the `export def` in `nu_modules/`, make a **surgical** fix, re-run that
  group, then re-run a short cross-group regression. Record any new pattern in
  `references/known-issues.md`.

---

## Extending (when commands are added or changed)
The manifest is **data**, so extension needs no script edits:
1. Run `discover-commands.nu` → it flags the new command as **UNCOVERED** (with its file).
2. Add a record to `coverage.nuon`:
   `{ command: "api <x>", kind: command|internal|tui, group: <group>, test: "<invocation>" }`
   - `command` — user-facing; gets a dedicated test.
   - `internal` — helper/primitive (record args or engine-invoked); exercised indirectly.
   - `tui` — interactive; smoke/parse-tested only.
3. Add a matching row to `references/command-matrix.md` with the invocation + expected result.
4. Re-run discovery until it reports **PASS / exit 0**, then run the new test.

For a renamed/removed command, discovery reports **STALE** — update or delete the manifest entry
(and matrix row) to match.

## CI / gating
`discover-commands.nu` exits non-zero on any uncovered or stale command, so it can run in CI to
fail the build when someone adds an `api` command without registering it here. Use `--json` for
machine-readable output.

## References
- `references/command-matrix.md` — the runnable per-command tests.
- `references/known-issues.md` — failure patterns (double-encoded bodies, `vars extract` crash,
  `api env` vs `api collection env`, tty/input limits, ansi, `.nuon` churn, jsonplaceholder
  non-persistence, PowerShell `$` expansion, `nu` not on PATH).
