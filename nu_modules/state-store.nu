# Private persistence helpers for workspace NUON state.

use command-error.nu [fail-command]

const STATE_TEMP_MAX_AGE = 1hr

def state-temp-path [destination: string] {
    ($destination | path dirname)
    | path join $".($destination | path basename).nurl-(random uuid).tmp"
}

def state-path-removable [path: string] {
    if not ($path | path exists) {
        return false
    }
    if (try { ($path | path type) == "dir" } catch { true }) {
        return false
    }
    if $nu.os-info.name == "windows" {
        return (try {
            "" | save --append $path
            true
        } catch {
            false
        })
    }

    try {
        let info = (ls -l -D ($path | path dirname) | first)
        let mode = ($info.mode? | default "")
        let user = ($env.USER? | default ($env.USERNAME? | default ""))
        if $user == ($info.user? | default "") and ($mode | str length) >= 2 {
            ($mode | split chars | get 1) == "w"
        } else if ($mode | str length) >= 8 {
            ($mode | split chars | get 7) == "w"
        } else {
            false
        }
    } catch {
        false
    }
}

def remove-state-path [path: string] {
    if not ($path | path exists) {
        return true
    }
    if not (state-path-removable $path) {
        return false
    }
    try { rm -f $path | ignore } catch {|error| $error | ignore }
    not ($path | path exists)
}

def sweep-stale-sibling-temps [destination: string] {
    let parent = ($destination | path dirname)
    let prefix = $".($destination | path basename).nurl-"
    let cutoff = ((date now) - $STATE_TEMP_MAX_AGE)
    let aged = try {
        ls -a $parent
        | where {|entry|
            let name = ($entry.name | path basename)
            (
                ($name | str starts-with $prefix)
                and ($name | str ends-with ".tmp")
                and ($entry.modified < $cutoff)
            )
        }
    } catch {
        []
    }

    for entry in $aged {
        if not (remove-state-path $entry.name) {
            print -e $"Warning: Stale state temporary file '($entry.name)' could not be removed; remove it manually."
        }
    }
}

def write-state-temp [destination: string, temp_path: string, serialized: any] {
    if $nu.os-info.name != "windows" and ($destination | path exists) {
        cp $destination $temp_path
        $serialized | save -f $temp_path
    } else {
        $serialized | save $temp_path
    }
}

export def save-state-replace [serialized: any, destination: string] {
    let destination_path = ($destination | path expand)
    sweep-stale-sibling-temps $destination_path
    let temp_path = (state-temp-path $destination_path)

    try {
        write-state-temp $destination_path $temp_path $serialized
    } catch {|error|
        remove-state-path $temp_path | ignore
        fail-command $"Could not write state file '($destination_path)': ($error.msg)"
    }

    try {
        mv -f $temp_path $destination_path | ignore
        null
    } catch {|error|
        $error | ignore
    } | ignore
    if ($temp_path | path exists) {
        remove-state-path $temp_path | ignore
        fail-command $"Could not publish state file '($destination_path)'."
    }
}

export def save-state-no-clobber [serialized: any, destination: string, exists_message: string] {
    try {
        $serialized | save $destination
    } catch {|error|
        if ($destination | path exists) {
            fail-command $exists_message
        }
        fail-command $"Could not create state file '($destination)': ($error.msg)"
    }
}

export def save-state-if-absent [serialized: any, destination: string] {
    try {
        $serialized | save $destination
    } catch {|error|
        if not ($destination | path exists) {
            fail-command $"Could not create state file '($destination)': ($error.msg)"
        }
    }
}

def state-base-type [value: any] {
    let described = ($value | describe --detailed)
    $described | get type
}

export def open-state-value [path: string, description: string] {
    # Native read failures must propagate unchanged; only NUON parsing is normalized.
    let raw = (open $path --raw)
    let parsed = try {
        {value: ($raw | from nuon), error: null}
    } catch {|error|
        {value: null, error: $error}
    }
    if $parsed.error != null {
        fail-command $"Could not parse ($description) at '($path)' as NUON."
    }
    $parsed.value
}

export def open-state-record [path: string, description: string] {
    let value = (open-state-value $path $description)
    if (state-base-type $value) != "record" {
        fail-command $"($description) must contain a record at '($path)'."
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
