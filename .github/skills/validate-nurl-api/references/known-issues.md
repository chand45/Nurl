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

## 13. Auth previews leaked secrets and authenticated history resent without auth  (FIXED)
- **Symptom:** basic/API-key dry-run and request export rendered wire credentials. History omitted
  auth metadata, so default resend silently downgraded authenticated requests to unauthenticated.
- **Fix:** auth preparation now has separate display, wire, and canonical replay projections.
  Preview/export masks supported auth and sensitive headers without OAuth acquisition. Named refs
  are stored without secrets and re-resolved on resend; inline auth is stored as non-replayable and
  requires an explicit `--auth` override.
- **Re-check:** run `tests/test_auth_replay.nu`; it covers rotation, override precedence, legacy
  history, invalid refs, no-side-effect failures, query fragments, and the preview/export matrix.

## 14. Direct history saves could bypass credential sanitization  (FIXED)
- **Symptom:** a caller could pass inline auth or sensitive headers to `api history save`, then
  recover the values through history bytes, index, show/get, or export. Arbitrary top-level or
  nested credential-shaped metadata could also bypass field-specific sanitization.
- **Fix:** `api history save` is now the shared persistence boundary for live and synthetic saves.
  It constructs allowlisted request/response records, validates field shapes and named refs from
  local credential metadata, makes inline auth non-replayable, masks sensitive headers, and omits
  unknown metadata before creating or modifying history state. Response bodies remain unchanged.
- **Re-check:** run the direct-save cases in `tests/test_auth_replay.nu`; verify no sentinel exists
  in persisted bytes or any public history projection, legacy fixtures are not migrated, and
  invalid schemas/refs/auth cause no mutation.

## 15. Query API keys could alter URL structure  (FIXED)
- **Symptom:** reserved characters in a query API-key name or value could create extra parameters,
  truncate the credential at `#`, or otherwise change request semantics.
- **Fix:** query API-key names and wire values are RFC 3986 query-component encoded exactly once.
  Existing queries and fragment placement are preserved; previews encode the name and mask the value.
- **Re-check:** run `tests/test_auth_replay.nu`; its local server covers `&`, `=`, `#`, `%`, `+`,
  spaces, Unicode, existing/empty queries, fragments, rotation, override, saved requests, and chains.

## 16. OAuth provider descriptions could echo credentials  (FIXED)
- **Symptom:** token or refresh failures emitted an untrusted provider `error_description`, which
  could contain a client secret, access token, or refresh token. Non-2xx responses with
  success-shaped JSON were also accepted, while malformed 2xx token records were insufficiently
  validated.
- **Fix:** OAuth rejects all non-2xx responses before token use/persistence and validates the
  required and optional fields of every accepted 2xx token record. Failures omit response
  descriptions/bodies and report only a validated provider code (or `unknown_error`) plus status.
  A refresh provider error is not retried as a new token request or allowed to overwrite old tokens.
- **Re-check:** run the initial-token and refresh error cases in `tests/test_auth_replay.nu`; they
  cover 3xx/4xx/5xx success-shaped bodies and malformed 2xx shapes, asserting secret-free,
  non-ANSI stderr, exact endpoint counts, and no history/output/state mutation.

## 17. Credential-bearing URLs could bypass safe history auth metadata  (FIXED)
- **Symptom:** URL userinfo or recognized credential query/fragment parameters were copied into
  history entries and the index, exposed by readers/exports, and reused by resend.
- **Fix:** one shared classifier now rejects userinfo and exact sensitive parameter names after
  interpolation and strict percent decoding, before wire auth, OAuth acquisition, network, output,
  or history mutation. It does not inspect arbitrary paths, parameter values, or bodies. Managed
  query auth is appended afterward and remains replayable through its safe named reference.
- **Compatibility:** existing history bytes are not migrated and remain readable, but resend
  revalidates the stored URL and refuses unsafe legacy entries before network access.
- **Re-check:** run the secret-URL preflight case in `tests/test_auth_replay.nu`; it covers direct
  save, direct/saved/chain execution, safe lookalike names, managed query auth, all history readers
  and exports, malformed encodings, and a byte-stable legacy resend rejection.

## 18. Password aliases were absent from URL and header credential classification  (FIXED)
- **Symptom:** exact `password` URL parameters and `X-Password` request headers could persist or
  appear in previews because token/key/client-secret names were classified but password aliases
  were not.
- **Fix:** the shared normalized exact-name policy includes `password`, `passwd`, and `pwd`, plus
  their exact `X-`/`X_` header forms. URL matching remains exact after percent decoding, so
  lookalikes such as `password_hint`, `compass`, and `pwd_reset_status` remain valid. Managed query
  auth may intentionally use `password` because Nurl appends and masks it after caller-URL preflight.
- **Re-check:** run the independent password policy case in `tests/test_auth_replay.nu`; its
  literal expectation tables cover URL variants, request/response headers, history/read/export
  boundaries, resend mask rejection, safe lookalikes, and managed query-key rotation.

## 19. Live sensitive response headers could escape through typed outputs  (FIXED)
- **Symptom:** response-header values were sanitized for history and human rendering but remained
  available in `--raw`, `--output headers|json`, and `--select`.
- **Fix:** recognized sensitive response headers are now masked before constructing the public
  result record. The record shape, body/status values, exact safe headers, trailers, redirects,
  and output-mode types remain unchanged.
- **Re-check:** run `tests/test_credential_boundaries.nu` and `tests/test_secure_header_capture.nu`;
  they exercise the live curl parser through typed/human/machine outputs, history/index/read/export,
  trailers, redirects, exact password-family names, and safe boundary lookalikes.

## 20. Same-second history recency and partial IDs were nondeterministic  (FIXED)
- **Symptom:** rapid saves shared a second-only timestamp, so list/search/rebuild order depended on a
  random ID suffix, export used filename order, and an ambiguous partial ID silently selected one
  entry. Negative limits leaked a low-level Nushell error.
- **Fix:** new saves use monotonic nine-digit fractional RFC3339 UTC timestamps derived consistently
  with their date directory and ID time component. One numeric newest-first ordering now drives the
  index, list, search, rebuild, and JSON/CSV export. Exact IDs win; only unique prefix/middle/suffix
  fragments resolve. Ambiguous fragments and negative limits use the shared clean error contract
  before index, output, auth, network, or replay work. Legacy files remain unchanged and readable;
  malformed timestamps sort deterministically last.
- **Re-check:** run `tests/test_history.nu`, the history cases in `tests/test_command_errors.nu`, and
  `tests/test_surface_contracts.nu`; they cover ten-entry no-sleep bursts, rebuilds, mixed/tied/
  malformed timestamps, every export/limit surface, exact/unique/ambiguous IDs, and zero endpoint or
  OAuth events on ambiguity.

## 21. Partial history clear and rebuild could silently desynchronize the index  (FIXED)
- **Symptom:** recursive clear could delete files before a later delete error while leaving their
  index rows visible. A successful deletion followed by a strict rebuild failure had the same stale
  result, and partial `--all` failure bypassed recovery. Duplicate or injected hints could also
  survive exceptional reconciliation. Full rebuild treated traversal or entry-read failures as
  empty/malformed data, replaced the index, and printed success after silently dropping existing
  unreadable entries.
- **Fix:** clear captures validated canonical index hints and exact raw index bytes before mutation.
  Every delete or post-delete rebuild error reconciles those hints against contained surviving
  entry paths without opening locked files, persists an exact-schema unique canonical index, then
  rethrows the original contextual error. Unsafe, stale, mismatched, and non-file hints are dropped
  individually; compatible duplicates are collapsed; injected fields are removed; and contained
  logical aliases are normalized to direct regular `.nuon` files. Dangling, external, directory,
  and non-NUON aliases are ignored. Only conflicts among surviving safe paths produce a composed
  reconciliation error. If reconciliation is impossible after the index changed or disappeared,
  the captured bytes are restored exactly; restoration failure is added without replacing the
  original clear error. Partial `--all` failures use the same recovery. Normal explicit/automatic
  rebuilds require a complete traversal and raw read of every entry; genuine I/O failures propagate
  before index replacement, while text/binary invalid NUON and non-entry content remain
  deterministically skippable for compatibility.
- **Re-check:** run `tests/test_history.nu`; the clear failure fixtures use barrier-synchronized
  Windows locks or POSIX permissions with no sleeps, and assert exact index/list/search/get/export
  agreement after later-directory, first-directory, post-delete rebuild, dangling-alias, and partial
  `--all` failures. Unsafe/duplicate/conflicting-hint fixtures verify canonical unique recovery,
  explicit combined failure, and byte-exact restoration when `--all` removes the index before
  reconciliation is rejected. Rebuild fixtures prove valid and invalid prior index bytes remain
  unchanged on unreadable-entry failures.

## 22. Concurrent same-name creates are not exclusive
- **Symptom:** two processes creating the same new collection, environment, request, or chain can both
  report success, with one complete contender payload surviving.
- **Root cause:** supported Nushell versions implement bare `save` as an existence check followed by
  create-plus-truncate, not atomic create-new (`O_EXCL`/`CREATE_NEW`). This is the same pre-existing
  TOCTOU behavior as Nurl `main`.
- **Status:** retained limitation. Nurl preserves the existing advisory duplicate messages for
  sequential use but does not claim atomic, exclusive, or exactly-one-winner create semantics. Locks,
  markers, sidecars, retries, and external synchronization are intentionally not added.
- **Re-check:** run `tests/run-state-durability.nu`. Gates A and B pin the direct bare-save shape and
  sequential byte preservation; Gate C records winner counts only as characterization while asserting
  complete parseable output, allowed outcomes, and no artifacts.

## 23. Hard termination can leave a sibling state temporary file
- **Symptom:** forced termination or power loss between temporary-file creation and publication can
  leave `.<name>.nurl-<uuid>.tmp` beside a state file. A `secrets.nuon` sibling may contain credential
  bytes.
- **Status:** retained limitation. On non-Windows updates to an existing destination, a sibling copies
  that file's basic mode bits; on Windows and for new destinations, it receives the directory's
  default create permissions. No owner-only permission is claimed. Cleanup runs only before a later
  write to the exact destination: fresh files remain untouched and aged removable files are deleted
  silently. Structured-removal runtimes produce one plain-text path and manual-removal warning for an
  unremovable file. Nushell 0.89 emits its single native removal diagnostic instead (path, OS detail,
  Nurl source span, and ANSI only on a TTY), without a duplicate Nurl warning. Neither stream includes
  state-file or credential content, and the current write continues. There is no global background
  sweeper, so an orphan may require manual removal.
- **Re-check:** run the stale sibling policy and PATH-empty lifecycle cases in
  `tests/run-state-durability.nu`.

## 24. Native replacement publication is best-effort on every supported platform

**Persistence guarantee: best-effort.** Nurl does not guarantee atomic file replacement on
any supported platform in this release. If a save fails or is interrupted, the previous file
may be missing, empty, or partially replaced even when Nushell returns success. This applies
to configuration, variables, secrets, collections, requests, environments, chains,
history/index files, and downloaded response bodies. Back up `~/.nurl` before upgrades or
bulk changes.

- **Root cause:** supported Nushell `mv -f` implementations can fall back from rename to copying
  or removing the destination. Even when the fallback fully succeeds, publication was an
  in-place overwrite, not an atomic swap. A concurrent reader can observe partial or torn bytes
  mid-copy even though the final bytes are correct and Nurl reports success — no error, no
  diagnostic, and the postcondition check passes. Additionally, Nu 0.89 self-renders `mv`
  failures and returns process exit 0, so a failed publication is not detectable from exit
  status.
- **Detection limit:** replacement paths compare the destination's raw bytes with the intended
  bytes after native publication. This is a final-byte damage detector, not an atomicity
  verifier. It can miss a completed in-place fallback that exposed torn reads, and it can report
  a mismatch after a legitimate external writer wins a race. A mismatch therefore states only
  the observed final-byte outcome and temporary-file cleanup state; it does not identify
  corruption, atomicity, or what happened to prior bytes. Verification-read I/O errors propagate
  unchanged.
- **Message boundary:** a strong previous-file preservation message is used only when failure is
  proven before native publication starts. Once `mv` is invoked, no platform or runtime is
  treated as a safe publication path and no preservation claim is made.
- **Re-check:** run the capability, persistence-inventory, forced-fallback, final-state detector,
  and non-root POSIX cases in `tests/run-state-durability.nu`.
