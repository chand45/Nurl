# Nurl

**A modern API client for the terminal** — curl meets Postman, powered by Nushell.

[![Nushell](https://img.shields.io/badge/Nushell-%3E%3D0.89-4E9A06?style=flat&logo=nushell)](https://www.nushell.sh/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## Why Nurl?

| Feature | Postman | Insomnia | curl | **Nurl** |
|---------|---------|----------|------|----------|
| No GUI required | ❌ | ❌ | ✅ | ✅ |
| Collections & Environments | ✅ | ✅ | ❌ | ✅ |
| Git-friendly (plain text) | ❌ | ❌ | ✅ | ✅ |
| Variable interpolation | ✅ | ✅ | ❌ | ✅ |
| Request chaining | ✅ | ✅ | ❌ | ✅ |
| Beautiful table output | ❌ | ❌ | ❌ | ✅ |
| Scriptable & pipeable | ❌ | ❌ | ✅ | ✅ |
| Zero electron/bloat | ❌ | ❌ | ✅ | ✅ |
| Interactive TUI | ❌ | ❌ | ❌ | ✅ |
| **Auto-saved history** | ✅ | ✅ | ❌ | ✅ |

**Nurl** gives you the power of Postman's collections, environments, and workflows — right in your terminal, with beautiful Nushell table output, and everything stored in git-friendly plain text.

**Never lose a completed request again:** Every completed HTTP response is automatically saved to history with full request/response details. Search through past requests, inspect responses, and resend any request with a single command — no need to remember or retype complex curl commands.

---

## Requirements

- [Nushell](https://www.nushell.sh/) >= 0.89.0
- curl >= 7.75.0 (required for fileless framed response metadata)

---

## Installation

### Quick Install (Recommended)

**Linux / macOS:**
```bash
curl -fsSL https://raw.githubusercontent.com/chand45/Nurl/main/install.sh | bash
```

**Windows (PowerShell):**
```powershell
irm https://raw.githubusercontent.com/chand45/Nurl/main/install.ps1 | iex
```

This installs Nurl to `~/.nurl` and adds an owned Nurl block to the `config.nu` in
`$nu.default-config-dir`. The installer downloads and parses the complete code payload in a
temporary staging directory before replacing live files. Failed downloads, HTTP errors, an
unsupported Nushell version, or parse failures leave an existing installation and Nushell
configuration unchanged. Collections, chains, history, and user `.nuon` files are never replaced
during an update. Unsupported config encodings and unsafe install paths are rejected before live
files change. On Linux/macOS, writable `config.nu` and config-directory symlinks are resolved to
their targets and preserved for dotfile-manager compatibility; PowerShell conservatively rejects
reparse-point config paths.

### Manual Install (Alternative)

```bash
# Clone the repository
git clone https://github.com/chand45/Nurl.git
cd Nurl
```

Then in Nushell:

```nushell
# Load Nurl (add to your config.nu for permanent use)
source api.nu
```

### Updating

Run the same install command again. It updates only Nurl's code after the complete staged payload
passes validation, while preserving collections, chains, history, secrets, variables, and
configuration.

### Uninstalling

**Linux / macOS (non-interactive):**
```bash
curl -fsSL https://raw.githubusercontent.com/chand45/Nurl/main/uninstall.sh | bash -s -- --yes
```

`-y` and `NURL_ASSUME_YES=1` are equivalent forms of explicit consent. A piped script can prompt
through `/dev/tty` when the process has a controlling terminal; without a usable terminal or
explicit consent it aborts without mutation. You can also download the script first and run
`bash uninstall.sh` interactively.

**Windows (PowerShell, non-interactive):**
```powershell
$env:NURL_ASSUME_YES = "1"; irm https://raw.githubusercontent.com/chand45/Nurl/main/uninstall.ps1 | iex
```

For an interactive prompt, download `uninstall.ps1` and run it without `-Yes`; `-Yes` (alias `-y`)
provides explicit consent for a local script. PowerShell install/uninstall failures are catchable
and do not terminate the invoking host session.

Uninstall atomically moves the complete `~/.nurl` tree to a timestamped same-home backup and
verifies its contents before considering the installation removed. If detaching or verification
fails, Nurl data remains at its original path or in the reported backup. The uninstaller removes
only the owned Nurl config block, plus the exact
legacy source line used by older releases, from both the resolved and legacy config locations.
Comments, aliases, encoding, mixed line endings, and trailing-newline state are preserved. Links
and special files inside `~/.nurl` are rejected because they cannot be copied and verified as a
self-contained backup.

---

## Quick Start

```nushell
# Make your first request
api get "https://jsonplaceholder.typicode.com/posts/1"

# Create a collection for your API
api collection create my-api -d "My API endpoints"

# Set up environments
api collection env create my-api dev
api collection env use my-api dev
api collection env set my-api base_url "http://localhost:3000"

# Save a request
api request create get-users GET "{{base_url}}/users" -c my-api

# Send it
api send get-users -c my-api
```

---

## Output Examples

Nurl produces clean, colorful terminal output that makes API testing a joy:

### HTTP Response

```
> api get "https://jsonplaceholder.typicode.com/posts/1"
200 OK  156ms, 292 bytes

╭────────────┬──────────────────────────────────────────────────────────────╮
│ request    │ {method: GET, url: https://jsonplaceholder.typicode.com/...} │
├────────────┼──────────────────────────────────────────────────────────────┤
│ response   │ ╭─────────────┬────────────────────────────────────────────╮ │
│            │ │ status      │ 200                                        │ │
│            │ │ status_text │ OK                                         │ │
│            │ │ body        │ ╭────────┬──────────────────────────────╮  │ │
│            │ │             │ │ userId │ 1                            │  │ │
│            │ │             │ │ id     │ 1                            │  │ │
│            │ │             │ │ title  │ sunt aut facere repellat...  │  │ │
│            │ │             │ │ body   │ quia et suscipit suscipit... │  │ │
│            │ │             │ ╰────────┴──────────────────────────────╯  │ │
│            │ │ time_ms     │ 156                                        │ │
│            │ │ size_bytes  │ 292                                        │ │
│            │ ╰─────────────┴────────────────────────────────────────────╯ │
├────────────┼──────────────────────────────────────────────────────────────┤
│ timestamp  │ 2026-01-11T14:32:08Z                                         │
╰────────────┴──────────────────────────────────────────────────────────────╯
```

### Collections & Environments

```
> api collection list
╭───┬──────────────────┬─────────────────────────────────────────┬──────────╮
│ # │ name             │ description                             │ requests │
├───┼──────────────────┼─────────────────────────────────────────┼──────────┤
│ 0 │ jsonplaceholder  │ Example collection for JSONPlaceholder  │        5 │
│ 1 │ my-api           │ Internal API endpoints                  │       12 │
│ 2 │ stripe           │ Stripe payment integration              │        8 │
╰───┴──────────────────┴─────────────────────────────────────────┴──────────╯

> api collection env list my-api
╭───┬────────────┬────────┬───────────┬──────────────────────────╮
│ # │ name       │ active │ variables │ description              │
├───┼────────────┼────────┼───────────┼──────────────────────────┤
│ 0 │ dev        │ ✓      │         4 │ Local development        │
│ 1 │ staging    │        │         4 │ Staging environment      │
│ 2 │ prod       │        │         5 │ Production environment   │
╰───┴────────────┴────────┴───────────┴──────────────────────────╯
```

### Request History

```
> api history list
╭───┬──────────────────────────┬──────────┬────────┬────────┬────────────────────────────────────────────────┬─────────╮
│ # │ id                       │ timestamp│ method │ status │ url                                            │ time_ms │
├───┼──────────────────────────┼──────────┼────────┼────────┼────────────────────────────────────────────────┼─────────┤
│ 0 │ 20260111-143208-xK9mPq   │ 14:32:08 │ GET    │ 200    │ https://jsonplaceholder.typicode.com/posts/1   │     156 │
│ 1 │ 20260111-143052-Lm3nRs   │ 14:30:52 │ POST   │ 201    │ https://jsonplaceholder.typicode.com/posts     │     203 │
│ 2 │ 20260111-142847-Wp7qXt   │ 14:28:47 │ GET    │ 200    │ https://api.example.com/users                  │      89 │
│ 3 │ 20260111-142512-Bc4dEf   │ 14:25:12 │ DELETE │ 404    │ https://api.example.com/users/999              │      45 │
╰───┴──────────────────────────┴──────────┴────────┴────────┴────────────────────────────────────────────────┴─────────╯
```

### Chain Execution

```
> api chain exec auth-workflow
═══ Running Chain: auth-workflow ═══

[1/3] auth/login
      POST https://api.example.com/auth/login
      200 OK  245ms
      ✓ Extracted: token → eyJhbGciOiJIUzI1NiIs...

[2/3] users/profile
      GET https://api.example.com/users/me
      200 OK  89ms
      ✓ Extracted: user_id → 12345

[3/3] users/settings
      GET https://api.example.com/users/12345/settings
      200 OK  67ms

═══ Chain Complete ═══
Total time: 401ms
Requests: 3 successful, 0 failed
```

### Interactive TUI

```
> api tui
╔════════════════════════════════════════╗
║       API Client - Terminal UI         ║
╚════════════════════════════════════════╝

═══ Main Menu ═══

[1] Collections
[2] History
[3] Variables
[4] Authentication
[5] Quick Request

[q] Quit  [?] Help

> _
```

<details>
<summary><strong>More Output Examples</strong></summary>

### Variables

```
> api vars list
╭───┬────────────────────┬─────────────────────────────────┬────────────┬─────────────────────────╮
│ # │ name               │ value                           │ type       │ description             │
├───┼────────────────────┼─────────────────────────────────┼────────────┼─────────────────────────┤
│ 0 │ {{base_url}}       │ https://api.example.com         │ global     │ API base URL            │
│ 1 │ {{api_version}}    │ v1                              │ global     │ API version             │
│ 2 │ {{$uuid}}          │ 8f14e45f-ceea-467f-a8bf-a67...  │ builtin    │ Random UUID v4          │
│ 3 │ {{$timestamp}}     │ 2026-01-11T14:32:08Z            │ builtin    │ ISO 8601 timestamp      │
│ 4 │ {{$random_int}}    │ 847293                          │ builtin    │ Random integer 0-999999 │
╰───┴────────────────────┴─────────────────────────────────┴────────────┴─────────────────────────╯
```

### Saved Requests

```
> api request list -c my-api
╭───┬───────────────┬──────────────────┬────────┬────────────────────────────────────────────────╮
│ # │ name          │ collection       │ method │ url                                            │
├───┼───────────────┼──────────────────┼────────┼────────────────────────────────────────────────┤
│ 0 │ get-users     │ my-api           │ GET    │ {{base_url}}/users                             │
│ 1 │ get-user      │ my-api           │ GET    │ {{base_url}}/users/{{user_id}}                 │
│ 2 │ create-user   │ my-api           │ POST   │ {{base_url}}/users                             │
│ 3 │ update-user   │ my-api           │ PUT    │ {{base_url}}/users/{{user_id}}                 │
│ 4 │ delete-user   │ my-api           │ DELETE │ {{base_url}}/users/{{user_id}}                 │
╰───┴───────────────┴──────────────────┴────────┴────────────────────────────────────────────────╯
```

### Authentication

```
> api auth show
╭───┬─────────────────┬─────────┬──────────────────────┬─────────────────╮
│ # │ name            │ type    │ status               │ value           │
├───┼─────────────────┼─────────┼──────────────────────┼─────────────────┤
│ 0 │ mytoken         │ bearer  │ configured           │ eyJhbGciOi...   │
│ 1 │ mycreds         │ basic   │ configured           │ admin:***       │
│ 2 │ stripe-key      │ apikey  │ header: X-API-Key    │ sk_test_***     │
│ 3 │ github-oauth    │ oauth2  │ token expires: 2h    │ gho_xxxx***     │
╰───┴─────────────────┴─────────┴──────────────────────┴─────────────────╯
```

</details>

---

## Features

- **Collections** — Organize requests into shareable, git-friendly collections
- **Environments** — Switch between dev/staging/prod with one command
- **Variable Interpolation** — Use `{{variable}}` syntax in URLs, headers, and bodies
- **Authentication** — Bearer tokens, Basic Auth, API Keys, OAuth2
- **Request History** — Automatic logging with fast indexed search and resend
- **Request Chaining** — Execute sequences with variable extraction between requests
- **Interactive TUI** — Browse and test APIs without remembering commands
- **Beautiful Output** — Nushell's native tables make responses easy to read
- **Output Control** — `--output status/body/json/headers`, `--select dot.path` for scripting
- **Form Encoding** — `--form` for `application/x-www-form-urlencoded` POST bodies
- **Redirect Handling** — `--follow-redirects` to follow HTTP 3xx responses
- **Retry Logic** — nonnegative `--retries N` makes at most `N+1` attempts, with `--retry-delay` between attempts
- **HEAD & OPTIONS** — `api head` and `api options` commands
- **File Saving** — `--save` for text, transactional `--binary-save` for binary downloads

---

## Usage Guide

### Making Requests

```nushell
# GET request
api get "https://api.example.com/users"

# POST with JSON body
api post "https://api.example.com/users" --body { name: "John", email: "john@example.com" }

# PUT request
api put "https://api.example.com/users/1" --body { name: "Jane" }

# PATCH request
api patch "https://api.example.com/users/1" --body { email: "jane@example.com" }

# DELETE request
api delete "https://api.example.com/users/1"

# HEAD request — status + headers only, no body (C10)
api head "https://api.example.com/users/1"

# OPTIONS request (C10)
api options "https://api.example.com/users"

# With custom headers
api get "https://api.example.com/users" -H { "X-Custom-Header": "value" }

# Using variables (from global or collection environment)
api get "{{base_url}}/{{api_version}}/users"

# Form-encoded POST (C4)
api post "https://api.example.com/login" --form { username: "alice", password: "secret" }

# Follow redirects automatically (C6)
api get "https://api.example.com/old-url" --follow-redirects

# Retry after failure — up to 4 total attempts, 2s delay between attempts (C8)
api get "https://api.example.com/flaky" --retries 3 --retry-delay 2

# Don't save this request to history (A7)
api get "https://api.example.com/users" --no-history
```

### Output Control

Nurl has two output modes with a clear separation between **interactive** and **scripting** use (C1, C2, C3):

**Interactive mode (default `pretty`)** — prints a human-friendly status line + formatted body. Returns `null` so the REPL does not render a second time. Best for everyday use:
```nushell
api get "https://api.example.com/users"
# → ● 200 OK  243ms  1.2KB  GET …
# → { "id": 1, … }
```

**Scripting/data modes** — return the value directly (no printing). Nushell renders the return value once when used naked; `let x = (...)` captures the typed value:
```nushell
# Capture the full result record (request + response + timestamp)
let r = (api get "https://api.example.com/users" --raw)
$r.response.body        # access body
$r.response.status      # access status
$r | describe           # → record<request: …, response: …, timestamp: string>

# Capture just the status code as an integer
let code = (api get "https://api.example.com/users" --output status)
$code | describe        # → int
# → 200

# Capture the parsed body value
let body = (api get "https://api.example.com/users" --output body)

# Capture only the undecorated response body text.
# JSON quoting/whitespace is preserved; empty bodies return nothing.
let rawBody = (api get "https://api.example.com/users" --output raw)

# Capture the full result as a JSON string
let json = (api get "https://api.example.com/users" --output json)

# Capture response headers as a record
let hdrs = (api get "https://api.example.com/users" --output headers)

# Silent — prints nothing, returns nothing
api get "https://api.example.com/users" --output none

# Extract a specific field via dot-path (shorthand: body.field, headers.Name, status)
let id = (api post "https://api.example.com/users" --body {name: "Alice"} --select body.id)
# → 42  (captured as int, not string)

# Full dot-path also works
let ct = (api get "https://api.example.com/" --select headers.Content-Type)
```

Output names are case-sensitive: `pretty`, `raw`, `body`, `json`, `headers`, `status`, and `none`.
`--output raw` preserves the response payload text exactly, including JSON scalar syntax and
whitespace. The separate `--raw` flag takes precedence and returns the complete result record; `--select`
takes precedence over `--output`. Recognized sensitive response headers are masked in the public
result before `--raw`, `--output headers|json`, `--select`, or human rendering, while non-sensitive
header names, values, and result types remain unchanged. With `--dry-run`, the curl preview is returned instead of an
HTTP response. Dry-run and saved-request export never build secret-bearing wire auth or contact an
OAuth token endpoint. They render bearer/OAuth/SAML authorization, basic credentials, API-key values,
and recognized sensitive headers as `******` while preserving non-sensitive headers and API-key
header/query names. Query API-key names use RFC 3986 query-component encoding in previews, and real
requests encode both the name and value exactly once while preserving existing queries and fragments.
`--save` may be combined with data modes, and `--binary-save` writes the response
bytes while returning a safe saved-file marker for `--output raw`. Binary attempts are written to
unique sibling temporary files and replace the destination only after a complete transfer; exhausted
transport failures preserve an existing destination and leave an absent destination absent.

HTTP 4xx and final 5xx responses remain typed, inspectable responses with exit code 0. Exhausted curl
transport failures instead exit nonzero with empty stdout and a secret-redacted, non-ANSI diagnostic
on stderr. Failed transfers create neither history nor `--save` output.

**Verbose / inspect flags** (always combine with pretty mode):
```nushell
# Show request + response headers (curl-like > / < style)
api get "https://api.example.com/users" --verbose

# Include response headers above the body
api get "https://api.example.com/users" --include

# Save response body to a file
api get "https://api.example.com/report" --save output.json

# Download binary file directly
api get "https://api.example.com/asset.zip" --binary-save asset.zip
```

### Variables

Nurl supports three levels of variables, resolved in order (narrowest wins):

1. **Request-level** — `--vars` flag (highest priority)
2. **Collection environment** — Active environment for the collection
3. **Global** — Workspace-wide in `variables.nuon`
4. **Built-in** — Dynamic values like `{{$uuid}}`, `{{$timestamp}}`

```nushell
# Global variables (available to all requests)
api vars set base_url "https://api.example.com"
api vars set api_version "v1"
api vars list
api vars unset api_version

# Collection environment variables
api collection env set my-api base_url "http://localhost:3000"
api collection env show my-api
```

#### Built-in Variables

| Variable | Description | Example Output |
|----------|-------------|----------------|
| `{{$uuid}}` | Random UUID v4 | `8f14e45f-ceea-467f-a8bf-a679c79cf3d2` |
| `{{$timestamp}}` | ISO 8601 timestamp | `2026-01-11T14:32:08Z` |
| `{{$timestamp_unix}}` | Unix timestamp | `1736605928` |
| `{{$random_int}}` | Random integer 0-999999 | `847293` |
| `{{$random_string}}` | Random 16-char string | `a8Kx9pQ2mN4wE6rT` |
| `{{$random_email}}` | Random email | `user_8hk3j@example.com` |
| `{{$date}}` | Current date | `2026-01-11` |
| `{{$time}}` | Current time | `14:32:08` |

### Collections

Collections group related requests and their environments together.

```nushell
# Create a collection
api collection create my-api -d "My API endpoints"

# List all collections
api collection list

# View collection details
api collection show my-api

# Delete a collection
api collection delete my-api
```

`api collection show` returns a stable record with:
- `metadata`: the stored collection metadata record.
- `active_environment`: the active environment name or `null`.
- `requests`: request summaries with `name`, `method`, and `url`.
- `environments`: environment summaries with `name`, boolean `active`, variable count, and
  `description`.

Request bodies, authentication values, and environment variable values are not included.

### Environments

Each collection can have multiple environments (dev, staging, prod, etc.).

```nushell
# Create environments
api collection env create my-api dev
api collection env create my-api staging
api collection env create my-api prod

# Switch active environment
api collection env use my-api dev

# Set environment variables
api collection env set my-api base_url "http://localhost:3000"
api collection env set my-api api_key "dev-key-123"

# View current environment
api collection env show my-api

# List all environments
api collection env list my-api
```

### Saved Requests

Save frequently used requests to collections.

```nushell
# Create a saved request
api request create get-users GET "{{base_url}}/users" -c my-api
api request create create-user POST "{{base_url}}/users" -b { name: "{{name}}" } -c my-api

# List requests in a collection
api request list -c my-api

# Send a saved request
api send get-users -c my-api

# Send with request-level variable override
api send create-user -c my-api --vars { name: "Alice" }

# Send with auth override
api send get-users -c my-api -a { type: bearer, token_ref: mytoken }

# Saved SAML auth remains an unresolved reference until execution
api request create RegisterFaultPlan PUT "{{base_url}}/fault-plans/{{id}}" -c my-api \
  -b { name: "{{name}}" } -a { type: saml, token_ref: samltoken }
api request show RegisterFaultPlan -c my-api
api send RegisterFaultPlan -c my-api --vars { id: 42, name: "primary" }

# Nested request names are supported
api request create auth/login POST "{{base_url}}/auth/login" -c my-api
api send auth/login -c my-api
```

Collection, environment, and saved-chain names must each be one non-empty relative path segment. Spaces, embedded dots, hyphens, case, and Unicode are preserved, but rooted names, dot-only navigation names (`.`, `..`, `...`, and so on), trailing dots or spaces, `:` stream syntax, and `/` or `\` separators are rejected. Saved-request names may use nested relative paths such as `auth/login`; every segment must be non-empty and cannot be dot-only, end in a dot or space, or contain `:`. Request lookups that already accept a `.nuon` suffix continue to do so.

These rules apply only to resource identifiers. Explicit path options such as `--body-file`, `--save`, `--binary-save`, history export output, and explicit chain files remain unrestricted path-taking features.

### Authentication

```nushell
# Bearer token
api auth bearer set mytoken "your-jwt-token-here"
api get "{{base_url}}/protected" -a { type: bearer, token_ref: mytoken }

# SAML bearer token (stored as a bare token, never with the scheme prefix)
api auth saml set samltoken "your-bare-saml-token"
api get "{{base_url}}/protected" -a { type: saml, token_ref: samltoken }

# Basic auth
api auth basic set mycreds "username" "password"
api get "{{base_url}}/protected" -a { type: basic, creds_ref: mycreds }

# API key (in header)
api auth apikey set mykey "api-key-123" --header "X-API-Key"
api get "{{base_url}}/data" -a { type: apikey, key_ref: mykey }

# API key (in query)
api auth apikey set querykey "api-key-123" --query "api_key"
api get "{{base_url}}/data?format=json" -a { type: api_key, ref: querykey }

# OAuth2 (client credentials)
api auth oauth2 configure myapp --client-id "id" --client-secret "secret" --token-url "https://auth.example.com/token"
api auth oauth2 token myapp  # Fetch/refresh token

# View all auth configurations
api auth show
```

Named authentication accepts the family-specific aliases (`token_ref`, `creds_ref`, and `key_ref`)
or the generic `ref`. Successful history stores only the canonical type and reference, never the
resolved token, key, password, access token, refresh token, or client secret. SAML sends exactly
`Authorization: http://schemas.microsoft.com/dsts/saml2-bearer <token>` on the wire. Saved requests
retain the unresolved SAML auth block; URL/body interpolation still applies at send time, but
variables and `--vars` cannot override workspace SAML secrets. Inline bearer, SAML, basic, and API-key
values can execute, but are recorded as non-replayable without storing the credential.
Before a direct history save, named references are validated against local credential metadata
without contacting an OAuth provider. OAuth accepts tokens only from 2xx responses with a valid
token record; failures report only a safe provider error code/status, never the untrusted response
description or token fields.

### History

Every request is automatically logged. The history index enables instant search without scanning individual files.

```nushell
# List recent requests (uses fast O(1) index lookup)
api history list
api history list -l 20      # limit to 20 most recent

# Search history by URL or method (uses index; falls back to file scan for body search)
api history search "users"
api history search "POST"

# View full request/response details
api history show 20260111-143208-xK9mPq

# Resend a previous request (named auth is re-resolved from its saved reference)
api history resend 20260111-143208-xK9mPq

# Override stored auth (also required for history created from inline credentials)
api history resend 20260111-143208-xK9mPq -a { type: bearer, ref: mytoken }

# Rebuild the history index from existing files without rewriting them
api history rebuild-index

# Clear old history
api history clear                         # remove entries older than configured retention
api history clear --before 2026-01-01     # remove entries before a specific date
api history clear --all --force           # remove every history entry

# Export history
api history export --output history.json
```

History uses one deterministic newest-first order for the index, list, search, and JSON/CSV export.
New entries store RFC3339 UTC timestamps with nine fractional digits (for example,
`2026-01-11T14:32:08.123456789Z`); existing second-only RFC3339 timestamps and IDs remain readable
without migration. Mixed timestamps are compared as numeric instants rather than strings. If legacy
entries have truly identical timestamps, an existing index order is retained when available; an
index-free rebuild uses a deterministic fallback because the original chronology cannot be
reconstructed.

History IDs resolve exact matches first. Prefix, middle, and suffix fragments remain valid when they
identify exactly one entry; ambiguous fragments fail and ask for a longer or exact ID before replay
or other side effects. `--limit` on list, search, and export accepts zero (no entries) and values
larger than the history size, while negative values fail before index or output changes.

Re-resolving named auth on resend means credential rotation is honored automatically for bearer,
SAML, basic, API-key header/query, and OAuth2 references. Named SAML history is canonical
`{type: saml, ref: <name>, replayable: true}`; inline SAML history is secret-free and non-replayable.
Legacy history without auth metadata retains
its unauthenticated resend behavior. A default resend of non-replayable inline auth fails before
network or file side effects and tells you to pass `--auth`. New history also redacts recognized
sensitive request and response headers. This sanitization is enforced by the shared persistence
boundary for automatic and direct synthetic history saves. It constructs explicit canonical
request/response records, validates their field types before mutation, and omits caller-supplied
metadata outside that schema, so history bytes, index, show/get, and export cannot expose smuggled
credential fields. Response bodies remain unchanged. Resend requires `--headers` instead of
transmitting mask text from a sensitive stored request header.

Caller-supplied URLs are also checked after interpolation and before authentication or network
work. URL userinfo and exact, case-insensitive credential parameter names in queries or fragments
(including percent-encoded token, client-secret, API-key, and `password`/`passwd`/`pwd` aliases)
are rejected; ordinary names that merely contain those words are preserved. The same exact password
aliases and their `X-` header forms are masked in request/response headers, including live typed
responses and machine output modes. Query parameters added
by Nurl managed auth are constructed only after this check, so named query API keys remain supported
even with a sensitive parameter name, and history stores the safe caller URL plus auth reference.
Pre-existing history remains readable without migration, but an old entry with an unsafe URL cannot
be resent.

### Request Chaining

Execute sequences of requests, extracting and passing values between them.

```nushell
# Run a saved chain
api chain exec auth-workflow

# Run inline chain
api chain run [
    { request: "auth/login", extract: { token: "body.access_token" } }
    { request: "users/profile", use: { bearer_token: "{{token}}" } }
    { request: "users/posts", extract: { post_count: "body.total" } }
]
```

Without `--stop-on-error`, a transport failure is recorded as a failed step, later steps continue,
and the returned summary has `success: false`. With `--stop-on-error`, the transport failure exits
nonzero. `--quiet` suppresses chain progress and caught-failure diagnostics.

### TUI (Terminal UI)

For those who prefer a visual interface:

```nushell
api tui
```

Navigate with number keys, `[b]` to go back, `[q]` to quit.

---

## Configuration

Global settings are stored in `config.nuon`:

```nushell
{
    default_collection: null
    default_headers: {
        "Content-Type": "application/json"
        "Accept": "application/json"
    }
    timeout_seconds: 30
    history_retention_days: 30
    editor: "code"
    colors: {
        success: "green"
        error: "red"
        warning: "yellow"
        info: "blue"
    }
}
```

`default_collection` is optional. `api status` reports it as `active_collection` and reports that
collection's `active_environment`; both fields are `null` when no default collection is configured.
Configured collection or environment references must exist.

---

## Project Structure

<details>
<summary>Click to expand</summary>

When installed via the install script, Nurl lives in `~/.nurl`:

```
~/.nurl/
├── api.nu                 # Entry point (auto-sourced via config.nu)
├── config.nuon            # Global configuration
├── variables.nuon         # Global variables
├── secrets.nuon           # Credentials (sensitive - never commit!)
├── nu_modules/            # Core modules
│   ├── mod.nu             # Main module + collection commands
│   ├── http.nu            # HTTP requests via curl
│   ├── auth.nu            # Authentication handling
│   ├── vars.nu            # Variable interpolation
│   ├── history.nu         # Request history
│   ├── chain.nu           # Request chaining
│   ├── tui.nu             # Terminal UI
│   └── log.nu             # Logging utilities
├── collections/           # Request collections
│   └── <collection>/
│       ├── collection.nuon    # Collection metadata
│       ├── meta.nuon          # Active environment tracking
│       ├── environments/      # Collection-specific environments
│       │   ├── dev.nuon
│       │   └── prod.nuon
│       └── requests/          # Saved request definitions
├── chains/                # Chain definitions
└── history/               # Request/response history (by date)
    ├── index.nuon         # Fast index for O(1) list/search (B1)
    └── YYYY-MM-DD/        # Daily directories with .nuon files
```

</details>

---

## Example: JSONPlaceholder

The included `jsonplaceholder` collection demonstrates the workflow:

```nushell
# Activate the example collection's environment
api collection env use jsonplaceholder default

# List available requests
api request list -c jsonplaceholder

# Get all posts
api send get-posts -c jsonplaceholder

# Get a specific post
api collection env set jsonplaceholder post_id "1"
api send get-post -c jsonplaceholder

# Create a new post
api send create-post -c jsonplaceholder

# Run the example chain
api chain exec example-workflow
```

---

## Command Reference

Run `api help` for the full command list, or:

| Category | Commands |
|----------|----------|
| **HTTP** | `api get`, `api post`, `api put`, `api patch`, `api delete`, `api head`, `api options`, `api request` |
| **Output control** | `--output pretty\|body\|raw\|json\|headers\|status\|none`, `--select <dot.path>`, `--verbose`, `--include`, `--save <file>`, `--binary-save <file>` |
| **Request options** | `--form <record>`, `--follow-redirects`, `--retries <n>`, `--retry-delay <s>`, `--no-history`, `--dry-run` |
| **Collections** | `api collection create/list/show/delete/copy` |
| **Environments** | `api collection env create/use/show/set/unset/delete/list` |
| **Requests** | `api request create/list/show/update/delete/export`, `api send` |
| **Variables** | `api vars list/set/unset` |
| **Auth** | `api auth bearer/saml/basic/apikey/oauth2 set/get/delete`, `api auth show` |
| **History** | `api history list/show/search/resend/clear/rebuild-index` |
| **Chains** | `api chain run/exec` |
| **Other** | `api init`, `api status`, `api help`, `api tui` |

---

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---
<p align="center">
  <sub>Built with ❤️ using <a href="https://www.nushell.sh/">Nushell</a></sub>
</p>
