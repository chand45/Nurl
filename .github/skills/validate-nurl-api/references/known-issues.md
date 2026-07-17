# Nurl API — known issues & failure patterns

Patterns surfaced while validating the `api` command surface against `jsonplaceholder`.
Each entry: **symptom → root cause → fix/status → how to re-check**. Use this as a watch-list
when validating new or changed commands — several of these recur whenever a command builds a
request, interpolates variables, or touches `.nuon` files.

> Items marked **FIXED** are regression checks. The rest are environment/behavior notes to
> avoid false bug reports.

---

## 1. Double-encoded string bodies → HTTP 500  (FIXED)
- **Symptom:** `api chain exec`, `api history resend` (POST), and the TUI quick-request returned
  HTTP 500; the server received a JSON-quoted string instead of a JSON object.
- **Root cause:** `api request` declared `--body (-b): record`, but those callers pass an
  **already-serialized JSON string**. `resolve-body` then ran `to json` a second time,
  producing `"\"{...}\""`.
- **Fix:** `-b` is now `any`; when the body is a string it is passed through unchanged, otherwise
  `resolve-body` serializes a record. (`nu_modules/http.nu`, `api request` + `resolve-body`.)
- **Re-check:** `api chain exec example-workflow` (step 1 POST should be 200/201, not 500);
  resend a POST from history and confirm the body arrives as an object.

## 2. `api vars extract` crash on non-structured input  (FIXED)
- **Symptom:** `api chain exec` aborted with `nu::shell::only_supports_this_input_type` when an
  extract path (e.g. `body.id`) ran against an error/string response body.
- **Root cause:** the extractor did `$current | get -o $part` even when `$current` was a string.
- **Fix:** guard checks `describe` for record/list/table before descending; otherwise returns
  `null`. (`nu_modules/vars.nu`, `api vars extract`.)
- **Re-check:** run a chain whose first step errors; the chain should continue/return null,
  not throw.

## 3. `api env *` does not exist — use `api collection env *`  (FIXED)
- **Symptom:** `api tui environments` and `api history resend -e` called `api env list/use/show/create`,
  which are undefined.
- **Root cause:** environment commands are namespaced under `api collection env`.
- **Fix:** `api tui environments` reworked to pick a collection then call `api collection env *`;
  `api history resend -e` no longer calls the missing command — historical URLs are already fully
  resolved, so the backward-compatible env override flag is inert. (`nu_modules/tui.nu`, `history.nu`.)
- **Re-check:** `nu .github/skills/validate-nurl-api/scripts/discover-commands.nu --check-help`
  reports no `api env *` reference; open the TUI environments view.

## 4. Interactive TUI can't be driven by piped stdin
- **Symptom:** scripted/redirected input doesn't advance `api tui *` menus in a non-tty harness.
- **Root cause:** Nushell `input` reads the Windows console device directly, bypassing redirected
  stdin.
- **Status:** environment limitation, not a bug. TUI commands are **smoke/parse-tested** only here
  (they load, render the first menu, and don't throw). Do full interaction in a real terminal.

## 5. Literal ANSI codes in some `print` lines (cosmetic)
- **Symptom:** sequences like `(ansi green)` render as literal text instead of color.
- **Root cause:** the string is a plain `"..."` instead of an interpolated `$"..."`, so `(ansi ...)`
  isn't evaluated. Seen in a few `tui.nu` / `history.nu` prints.
- **Status:** cosmetic; left as-is. If asked to fix, convert the affected `print "..."` to
  `print $"..."`.

## 6. `.nuon` re-serialization churn
- **Symptom:** `git status` shows diffs in `config.nuon` / `*/meta.nuon` / env files after running
  commands, often only whitespace or a trailing newline.
- **Root cause:** commands that persist state re-serialize the whole file with `to nuon`.
- **Status:** expected. Keep the tree clean by restoring touched files: `git checkout -- <file>`.
  `secrets.nuon` and `history/` are gitignored, so they won't appear.

## 7. jsonplaceholder doesn't persist writes
- **Symptom:** `GET /posts/101` after `POST /posts` returns 404 (e.g. `example-workflow` step 2).
- **Root cause:** jsonplaceholder is a mock API; it echoes a created id but stores nothing.
- **Status:** expected. Don't treat the 404 as a chaining bug — assert that the POST and the
  *subsequent* GET ran, not that the resource persisted.

## 8. PowerShell variable expansion mangles inline nu (`-c`) scripts
- **Symptom:** `nu -c "...$res..."` run from PowerShell loses `$res`/`$r`, producing wrong output.
- **Root cause:** PowerShell expands `$name` before nu sees it.
- **Status:** harness gotcha. Write multi-line tests to a `.nu` file and run `nu file.nu`, or keep
  `-c` snippets free of `$`-prefixed nu variables.

## 9. `nu` may not be on PATH
- **Symptom:** `nu: command not found`.
- **Fix:** locate the binary (commonly
  `C:\Users\<you>\AppData\Local\Programs\nu\bin\nu.exe`) and invoke it by full path; see SKILL.md.

## 10. OAuth2 success written to stderr  (FIXED)
- **Symptom:** a successful `api auth oauth2 token <name>` exited 0 but wrote its normal success
  diagnostic to stderr, making clean automation indistinguishable from a warning.
- **Fix:** public token/refresh commands print only secret-free success text on stdout; internal
  request auth uses a private token-returning helper, so access and refresh tokens are never
  rendered by the public commands.
- **Re-check:** use the deterministic local endpoint test in `tests/test_command_errors.nu`;
  obtain and refresh must exit 0 with empty stderr, persist the expected tokens, and emit no
  client secret or token value.

## 11. Duplicate/not-found commands exited successfully  (FIXED)
- **Symptom:** representative collection, environment, saved-request, chain, history, and OAuth2
  duplicate/not-found conditions printed an error on stdout and exited 0.
- **Fix:** these public logical failures now raise one shared Nushell error contract: nonzero exit,
  empty stdout, actionable non-ANSI stderr, and no mutation or network request.
- **Re-check:** run the table-driven subprocess cases in `tests/test_command_errors.nu`.

## 12. Curl transport failures exited successfully and binary retries were destructive  (FIXED)
- **Symptom:** exhausted DNS/connect/TLS/timeout/truncated transfers printed ANSI errors on stdout,
  exited 0, and could create result-shaped fallbacks. `--binary-save` bypassed retries and wrote
  partial bytes directly over an existing destination.
- **Fix:** all transferring surfaces now raise the shared command-error contract after exhausted curl
  failures. Normal and binary paths share `N+1` retry behavior; binary attempts use unique sibling
  files and commit only a complete accepted transfer. Failed attempts create no history or save
  output. HTTP 4xx and final 5xx remain typed exit-0 responses.
- **Re-check:** run `tests/test_transport_failures.nu`; it covers direct, saved, resend, binary, and
  chain surfaces, negative preflight, exact attempts, redaction, and destination preservation.
