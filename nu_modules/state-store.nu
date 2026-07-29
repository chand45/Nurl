# Private persistence helpers for workspace NUON state.

use command-error.nu [fail-command]

const STATE_LOCK_MAX_AGE = 1hr

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

def state-temp-ready-path [path: string] {
    (state-temp-dir $path) | path join ".secured-v1"
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
    let lexical = ($dir | path expand --no-symlink)
    let resolved = ($dir | path expand)
    if $lexical != $resolved {
        fail-command $"State temp directory '($dir)' must not be a link or reparse point"
    }
}

def secure-state-temp-dir [path: string] {
    let dir = (state-temp-dir $path)
    let ready = (state-temp-ready-path $path)
    validate-state-temp-dir $dir
    if ($ready | path exists) {
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

    "secured" | save -f ($candidate | path join ".secured-v1")
    if $candidate != $dir {
        if ($dir | path exists) {
            validate-state-temp-dir $dir
            if not ((state-temp-ready-path $path) | path exists) {
                remove-state-path $candidate | ignore
                fail-command $"State temp directory '($dir)' appeared without a security marker"
            }
            remove-state-path $candidate | ignore
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

def release-state-create-lock [lock_path: string, path: string, published: bool] {
    let cleanup_error = (remove-state-path $lock_path)
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
    if not ($entries | is-empty) and (($entries | first | get modified) < ((date now) - $STATE_LOCK_MAX_AGE)) {
        let cleanup_error = (remove-state-path $lock_path)
        if $cleanup_error != null {
            error make {msg: $"Could not clean stale state create lock '($lock_path)': ($cleanup_error.msg)"}
        }
    }
}

def commit-state-no-clobber [temp_path: string, path: string, exists_message: string] {
    let lock_path = (state-create-lock-path $path)
    cleanup-stale-create-lock $lock_path
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
    if not ((state-temp-ready-path $destination_path) | path exists) {
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
    if ($write_error != null) and (not ((state-temp-ready-path $destination_path) | path exists)) {
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
