# API Client - curl + nushell Postman Replacement

A lightweight, powerful API testing tool built on curl and nushell that provides Postman-like functionality through CLI commands and an optional TUI.

## Quick Start

```nushell
# Load the API client
source api.nu

# Initialize workspace (creates directories and config files)
api init

# Show help
api help
```

## Features

- **Global Variables**: Workspace-wide variables in `variables.nuon`
- **Collection Environments**: Per-collection switchable environments (dev, staging, prod)
- **Variable Interpolation**: Use `{{variable}}` syntax in URLs, headers, and bodies
- **Authentication**: Bearer tokens, Basic Auth, API Keys, OAuth2
- **History**: Automatic request/response logging with search and resend
- **Request Chaining**: Execute sequences of requests with variable extraction
- **Collections**: Shareable request collections (git-friendly)
- **TUI**: Interactive terminal UI for browsing and testing

## Variable Resolution

Variables are resolved in this order (narrowest wins):
1. Request `--vars` flag (highest priority)
2. Collection's active environment
3. Global variables (`variables.nuon`)
4. Built-in variables

## Usage Examples

### Global Variables

```nushell
# Set global variables (available to all requests)
api vars set api_version "v1"
api vars set timeout "30"

# List global variables
api vars list

# Remove a global variable
api vars unset timeout
```

### Collection Environments

```nushell
# Create an environment for a collection
api collection env create my-api dev
api collection env create my-api prod

# Set variables in an environment
api collection env use my-api dev
api collection env set my-api base_url "http://localhost:3000"
api collection env set my-api api_key "dev-key-123"

# Switch environments
api collection env use my-api prod
api collection env set my-api base_url "https://api.example.com"

# Show environment variables
api collection env show my-api
```

### Making Requests

```nushell
# Simple requests (use global variables only)
api get "https://api.example.com/users"
api post "https://api.example.com/users" -b '{"name": "John"}'

# Using variables
api get "{{base_url}}/{{api_version}}/users"

# With headers
api get "{{base_url}}/users" -H { "X-Custom-Header": "value" }

# Send saved request (uses collection environment + global vars)
api send get-users -c my-api
```

### Authentication

```nushell
# Bearer token
api auth bearer set mytoken "your-jwt-token-here"
api get "{{base_url}}/protected" -a { type: bearer, token_ref: mytoken }

# Basic auth
api auth basic set mycreds "username" "password"

# API key
api auth apikey set mykey "api-key-123" --header "X-API-Key"

# OAuth2 (client credentials)
api auth oauth2 configure myapp --client-id "id" --client-secret "secret" --token-url "https://auth.example.com/token"
api auth oauth2 token myapp
```

### Working with Collections

```nushell
# List collections
api collection list

# Create a collection
api collection create my-api -d "My API Collection"

# Create a saved request
api request create users/list --method GET --url "{{base_url}}/users" -c my-api

# Send saved request
api send users/list -c my-api

# List requests in collection
api request list -c my-api
```

### History

```nushell
# List recent history
api history list

# Search history
api history search "users"

# Resend a request
api history resend <id>

# Show request details
api history show <id>
```

### Request Chaining

```nushell
# Run a chain from file
api chain exec example-workflow

# Run inline chain
api chain run [
    { request: "auth/login", extract: { token: "body.access_token" } }
    { request: "users/profile", use: { bearer_token: "{{token}}" } }
]
```

### TUI (Terminal UI)

```nushell
# Launch interactive TUI
api tui
```

## Built-in Variables

Use these in any request:
- `{{$uuid}}` - Random UUID v4
- `{{$timestamp}}` - ISO 8601 timestamp
- `{{$timestamp_unix}}` - Unix timestamp
- `{{$random_int}}` - Random integer 0-999999
- `{{$random_string}}` - Random 16-character string
- `{{$random_email}}` - Random email address
- `{{$date}}` - Current date (YYYY-MM-DD)
- `{{$time}}` - Current time (HH:MM:SS)

## Project Structure

```
ApiRequests/
├── api.nu                 # Entry point (source this file)
├── config.nuon            # Global configuration
├── variables.nuon         # Global variables
├── secrets.nuon           # Credentials (gitignored)
├── nu_modules/            # Core modules
│   ├── mod.nu             # Main module + collection commands
│   ├── http.nu            # HTTP requests
│   ├── auth.nu            # Authentication
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
│       └── requests/          # Saved requests
├── chains/                # Chain definitions
└── history/               # Request/response history
```

## Requirements

- nushell >= 0.89
- curl (system installed)

## Example Collection

The included `jsonplaceholder` collection demonstrates using the [JSONPlaceholder](https://jsonplaceholder.typicode.com) API:

```nushell
# Set up collection environment
api collection env use jsonplaceholder default

# Get all posts
api send get-posts

# Get a specific post
api collection env set jsonplaceholder post_id "1"
api send get-post

# Create a post
api send create-post

# Run the example chain
api chain exec example-workflow
```
