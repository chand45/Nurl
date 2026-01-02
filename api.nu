# API Client Entry Point
# Source this file to use the API client: source api.nu

# Set the API root directory to where this file is located
$env.API_ROOT = ($env.FILE_PWD? | default (pwd))

# Load all modules
use nu_modules/mod.nu *

# Show welcome message
print $"(ansi blue)API Client loaded.(ansi reset) Type '(ansi green)api help(ansi reset)' for available commands."
