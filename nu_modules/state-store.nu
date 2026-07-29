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

def fail-after-cleanup [error: record, temp_path: string] {
    let cleanup_error = (remove-state-temp $temp_path)
    let message = if $cleanup_error == null {
        $error.msg
    } else {
        $"($error.msg); temporary state cleanup also failed: ($cleanup_error.msg)"
    }
    error make {msg: $message}
}

def state-command-error [result: record, fallback: string] {
    let detail = ($result.stderr | str trim)
    if ($detail | is-empty) {
        error make {msg: $fallback}
    } else {
        error make {msg: $detail}
    }
}

def preserve-state-mode [path: string, temp_path: string] {
    if not ($path | path exists) {
        return null
    }

    if $nu.os-info.name == "windows" {
        let script = "try { $acl = [System.IO.File]::GetAccessControl($env:NURL_STATE_DESTINATION); [System.IO.File]::SetAccessControl($env:NURL_STATE_SOURCE, $acl) } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }"
        let result = (
            do {
                with-env {
                    NURL_STATE_SOURCE: $temp_path
                    NURL_STATE_DESTINATION: $path
                } {
                    ^powershell.exe -NoProfile -NonInteractive -Command $script
                }
            }
            | complete
        )
        if $result.exit_code != 0 {
            return {msg: ($result.stderr | str trim)}
        }
        return null
    }

    let stat_result = if $nu.os-info.name == "macos" {
        do { ^stat -f "%Lp" $path } | complete
    } else {
        do { ^stat -c "%a" $path } | complete
    }
    if $stat_result.exit_code != 0 {
        return {msg: ($stat_result.stderr | str trim)}
    }

    let mode = ($stat_result.stdout | str trim)
    let chmod_result = (do { ^chmod $mode $temp_path } | complete)
    if $chmod_result.exit_code != 0 {
        return {msg: ($chmod_result.stderr | str trim)}
    }
    null
}

def commit-state-file [temp_path: string, path: string, no_clobber: bool] {
    let injected_path = ($env.NURL_TEST_STATE_STORE_FAIL_COMMIT? | default "")
    if $injected_path != "" and (($injected_path | path expand) == $path) {
        error make {msg: $"Injected state commit failure for '($path)'"}
    }

    if $nu.os-info.name == "windows" {
        let backup_path = if $no_clobber { "" } else { state-temp-path $path }
        let script = if $no_clobber {
            "try { [System.IO.File]::Move($env:NURL_STATE_SOURCE, $env:NURL_STATE_DESTINATION) } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }"
        } else {
            "try { if ([System.IO.File]::Exists($env:NURL_STATE_DESTINATION)) { [System.IO.File]::Replace($env:NURL_STATE_SOURCE, $env:NURL_STATE_DESTINATION, $env:NURL_STATE_BACKUP, $true) } else { [System.IO.File]::Move($env:NURL_STATE_SOURCE, $env:NURL_STATE_DESTINATION) } } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }"
        }
        let result = (
            do {
                with-env {
                    NURL_STATE_SOURCE: $temp_path
                    NURL_STATE_DESTINATION: $path
                    NURL_STATE_BACKUP: $backup_path
                } {
                    ^powershell.exe -NoProfile -NonInteractive -Command $script
                }
            }
            | complete
        )
        let backup_error = if $backup_path == "" {
            null
        } else {
            remove-state-temp $backup_path
        }
        if $result.exit_code != 0 {
            if $backup_error != null {
                error make {msg: $"($result.stderr | str trim); state backup cleanup also failed: ($backup_error.msg)"}
            }
            state-command-error $result $"Could not commit state file '($path)'"
        }
        if $backup_error != null {
            error make {msg: $"State commit succeeded but backup cleanup failed: ($backup_error.msg)"}
        }
        return true
    }

    if $no_clobber {
        let result = (do { ^ln $temp_path $path } | complete)
        if $result.exit_code != 0 {
            state-command-error $result $"Could not create state file '($path)'"
        }
        let cleanup_error = (remove-state-temp $temp_path)
        if $cleanup_error != null {
            error make {msg: $cleanup_error.msg}
        }
    } else {
        let result = (do { ^mv -f $temp_path $path } | complete)
        if $result.exit_code != 0 {
            state-command-error $result $"Could not replace state file '($path)'"
        }
    }
    true
}

# Commit already serialized state bytes through a unique sibling file.
export def save-state-bytes [
    path: string
    serialized: any
    --no-clobber
    --exists-message: string = "Destination file already exists"
] {
    # Resolve an existing leaf symlink so atomic replacement updates its target
    # rather than replacing the link itself.
    let destination_path = ($path | path expand)
    if $no_clobber and ($destination_path | path exists) {
        fail-command $exists_message
    }

    let temp_path = (state-temp-path $destination_path)
    let prepare_error = try {
        "" | save $temp_path
        null
    } catch {|error|
        $error
    }
    if $prepare_error != null {
        fail-after-cleanup $prepare_error $temp_path
    }

    let metadata_error = (preserve-state-mode $destination_path $temp_path)
    if $metadata_error != null {
        fail-after-cleanup $metadata_error $temp_path
    }

    let write_error = try {
        $serialized | save -f $temp_path
        null
    } catch {|error|
        $error
    }
    if $write_error != null {
        fail-after-cleanup $write_error $temp_path
    }

    let commit = try {
        {moved: (commit-state-file $temp_path $destination_path $no_clobber), error: null}
    } catch {|error|
        {moved: false, error: $error}
    }

    if not $commit.moved {
        let cleanup_error = (remove-state-temp $temp_path)
        if $no_clobber and ($destination_path | path exists) {
            if $cleanup_error != null {
                error make {msg: $"($exists_message); temporary state cleanup also failed: ($cleanup_error.msg)"}
            }
            fail-command $exists_message
        }
        let error = ($commit.error? | default {msg: $"Could not commit state file '($path)'"})
        let message = if $cleanup_error == null {
            $error.msg
        } else {
            $"($error.msg); temporary state cleanup also failed: ($cleanup_error.msg)"
        }
        error make {msg: $message}
    }
}

def invalid-state-record [path: string] {
    fail-command $"State file '($path)' is invalid or does not contain a NUON record. Restore or recreate the file, then retry."
}

# Read errors remain visible; only parse and record-shape failures are normalized.
export def open-state-record [path: string] {
    let raw = (open $path --raw)
    let parsed = try {
        let value = ($raw | from nuon)
        if (($value | describe) | str starts-with "record") {
            {valid: true, value: $value}
        } else {
            {valid: false, value: null}
        }
    } catch {
        {valid: false, value: null}
    }

    if not $parsed.valid {
        invalid-state-record $path
    }
    $parsed.value
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
