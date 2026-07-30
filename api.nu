# Nurl - Terminal API Client Entry Point
# Source this file to use Nurl: source ~/.nurl/api.nu

# Set the API root directory
# When installed via install script, this will be ~/.nurl
# When sourced from a cloned repo, this will use the repo directory
$env.API_ROOT = if not ($env.FILE_PWD? | is-empty) {
    $env.FILE_PWD
} else if ((not ($env.USERPROFILE? | is-empty)) and (($env.USERPROFILE | path join ".nurl") | path exists)) {
    # Windows: check USERPROFILE\.nurl
    $env.USERPROFILE | path join ".nurl"
} else if ((not ($env.HOME? | is-empty)) and (($env.HOME | path join ".nurl") | path exists)) {
    # Unix: check HOME/.nurl
    $env.HOME | path join ".nurl"
} else {
    # Fallback to current directory
    pwd
}

# Load all modules
use nu_modules/mod.nu *

# Show welcome message
print $"(ansi blue)Nurl loaded.(ansi reset) Type '(ansi green)api help(ansi reset)' for available commands."
