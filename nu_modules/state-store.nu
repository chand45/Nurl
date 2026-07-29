# Private persistence helpers for workspace NUON state.

use command-error.nu [fail-command]

const STATE_TEMP_MAX_AGE = 1hr

def state-temp-prefix [path: string] {
    $".($path | path basename).nurl-"
}

def state-temp-path [path: string] {
    let parent = ($path | path dirname)
    $parent | path join $"(state-temp-prefix $path)(random uuid).tmp"
}

def state-create-lock-path [path: string] {
    ($path | path dirname) | path join $".($path | path basename).nurl-create.lock"
}

def remove-state-path [path: string] {
    if ($path | path exists) {
        try {
            rm -rf $path
            null
        } catch {|error|
            $error
        }
    } else {
        null
    }
}

def fail-after-cleanup [error: record, temp_path: string] {
    let cleanup_error = (remove-state-path $temp_path)
    let message = if $cleanup_error == null {
        $error.msg
    } else {
        $"($error.msg); temporary state cleanup also failed: ($cleanup_error.msg)"
    }
    error make {msg: $message}
}

def cleanup-stale-state-path [path: string] {
    let parent = ($path | path dirname)
    if not ($parent | path exists) {
        return
    }
    let name = ($path | path basename)
    let entries = (
        try { ls -a $parent } catch { [] }
        | where {|entry| ($entry.name | path basename) == $name}
    )
    if ($entries | is-empty) {
        return
    }
    let entry = ($entries | first)
    if $entry.modified < ((date now) - $STATE_TEMP_MAX_AGE) {
        let cleanup_error = (remove-state-path $path)
        if $cleanup_error != null {
            error make {msg: $"Could not clean stale state path '($path)': ($cleanup_error.msg)"}
        }
    }
}

def cleanup-stale-state-temps [path: string] {
    let parent = ($path | path dirname)
    if not ($parent | path exists) {
        return
    }
    let prefix = (state-temp-prefix $path)
    let stale = (
        try { ls -a $parent } catch { [] }
        | where type == file
        | where {|entry|
            let name = ($entry.name | path basename)
            (($name | str starts-with $prefix)
                and ($name | str ends-with ".tmp")
                and ($entry.modified < ((date now) - $STATE_TEMP_MAX_AGE)))
        }
    )
    for entry in $stale {
        let cleanup_error = (remove-state-path $entry.name)
        if $cleanup_error != null {
            error make {msg: $"Could not clean stale state temporary file '($entry.name)': ($cleanup_error.msg)"}
        }
    }
    cleanup-stale-state-path (state-create-lock-path $path)
}

def release-state-create-lock [lock_path: string, path: string, published: bool] {
    let cleanup_error = (remove-state-path $lock_path)
    if $cleanup_error != null {
        let outcome = if $published { "was created" } else { "was not created" }
        error make {
            msg: $"State file '($path)' ($outcome), but create-lock cleanup failed: ($cleanup_error.msg)"
        }
    }
}

def commit-state-no-clobber [temp_path: string, path: string, exists_message: string] {
    let lock_path = (state-create-lock-path $path)
    cleanup-stale-state-path $lock_path
    let lock_error = try {
        mkdir $lock_path
        null
    } catch {|error|
        $error
    }
    if $lock_error != null {
        if ($path | path exists) {
            fail-command $exists_message
        }
        error make {msg: $"Could not acquire state create lock for '($path)': ($lock_error.msg)"}
    }

    if ($path | path exists) {
        release-state-create-lock $lock_path $path false
        fail-command $exists_message
    }

    let publish_error = try {
        mv -f $temp_path $path
        null
    } catch {|error|
        $error
    }
    if $publish_error != null {
        let lock_cleanup_error = (remove-state-path $lock_path)
        if $lock_cleanup_error != null {
            error make {
                msg: $"($publish_error.msg); create-lock cleanup also failed: ($lock_cleanup_error.msg)"
            }
        }
        error make {msg: $publish_error.msg}
    }

    release-state-create-lock $lock_path $path true
}

def commit-state-replace [temp_path: string, path: string] {
    mv -f $temp_path $path
}

# Commit already serialized state bytes through a unique same-directory file.
export def save-state-bytes [
    path: string
    serialized: any
    --no-clobber
    --exists-message: string = "Destination file already exists"
] {
    # Resolve an existing leaf symlink so replacement updates its target rather
    # than replacing the link itself.
    let destination_path = ($path | path expand)
    cleanup-stale-state-temps $destination_path
    if $no_clobber and ($destination_path | path exists) {
        fail-command $exists_message
    }

    let temp_path = (state-temp-path $destination_path)
    let write_error = try {
        if $nu.os-info.name != "windows" and ($destination_path | path exists) {
            # Nushell's native copy carries POSIX mode bits to the sibling temp.
            # Extended ACLs and ownership are intentionally not claimed.
            cp $destination_path $temp_path
            $serialized | save -f $temp_path
        } else {
            $serialized | save $temp_path
        }
        null
    } catch {|error|
        $error
    }
    if $write_error != null {
        fail-after-cleanup $write_error $temp_path
    }

    let commit_error = try {
        if $no_clobber {
            commit-state-no-clobber $temp_path $destination_path $exists_message
        } else {
            commit-state-replace $temp_path $destination_path
        }
        null
    } catch {|error|
        $error
    }
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

# Read errors remain visible; only NUON syntax failures are normalized.
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
    let opened = try {
        {found: true, value: (open-state-record $path)}
    } catch {|error|
        let debug = ($error.debug? | default "")
        if $error.msg == "File not found" and ($debug | str contains "FileNotFound") {
            {found: false, value: null}
        } else if ($error.msg | str starts-with "State file '") {
            error make {msg: $error.msg}
        } else {
            error make {msg: $"Could not read state file '($path)': ($error.msg)"}
        }
    }
    if $opened.found {
        $opened.value
    } else {
        $default_value
    }
}
