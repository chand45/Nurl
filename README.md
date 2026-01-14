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

**Never lose a request again:** Every request you make is automatically saved to history with full request/response details. Search through past requests, inspect responses, and resend any request with a single command — no need to remember or retype complex curl commands.

---

## Requirements

- [Nushell](https://www.nushell.sh/) >= 0.89
- curl (system installed)

---

## Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/nurl.git

# Navigate to the directory
cd nurl
```

Then in Nushell:

```nushell
# Load Nurl (add to your config.nu for permanent use)
source api.nu

# Initialize workspace
api init
```

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
api request create get-users --method GET --url "{{base_url}}/users" -c my-api

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
- **Request History** — Automatic logging with search and resend
- **Request Chaining** — Execute sequences with variable extraction between requests
- **Interactive TUI** — Browse and test APIs without remembering commands
- **Beautiful Output** — Nushell's native tables make responses easy to read

---

## Usage Guide

### Making Requests

```nushell
# GET request
api get "https://api.example.com/users"

# POST with JSON body
api post "https://api.example.com/users" -b '{"name": "John", "email": "john@example.com"}'

# PUT request
api put "https://api.example.com/users/1" -b '{"name": "Jane"}'

# DELETE request
api delete "https://api.example.com/users/1"

# With custom headers
api get "https://api.example.com/users" -H { "X-Custom-Header": "value" }

# Using variables (from global or collection environment)
api get "{{base_url}}/{{api_version}}/users"
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
api request create get-users --method GET --url "{{base_url}}/users" -c my-api
api request create create-user --method POST --url "{{base_url}}/users" -b '{"name": "{{name}}"}' -c my-api

# List requests in a collection
api request list -c my-api

# Send a saved request
api send get-users -c my-api

# Send with request-level variable override
api send create-user -c my-api --vars { name: "Alice" }
```

### Authentication

```nushell
# Bearer token
api auth bearer set mytoken "your-jwt-token-here"
api get "{{base_url}}/protected" -a { type: bearer, token_ref: mytoken }

# Basic auth
api auth basic set mycreds "username" "password"
api get "{{base_url}}/protected" -a { type: basic, creds_ref: mycreds }

# API key (in header)
api auth apikey set mykey "api-key-123" --header "X-API-Key"
api get "{{base_url}}/data" -a { type: apikey, key_ref: mykey }

# OAuth2 (client credentials)
api auth oauth2 configure myapp --client-id "id" --client-secret "secret" --token-url "https://auth.example.com/token"
api auth oauth2 token myapp  # Fetch/refresh token

# View all auth configurations
api auth show
```

### History

Every request is automatically logged.

```nushell
# List recent requests
api history list

# Search history
api history search "users"

# View full request/response details
api history show 20260111-143208-xK9mPq

# Resend a previous request
api history resend 20260111-143208-xK9mPq
```

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

---

## Project Structure

<details>
<summary>Click to expand</summary>

```
nurl/
├── api.nu                 # Entry point (source this file)
├── config.nuon            # Global configuration
├── variables.nuon         # Global variables
├── secrets.nuon           # Credentials (gitignored)
├── nu_modules/            # Core modules
│   ├── mod.nu             # Main module + collection commands
│   ├── http.nu            # HTTP requests via curl
│   ├── auth.nu            # Authentication handling
│   ├── vars.nu            # Variable interpolation
│   ├── history.nu         # Request history
│   ├── chain.nu           # Request chaining
│   └── tui.nu             # Terminal UI
├── collections/           # Request collections
│   └── <collection>/
│       ├── collection.nuon    # Collection metadata
│       ├── meta.nuon          # Active environment tracking
│       ├── environments/      # Collection-specific environments
│       │   ├── dev.nuon
│       │   └── prod.nuon
│       └── requests/          # Saved request definitions
├── chains/                # Chain definitions
└── history/               # Request/response history
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
| **HTTP** | `api get`, `api post`, `api put`, `api patch`, `api delete` |
| **Collections** | `api collection create/list/show/delete/copy` |
| **Environments** | `api collection env create/use/show/set/unset/delete/list` |
| **Requests** | `api request create/list/show/update/delete`, `api send` |
| **Variables** | `api vars list/set/unset` |
| **Auth** | `api auth bearer/basic/apikey/oauth2 set/get/delete`, `api auth show` |
| **History** | `api history list/show/search/resend` |
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
