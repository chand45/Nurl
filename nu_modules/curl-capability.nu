# Shared curl capability preflight for HTTP execution paths.

use command-error.nu [fail-command]

export def require-curl-capability [--dry-run] {
    if $dry_run {
        return
    }

    let version_result = try {
        {value: (curl --version | complete), error: null}
    } catch {|error|
        {value: null, error: $error}
    }
    if $version_result.error != null or $version_result.value.exit_code != 0 {
        fail-command "Nurl requires curl 7.83.0 or newer for fileless response metadata"
    }
    let parsed = (
        $version_result.value.stdout
        | lines
        | get 0
        | parse --regex '^curl\s+(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)'
    )
    if ($parsed | is-empty) {
        fail-command "Could not determine whether curl supports fileless response metadata"
    }
    let version = ($parsed | get 0)
    let major = ($version.major | into int)
    let minor = ($version.minor | into int)
    let patch = ($version.patch | into int)
    let supported = (
        $major > 7
        or ($major == 7 and $minor > 83)
        or ($major == 7 and $minor == 83 and $patch >= 0)
    )
    if not $supported {
        fail-command $"Nurl requires curl 7.83.0 or newer for fileless response metadata \(found ($major).($minor).($patch)\)"
    }
}
