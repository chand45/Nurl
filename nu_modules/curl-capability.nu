# Shared curl capability preflight for HTTP execution paths.

use command-error.nu [fail-command]

const CURL_MIN_VERSION = "7.75.0"

export def require-curl-capability [--dry-run] {
    if $dry_run {
        return
    }

    let version_result = try {
        {value: (do { curl -q --version } | complete), error: null}
    } catch {|error|
        {value: null, error: $error}
    }
    if $version_result.error != null or $version_result.value.exit_code != 0 {
        fail-command $"Nurl requires curl ($CURL_MIN_VERSION) or newer for fileless response metadata"
    }
    let parsed = (
        $version_result.value.stdout
        | lines
        | get 0
        | parse --regex '^curl(?:\.exe)?\s+(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:[^0-9.].*)?$'
    )
    if ($parsed | is-empty) {
        fail-command "Could not determine whether curl supports fileless response metadata"
    }
    let version = ($parsed | get 0)
    let major = ($version.major | into int)
    let minor = ($version.minor | into int)
    let patch = ($version.patch | into int)
    let required = ($CURL_MIN_VERSION | split row "." | each {|part| $part | into int })
    let supported = (
        $major > $required.0
        or ($major == $required.0 and $minor > $required.1)
        or ($major == $required.0 and $minor == $required.1 and $patch >= $required.2)
    )
    if not $supported {
        fail-command $"Nurl requires curl ($CURL_MIN_VERSION) or newer for fileless response metadata \(found ($major).($minor).($patch)\)"
    }
}
