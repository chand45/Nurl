# Private persistence helpers for workspace NUON state.

use command-error.nu [fail-command]

const STATE_TEMP_MAX_AGE = 1hr
const STATE_TEMP_UUID = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

def has-legacy-filesystem-errors [] {
    (version | get version | str starts-with "0.89.")
}

def state-rm-reports-structured [] {
    let raw = try { (version).version } catch { null }
    if $raw == null { return false }
    let parts = ($raw | split row ".")
    if ($parts | length) != 3 { return false }
    let parsed = try {
        {ok: true, value: ($parts | each {|part| $part | into int })}
    } catch {
        {ok: false, value: []}
    }
    if not $parsed.ok { return false }
    let major = ($parsed.value | get 0)
    let minor = ($parsed.value | get 1)
    let patch = ($parsed.value | get 2)
    ($major > 0) or ($minor > 113) or (($minor == 113) and ($patch >= 1))
}

def cleanup-state-paths [
    paths: list<string>
    destination: string
    --stale
] {
    if ($paths | is-empty) { return }
    if (state-rm-reports-structured) {
        for path in $paths {
            let outcome = (rm --force --verbose $path | default [])
            for row in $outcome {
                if not ($row.deleted? | default false) {
                    let failed_path = ($row.path? | default $destination)
                    let label = if $stale { "Stale state temporary file" } else { "State temporary file" }
                    print --stderr $"($label) '($failed_path)' could not be removed; remove it manually."
                }
            }
        }
        return
    }
    for path in $paths {
        try {
            rm --force $path
        } catch {
            let label = if $stale { "Stale state temporary file" } else { "State temporary file" }
            print --stderr $"($label) '($path)' could not be removed; remove it manually."
        }
    }
}

def remove-state-path [path: string, destination: string] {
    cleanup-state-paths [$path] $destination
    $path | path exists
}

def sweep-stale-sibling-temps [destination: string] {
    let parent = ($destination | path dirname)
    let prefix = $".($destination | path basename).nurl-"
    let cutoff = ((date now) - $STATE_TEMP_MAX_AGE)
    let entries = (do -i { ls -a $parent } | default [])
    let aged = (
        $entries
        | where {|entry|
            let name = ($entry.name | path basename)
            let suffix = ($name | str replace $prefix "")
            (
                ($name | str starts-with $prefix)
                and ($suffix =~ $"^($STATE_TEMP_UUID)\\.tmp$")
                and ($entry.modified < $cutoff)
            )
        }
    )

    cleanup-state-paths ($aged | get name) $destination --stale
}

export def state-replacement-temp-path [destination_path: string] {
    sweep-stale-sibling-temps $destination_path
    $destination_path
    | path dirname
    | path join $".($destination_path | path basename).nurl-(random uuid).tmp"
}

def write-state-temp [destination: string, temp_path: string, serialized: any] {
    if $nu.os-info.name != "windows" and ($destination | path exists) {
        cp $destination $temp_path
        $serialized | save -f $temp_path
    } else {
        $serialized | save $temp_path
    }
}

export def state-persistence-contract [] {
    "best-effort"
}

export def verify-state-publication [serialized: any, temp_path: string, destination: string] {
    let observed = (open $destination --raw)
    if $observed != $serialized {
        let cleanup = if ($temp_path | path exists) {
            $"Temporary file retained at '($temp_path)'; inspect the destination and temporary file before retrying."
        } else {
            "No temporary file remains; inspect the destination before retrying."
        }
        fail-command $"State file '($destination)' does not match the intended bytes after publication. ($cleanup)"
    }
}

export def commit-state-replace [serialized: any, temp_path: string, destination: string] {
    if (has-legacy-filesystem-errors) {
        do -i { mv -f $temp_path $destination }
    } else {
        try { mv -f $temp_path $destination } catch {}
    }
    verify-state-publication $serialized $temp_path $destination
}

export def save-state-replace [serialized: any, destination: string] {
    let destination_path = ($destination | path expand)
    let temp_path = (state-replacement-temp-path $destination_path)
    let legacy_errors = (has-legacy-filesystem-errors)

    let write_result = if $legacy_errors {
        do -i {
            write-state-temp $destination_path $temp_path $serialized
            "ok"
        }
    } else {
        try {
            write-state-temp $destination_path $temp_path $serialized
            "ok"
        } catch {
            null
        }
    }
    let staged = if ($write_result == "ok") and ($temp_path | path exists) {
        let staged_read = try {
            {ok: true, value: (open $temp_path --raw)}
        } catch {
            {ok: false, value: null}
        }
        $staged_read.ok and ($staged_read.value == $serialized)
    } else {
        false
    }
    if not $staged {
        remove-state-path $temp_path $destination_path | ignore
        fail-command $"Could not stage state file '($destination_path)'. The previous file was preserved; check the destination directory and try again."
    }

    commit-state-replace $serialized $temp_path $destination_path
}

export def state-base-type [value: any] {
    let described = ($value | describe --detailed)
    $described | get type
}

export def open-state-value [path: string, description: string] {
    let raw = (open $path --raw)
    let parsed = try {
        {ok: true, value: ($raw | from nuon)}
    } catch {
        {ok: false, value: null}
    }
    if not $parsed.ok {
        fail-command $"Invalid state file '($path)': expected valid NUON for ($description). Repair or replace the file."
    }
    $parsed.value
}

export def open-state-record [path: string, description: string] {
    let value = (open-state-value $path $description)
    if not (($value | describe) | str starts-with "record") {
        fail-command $"Invalid state file '($path)': expected a NUON record for ($description). Repair or replace the file."
    }
    $value
}

export def open-state-record-or-default [
    path: string
    default_value: record
    description: string
] {
    if not ($path | path exists) {
        return $default_value
    }
    open-state-record $path $description
}
