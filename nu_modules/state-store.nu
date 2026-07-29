# Private persistence helpers for workspace NUON state.

use command-error.nu [fail-command]

const STATE_LOCK_MAX_AGE = 1hr

export-env {
    # Process-local proof that a marker was written after this module loaded.
    # Unlike a PID, this token cannot be predicted by a preexisting workspace.
    $env.NURL_STATE_SESSION_TOKEN = (random uuid)
}

def state-temp-dir [path: string] {
    ($path | path dirname) | path join ".nurl-state"
}

def state-temp-prefix [path: string] {
    $".($path | path basename).nurl-"
}

def state-temp-path [path: string] {
    (state-temp-dir $path) | path join $"(state-temp-prefix $path)(random uuid).tmp"
}

def state-create-lock-path [path: string] {
    (state-temp-dir $path) | path join $".($path | path basename).create.lock"
}

def legacy-state-create-lock-path [path: string] {
    ($path | path dirname) | path join $".($path | path basename).nurl-create.lock"
}

def state-temp-ready-path [path: string] {
    (state-temp-dir $path) | path join ".secured-v2"
}

def state-temp-ready-value [] {
    $"secured-v2:($env.NURL_STATE_SESSION_TOKEN)"
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

def validate-state-temp-dir [dir: string] {
    if not ($dir | path exists) {
        return
    }
    if (($dir | path type) != "dir") {
        fail-command $"State temp path '($dir)' must be a directory"
    }
}

def state-temp-ready-for-process [path: string] {
    let ready = (state-temp-ready-path $path)
    if not ($ready | path exists) {
        return false
    }
    try {
        (open $ready --raw) == (state-temp-ready-value)
    } catch {
        false
    }
}

def secure-state-temp-dir [path: string] {
    let dir = (state-temp-dir $path)
    let ready = (state-temp-ready-path $path)
    validate-state-temp-dir $dir
    if (state-temp-ready-for-process $path) {
        return $dir
    }

    let candidate = if ($dir | path exists) {
        $dir
    } else {
        ($dir | path dirname) | path join $".nurl-state-setup-(random uuid)"
    }
    if not ($candidate | path exists) {
        let create_error = try {
            mkdir $candidate
            null
        } catch {|error|
            $error
        }
        if $create_error != null {
            error make {msg: $"Could not create state temp directory '($candidate)': ($create_error.msg)"}
        }
    }

    let secured = if $nu.os-info.name == "windows" {
        let system_root = ($env.SystemRoot? | default 'C:\Windows')
        let icacls = ($system_root | path join "System32" "icacls.exe")
        let domain = ($env.USERDOMAIN? | default "")
        let user = ($env.USERNAME? | default "")
        let identity = if ($domain | is-empty) { $user } else { $domain + "\\" + $user }
        if ($identity | is-empty) {
            {ok: false, detail: "current Windows identity is unavailable"}
        } else {
            let grant = $identity + ":(OI)(CI)F"
            let owner_result = (
                do { ^$icacls $candidate "/setowner" $identity "/Q" }
                | complete
            )
            let reset_result = (
                do { ^$icacls $candidate "/reset" "/T" "/C" "/Q" }
                | complete
            )
            let acl_result = (
                do { ^$icacls $candidate "/inheritance:r" "/grant:r" $grant "/Q" }
                | complete
            )
            {
                ok: (
                    (($owner_result.exit_code? | default 1) == 0)
                        and (($reset_result.exit_code? | default 1) == 0)
                        and (($acl_result.exit_code? | default 1) == 0)
                )
                detail: (
                    [
                        ($owner_result.stderr? | default "")
                        ($reset_result.stderr? | default "")
                        ($acl_result.stderr? | default "")
                    ]
                    | str join " "
                    | str trim
                )
            }
        }
    } else {
        let result = (do { ^chmod 700 $candidate } | complete)
        {
            ok: (($result.exit_code? | default 1) == 0)
            detail: ($result.stderr? | default "" | str trim)
        }
    }

    if not $secured.ok {
        if $candidate != $dir {
            remove-state-path $candidate | ignore
        }
        fail-command $"Could not secure state temp directory '($candidate)'"
    }

    (state-temp-ready-value) | save -f ($candidate | path join ".secured-v2")
    if $candidate != $dir {
        if ($dir | path exists) {
            validate-state-temp-dir $dir
            remove-state-path $candidate | ignore
            return (secure-state-temp-dir $path)
        } else {
            mv -f $candidate $dir
        }
    }
    validate-state-temp-dir $dir
    if not ($ready | path exists) {
        mv -f $candidate $dir
    }
    $dir
}

export def initialize-state-store [root: string] {
    secure-state-temp-dir ($root | path join "config.nuon") | ignore
}

def release-state-create-lock [lock_path: string, owner: string, path: string, published: bool] {
    let observed = try {
        open $lock_path --raw
    } catch {|error|
        let outcome = if $published { "was created" } else { "was not created" }
        error make {msg: $"State file '($path)' ($outcome), but its create lock could not be read: ($error.msg)"}
    }
    if $observed != $owner {
        let outcome = if $published { "was created" } else { "was not created" }
        error make {msg: $"State file '($path)' ($outcome), but create-lock ownership changed"}
    }
    let cleanup_error = try {
        rm -f $lock_path
        null
    } catch {|error| $error}
    if $cleanup_error != null {
        let outcome = if $published { "was created" } else { "was not created" }
        error make {
            msg: $"State file '($path)' ($outcome), but create-lock cleanup failed: ($cleanup_error.msg)"
        }
    }
}

def cleanup-stale-create-lock [lock_path: string] {
    if not ($lock_path | path exists) {
        return
    }
    let entries = (
        ls -a ($lock_path | path dirname)
        | where {|entry| ($entry.name | path basename) == ($lock_path | path basename)}
    )
    if ($entries | is-empty) {
        return
    }
    let stale = (($entries | first | get modified) < ((date now) - $STATE_LOCK_MAX_AGE))
    if not $stale {
        return
    }

    let reclaim_path = $"($lock_path).reclaim"
    let reclaim_owner = (random uuid)
    let reclaim_error = try {
        $reclaim_owner | save $reclaim_path
        null
    } catch {|error| $error}
    if $reclaim_error != null {
        return
    }

    let cleanup_error = try {
        let current_entries = (
            ls -a ($lock_path | path dirname)
            | where {|entry| ($entry.name | path basename) == ($lock_path | path basename)}
        )
        if not ($current_entries | is-empty) {
            let still_stale = (($current_entries | first | get modified) < ((date now) - $STATE_LOCK_MAX_AGE))
            if $still_stale {
                let removal_error = (remove-state-path $lock_path)
                if $removal_error != null {
                    error make {msg: $removal_error.msg}
                }
            }
        }
        null
    } catch {|error| $error}

    let observed_owner = try { open $reclaim_path --raw } catch { "" }
    let release_error = if $observed_owner == $reclaim_owner {
        remove-state-path $reclaim_path
    } else {
        {msg: $"Stale-lock reclaim ownership changed for '($lock_path)'"}
    }
    if $cleanup_error != null {
        error make {msg: $"Could not clean stale state create lock '($lock_path)': ($cleanup_error.msg)"}
    }
    if $release_error != null {
        error make {msg: $release_error.msg}
    }
}

def require-state-create-lock-owner [lock_path: string, owner: string, path: string] {
    let observed = try { open $lock_path --raw } catch {
        error make {msg: $"State create lock for '($path)' disappeared before publication"}
    }
    if $observed != $owner {
        error make {msg: $"State create-lock ownership changed before publishing '($path)'"}
    }
}

def legacy-lock-move-required [] {
    let parts = ((version | get version) | split row ".")
    (($parts | first | into int) == 0) and (($parts | get 1 | into int) < 97)
}

def commit-state-no-clobber [temp_path: string, path: string, exists_message: string] {
    let legacy_lock_path = (legacy-state-create-lock-path $path)
    cleanup-stale-create-lock $legacy_lock_path
    if ($legacy_lock_path | path exists) {
        if ($path | path exists) {
            fail-command $exists_message
        }
        error make {msg: $"Could not acquire state create lock for '($path)': a legacy lock is still active"}
    }

    let lock_path = (state-create-lock-path $path)
    cleanup-stale-create-lock $lock_path
    let owner = (random uuid)
    let pending_path = $"($lock_path).($owner).pending"
    let lock_error = try {
        if (legacy-lock-move-required) {
            $owner | save $pending_path
            mv $pending_path $lock_path
        } else {
            $owner | save $lock_path
        }
        null
    } catch {|error|
        $error
    }
    remove-state-path $pending_path | ignore
    if $lock_error != null {
        if ($path | path exists) {
            fail-command $exists_message
        }
        error make {msg: $"Could not acquire state create lock for '($path)': ($lock_error.msg)"}
    }

    if ($path | path exists) {
        release-state-create-lock $lock_path $owner $path false
        fail-command $exists_message
    }
    require-state-create-lock-owner $lock_path $owner $path

    let publish_error = try {
        mv -f $temp_path $path
        null
    } catch {|error|
        $error
    }
    if $publish_error != null {
        let lock_cleanup_error = try {
            release-state-create-lock $lock_path $owner $path false
            null
        } catch {|error| $error}
        if $lock_cleanup_error != null {
            error make {
                msg: $"($publish_error.msg); create-lock cleanup also failed: ($lock_cleanup_error.msg)"
            }
        }
        error make {msg: $publish_error.msg}
    }

    release-state-create-lock $lock_path $owner $path true
}

def commit-state-replace [temp_path: string, path: string] {
    mv -f $temp_path $path
}

def write-state-temp [destination_path: string, temp_path: string, serialized: any] {
    if $nu.os-info.name != "windows" and ($destination_path | path exists) {
        # Nushell's native copy carries POSIX mode bits to the protected temp.
        # Extended ACLs and ownership are intentionally not claimed.
        cp $destination_path $temp_path
        $serialized | save -f $temp_path
    } else {
        $serialized | save $temp_path
    }
}

# Commit already serialized state bytes through a unique protected temp file.
export def save-state-bytes [
    path: string
    serialized: any
    --no-clobber
    --exists-message: string = "Destination file already exists"
] {
    # Resolve an existing leaf symlink so replacement updates its target rather
    # than replacing the link itself.
    let destination_path = ($path | path expand)
    if not (state-temp-ready-for-process $destination_path) {
        secure-state-temp-dir $destination_path | ignore
    }
    if $no_clobber and ($destination_path | path exists) {
        fail-command $exists_message
    }

    let temp_path = (state-temp-path $destination_path)
    mut write_error = try {
        write-state-temp $destination_path $temp_path $serialized
        null
    } catch {|error| $error}
    if ($write_error != null) and (not (state-temp-ready-for-process $destination_path)) {
        secure-state-temp-dir $destination_path | ignore
        $write_error = (try {
            write-state-temp $destination_path $temp_path $serialized
            null
        } catch {|error| $error})
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
