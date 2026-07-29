# Private persistence helpers for workspace NUON state.

use command-error.nu [fail-command]

def state-temp-path [path: string] {
    let parent = ($path | path dirname)
    let name = ($path | path basename)
    $parent | path join $".($name).nurl-(random uuid).tmp"
}

def remove-state-temp [path: string] {
    if ($path | path exists) {
        try {
            rm -f $path
            null
        } catch {|error|
            $error
        }
    } else {
        null
    }
}

def remove-stale-state-temp-compat [path: string] {
    try {
        do -c { rm -f $path }
        null
    } catch {|error| $error}
}

def remove-stale-state-temp-current [path: string] {
    try {
        rm -f $path
        null
    } catch {|error| $error}
}

def state-temp-readable [path: string] {
    try {
        open $path --raw | ignore
        true
    } catch {
        false
    }
}

def cleanup-stale-state-temps [destination: string] {
    let parent = ($destination | path dirname)
    if not ($parent | path exists) {
        return
    }
    let prefix = $".(($destination | path basename)).nurl-"
    for entry in (ls -a $parent) {
        let name = ($entry.name | path basename)
        let suffix = if ($name | str starts-with $prefix) {
            $name | str substring ($prefix | str length)..
        } else {
            ""
        }
        let exact_temp = (
            $suffix =~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.tmp$'
        )
        if $exact_temp and (((date now) - $entry.modified) > 1hr) {
            let runtime_minor = (version | get version | split row "." | get 1 | into int)
            let cleanup_error = if $entry.type != "file" {
                {msg: "not a removable state temp file"}
            } else if ($runtime_minor < 100) and (not (state-temp-readable $entry.name)) {
                {msg: "state temp is not readable"}
            } else if $runtime_minor < 100 {
                remove-stale-state-temp-compat $entry.name
            } else {
                remove-stale-state-temp-current $entry.name
            }
            if ($cleanup_error != null) or ($entry.name | path exists) {
                print -e $"Warning: Could not remove stale state temp '($entry.name)'; remove it manually."
            }
        }
    }
}

def fail-after-cleanup [error: record, temp_path: string] {
    let cleanup_error = (remove-state-temp $temp_path)
    let message = if $cleanup_error == null {
        $error.msg
    } else {
        $"($error.msg); temporary state cleanup also failed: ($cleanup_error.msg)"
    }
    error make {msg: $message}
}

def write-replacement-temp [destination: string, temp_path: string, serialized: any] {
    $serialized | save $temp_path
}

# Commit already serialized state bytes.
export def save-state-bytes [
    path: string
    serialized: any
    --no-clobber
    --exists-message: string = "Destination file already exists"
] {
    if $no_clobber {
        let create_error = try {
            $serialized | save $path
            null
        } catch {|error| $error}
        if $create_error != null {
            if $create_error.msg == "Destination file already exists" {
                fail-command $exists_message
            }
            error make {msg: $create_error.msg}
        }
        return
    }

    # Existing leaf symlinks resolve to their targets; aliased ancestors remain
    # valid filesystem paths and are not rejected by lexical string comparison.
    let destination = ($path | path expand)
    cleanup-stale-state-temps $destination
    let temp_path = (state-temp-path $destination)
    let write_error = try {
        write-replacement-temp $destination $temp_path $serialized
        null
    } catch {|error| $error}
    if $write_error != null {
        fail-after-cleanup $write_error $temp_path
    }

    let commit_error = try {
        mv -f $temp_path $destination
        null
    } catch {|error| $error}
    if $commit_error != null {
        fail-after-cleanup $commit_error $temp_path
    }
}

def invalid-state-value [path: string] {
    fail-command $"State file '($path)' contains invalid NUON. Restore or recreate the file, then retry."
}

def invalid-state-record [path: string] {
    fail-command $"State file '($path)' is invalid or does not contain a NUON record. Restore or recreate the file, then retry."
}

export def open-state-value [path: string] {
    let raw = (open $path --raw)
    let parsed = try {
        {valid: true, value: ($raw | from nuon)}
    } catch {
        {valid: false, value: null}
    }
    if not $parsed.valid {
        invalid-state-value $path
    }
    $parsed.value
}

export def open-state-record [path: string] {
    let value = (open-state-value $path)
    if not (($value | describe) | str starts-with "record") {
        invalid-state-record $path
    }
    $value
}

export def open-state-record-or-default [path: string, default_value: record] {
    if not ($path | path exists) {
        return $default_value
    }
    try {
        open-state-record $path
    } catch {|error|
        if ($error.msg | str starts-with "State file '") {
            error make {msg: $error.msg}
        }
        error make {msg: $"Could not read state file '($path)': ($error.msg)"}
    }
}
