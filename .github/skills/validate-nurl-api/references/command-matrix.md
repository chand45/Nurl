# Nurl API command matrix

Concrete, runnable test for every user-facing `api` command, grouped the same way as
`coverage.nuon`. Each row is: **command → invocation (against the `jsonplaceholder`
collection) → expected result**. Internal helpers and TUI views are summarized at the end.

## Assumptions
- `nu` is the Nushell binary (may be off PATH — see SKILL.md "Environment setup").
- `api.nu` has been sourced with its **absolute** path so `API_ROOT` points at the repo:
  `source C:\path\to\Nurl\api.nu`
- The `jsonplaceholder` collection exists with envs `default` / `dev` / `staging`, where
  `base_url = https://jsonplaceholder.typicode.com`, and these saved requests:
  `create-post get-post get-posts get-users get-comments update-post delete-post`.
- Network reaches `jsonplaceholder.typicode.com` (offline → use `-d`/`--dry-run` on requests).

## Conventions
- `-r` / `--raw` returns the structured result so you can assert on `.response.status`.
- Mutating commands use a **temp** name (`tmp-*`) and are cleaned up in the same script.
- Commands that re-serialize `.nuon` (e.g. `api init`) cause formatting churn — restore with
  `git checkout -- <file>`.
- PowerShell expands `$x`; write multi-line nu tests to a `.nu` file and run `nu file.nu`
  rather than `nu -c "...$res..."`.

---

## setup
| Command | Invocation | Expected |
|---|---|---|
| api init | `api init` | Recreates missing workspace files. **Churn:** rewrites `config.nuon`; `git checkout -- config.nuon` after. |
| api status | `api status` | Prints active collection/env + counts, no error. |
| api config get | `api config get` | Prints the config record. |
| api config set | `api config set default_collection jsonplaceholder; api config get` | `default_collection` now `jsonplaceholder`. Restore prior value or `git checkout -- config.nuon`. |
| api help | `api help` | Prints the curated command groups. |

## variables
| Command | Invocation | Expected |
|---|---|---|
| api vars list | `api vars list` | Lists global + built-in vars. |
| api vars set | `api vars set tmp_token abc123; api vars list` | `tmp_token` shown. |
| api vars unset | `api vars unset tmp_token` | `tmp_token` removed. |
| api vars test | `api vars set tmp_token abc; api vars test "t={{tmp_token}}"; api vars unset tmp_token` | Prints `Output: t=abc`. |

## collections
| Command | Invocation | Expected |
|---|---|---|
| api collection list | `api collection list` | Lists collections incl. `jsonplaceholder`. |
| api collection create | `api collection create tmp-col --description test` | Creates `collections/tmp-col`. |
| api collection show | `api collection show jsonplaceholder` | Prints metadata + requests/envs. |
| api collection copy | `api collection copy jsonplaceholder tmp-copy` | Deep-copies into `tmp-copy`. |
| api collection delete | `api collection delete tmp-col --force; api collection delete tmp-copy --force` | Removes the temp collections. |

## collection-env
Operate on a temp env so `jsonplaceholder`'s envs stay intact.
| Command | Invocation | Expected |
|---|---|---|
| api collection env list | `api collection env list jsonplaceholder` | Lists `default/dev/staging`. |
| api collection env create | `api collection env create jsonplaceholder tmpenv` | Creates `environments/tmpenv.nuon`. |
| api collection env use | `api collection env use jsonplaceholder dev; api collection env use jsonplaceholder default` | Switches active env (restore to `default`). |
| api collection env show | `api collection env show jsonplaceholder default` | Prints `base_url` etc. |
| api collection env set | `api collection env set jsonplaceholder k v -t tmpenv` | Sets `k=v` in `tmpenv` (`-t` targets a non-active env). |
| api collection env unset | `api collection env unset jsonplaceholder k -t tmpenv` | Removes `k` from `tmpenv`. |
| api collection env delete | `api collection env delete jsonplaceholder tmpenv --force` | Deletes `tmpenv`. |

## auth
Use a temp credential name; secrets live in gitignored `secrets.nuon`.
| Command | Invocation | Expected |
|---|---|---|
| api auth bearer set | `api auth bearer set tmpcred abc123` | "Bearer token 'tmpcred' saved". |
| api auth bearer get | `api auth bearer get tmpcred` | Returns `abc123`. |
| api auth bearer delete | `api auth bearer delete tmpcred` | Removed. |
| api auth basic set | `api auth basic set tmpcred u p` | "Basic auth 'tmpcred' saved". |
| api auth basic get | `api auth basic get tmpcred` | Returns `{username,password}`. |
| api auth basic delete | `api auth basic delete tmpcred` | Removed. |
| api auth apikey set | `api auth apikey set tmpcred secret --header X-Api-Key` | Header-mode key saved (use `--query name` for query mode). |
| api auth apikey get | `api auth apikey get tmpcred` | Returns the key config. |
| api auth apikey delete | `api auth apikey delete tmpcred` | Removed. |
| api auth oauth2 configure | `api auth oauth2 configure tmpcred --client-id id --client-secret s --token-url https://example.com/token` | Config saved. |
| api auth oauth2 token | `api auth oauth2 token tmpcred` | **Needs a real provider.** Without one: config/HTTP error (smoke only). |
| api auth oauth2 refresh | `api auth oauth2 refresh tmpcred` | **Needs a real provider + refresh token** (smoke only). |
| api auth oauth2 delete | `api auth oauth2 delete tmpcred` | Removed. |
| api auth show | `api auth bearer set tmpcred abc; api auth show --full; api auth bearer delete tmpcred` | Shows credential type/status and the isolated `tmpcred` value; never run `--full` against real secrets in captured logs. |
| api auth list | `api auth list` | Lists configured credentials by type. |
| **Applied auth** | add `-a {type: bearer, token_ref: tmpcred}` to `api get`/`api send` | Request carries an `Authorization` header; redact its value in captured output. |

## requests
| Command | Invocation | Expected |
|---|---|---|
| api get | `api get https://jsonplaceholder.typicode.com/posts/1 -r` | `.response.status == 200`. |
| api post | `api post https://jsonplaceholder.typicode.com/posts -b {title: t, body: b, userId: 1} -r` | `201`. |
| api put | `api put https://jsonplaceholder.typicode.com/posts/1 -b {title: t} -r` | `200`. |
| api patch | `api patch https://jsonplaceholder.typicode.com/posts/1 -b {title: t} -r` | `200`. |
| api delete | `api delete https://jsonplaceholder.typicode.com/posts/1 -r` | `200`. |
| api head | `api head https://jsonplaceholder.typicode.com/posts/1 --output status --no-history` | Exit 0, typed status `200`, no body rendering, empty stderr, and no history entry. |
| api options | `api options https://jsonplaceholder.typicode.com/posts --raw --no-history` | Exit 0 with structured status `204`, empty stderr, and no history write. |
| api request | `api request -m GET https://jsonplaceholder.typicode.com/posts/1 -r` | `200`. Generic verb; a **string** `-b` body is sent as-is (no double-encode). |
| api send | `api send get-post -c jsonplaceholder -r` | `200`; `{{base_url}}` resolved from the active env. Try every saved request. |

## saved-requests
Full lifecycle on a temp request, cleaned up at the end.
| Command | Invocation | Expected |
|---|---|---|
| api request create | `api request create tmp-req GET '{{base_url}}/posts/1' -c jsonplaceholder` | Creates `requests/tmp-req.nuon`. |
| api request list | `api request list -c jsonplaceholder` | Includes `tmp-req`. |
| api request show | `api request show tmp-req -c jsonplaceholder` | Prints method/url/headers. |
| api request update | `api request update tmp-req --method POST -c jsonplaceholder` | Method now `POST`. |
| api request delete | `api request delete tmp-req -c jsonplaceholder --force` | Removed. |
| api request export | `api request export get-post -c jsonplaceholder` | Exit 0; stdout is the interpolated curl dry-run, stderr is empty, and neither network nor history is touched. |

## history
| Command | Invocation | Expected |
|---|---|---|
| api history list | `api get .../posts/1; api history list` | New entry at the top. |
| api history show | `api history show (api history list \| first \| get id)` | Prints full request/response. |
| api history resend | `api history resend <id>` | Re-executes; POST bodies re-sent as a string (no double-encode). `-e` is **inert** (warns). |
| api history search | `api history search posts` | Matching entries. |
| api history clear | `api history clear` | Removes only date directories older than `history_retention_days`; use `--before YYYY-MM-DD` for an explicit cutoff or `--all --force` to remove everything. Run destructive variants in a throwaway `API_ROOT`. |
| api history export | `let out = ($nu.temp-dir \| path join $"nurl-hist-(random uuid).json"); api history export --format json --output $out; rm -f $out` | Writes the isolated export file and then removes it. |
| api history rebuild-index | `let tmp = ($nu.temp-dir \| path join $"nurl-rebuild-(random uuid)"); mkdir $tmp; with-env {API_ROOT: $tmp} { api init \| ignore; api history save {method: GET, url: "https://example.invalid", headers: {}, body: null} {status: 200, status_text: OK, headers: {}, body: null, time_ms: 1, size_bytes: 0} \| ignore; rm ($tmp \| path join history index.nuon); api history rebuild-index }; rm -rf $tmp` | Exit 0, stdout reports one indexed entry, stderr is empty, and the isolated `history/index.nuon` contains that synthetic entry. |

## chaining
| Command | Invocation | Expected |
|---|---|---|
| api chain exec | `api chain exec example-workflow` | Runs the file's steps. Step 1 POSTs; **step 2 GET /posts/101 → 404 by design** (jsonplaceholder doesn't persist). Not a bug. |
| api chain run | `api chain run (open chains/example-workflow.nuon \| get steps)` | Same steps via the **list** form (`chain run` takes a list, not a file path). |
| api chain create | `api chain create tmp-chain` | Creates `chains/tmp-chain.nuon`. |
| api chain list | `api chain list` | Lists chains incl. `example-workflow`. |
| api chain show | `api chain show example-workflow` | Prints the chain definition. |
| api chain delete | `api chain delete tmp-chain --force` | Removed. |

## tui (smoke only)
Interactive `input` reads the Windows console directly, so these can't be driven by piped
stdin in a non-tty harness. Confirm each **launches and renders its first menu** without a
parse/throw, then exit; do full interaction in a real terminal.
`api tui`, `api tui collections`, `api tui history`, `api tui environments`, `api tui request`,
`api tui chains`. Note `api tui environments` must use `api collection env *` (not `api env *`).

## internal helpers (no dedicated test — exercised indirectly)
- **variables:** `api vars get-merged`, `api vars interpolate`, `api vars interpolate-record`,
  `api vars extract` — covered by `api vars test`, live `api send`, and `api chain exec`.
- **auth:** `api auth get-config` — covered when a request applies auth.
- **history:** `api history save`, `api history get` — covered by any live request / `history show`.
- **display:** `api headers`, `api table`, `api explore`, `api pretty`, `api summary` — covered
  by request output rendering.
