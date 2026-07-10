# Internal resource identifier validation and path containment.

def invalid-resource-name [kind: string, name: string, detail: string] {
    error make {
        msg: $"Invalid ($kind) name '($name)': ($detail)."
    }
}

# Validate a resource identifier before any filesystem access.
export def validate-resource-name [
    kind: string
    name: string
    --nested
    --scope: string = ""
] {
    let normalized = ($name | str replace --all "\\" "/")
    let rooted = (
        ($normalized | str starts-with "/")
        or ($normalized =~ '^[A-Za-z]:')
    )
    let segments = ($normalized | split row "/")

    if $nested {
        let invalid_segment = ($segments | any {|segment|
            $segment == "" or ($segment =~ '^\.+$')
        })

        if $rooted or $invalid_segment {
            let location = if $scope == "" { "its resource directory" } else { $scope }
            invalid-resource-name $kind $name $"path must remain under ($location) and cannot contain empty or dot-only navigation segments, including '.', '..', and '...'"
        }
    } else {
        if $rooted or $name == "" or ($name =~ '^\.+$') or ($segments | length) != 1 {
            invalid-resource-name $kind $name "expected one non-empty relative path segment without '/' or '\\'"
        }
    }

    $segments
}

def canonicalize-base [base: string] {
    mut probe = ($base | path expand --no-symlink)
    mut missing = []

    loop {
        if (($probe | path type) | is-not-empty) {
            break
        }

        let parent = ($probe | path dirname)
        if $parent == $probe {
            break
        }

        $missing = ($missing | append ($probe | path basename))
        $probe = $parent
    }

    mut resolved = ($probe | path expand)
    for segment in ($missing | reverse) {
        $resolved = ($resolved | path join $segment)
    }
    $resolved
}

def is-strict-descendant [candidate: string, base: string] {
    if $candidate == $base {
        return false
    }

    try {
        $candidate | path relative-to $base | ignore
        true
    } catch {
        false
    }
}

# Resolve a validated logical resource name beneath a trusted base directory.
# Existing path components are expanded one at a time so links cannot escape
# before containment is checked.
export def resolve-under-base [
    base: string
    logical_name: string
    kind: string
    --nested
    --suffix: string = ""
    --always-suffix
    --scope: string = ""
    --base-is-canonical
] {
    mut segments = (validate-resource-name $kind $logical_name --nested=$nested --scope=$scope)

    if $suffix != "" {
        let last_index = (($segments | length) - 1)
        let leaf = ($segments | get $last_index)
        if $always_suffix or (not ($leaf | str ends-with $suffix)) {
            $segments = ($segments | update $last_index $"($leaf)($suffix)")
        }
    }

    let canonical_base = if $base_is_canonical { $base } else { canonicalize-base $base }
    let location = if $scope == "" { $canonical_base } else { $scope }
    mut lexical_candidate = $canonical_base
    for segment in $segments {
        $lexical_candidate = ($lexical_candidate | path join $segment)
    }
    $lexical_candidate = ($lexical_candidate | path expand --no-symlink)
    if not (is-strict-descendant $lexical_candidate $canonical_base) {
        invalid-resource-name $kind $logical_name $"path must remain under ($location)"
    }

    mut candidate = $canonical_base
    mut parent_exists = true

    for segment in $segments {
        $candidate = ($candidate | path join $segment)

        if $parent_exists {
            if (($candidate | path type) | is-not-empty) {
                $candidate = ($candidate | path expand)
                if not (is-strict-descendant $candidate $canonical_base) {
                    invalid-resource-name $kind $logical_name $"path must remain under ($location); existing links cannot escape it"
                }
            } else {
                $parent_exists = false
            }
        }
    }

    if not (is-strict-descendant $candidate $canonical_base) {
        invalid-resource-name $kind $logical_name $"path must remain under ($location); existing links cannot escape it"
    }

    $candidate
}

def list-contained-resource-files-under [
    base: string
    current_dir: string
    logical_prefix: string
    kind: string
    suffix: string
    scope: string
] {
    mut files = []
    let entries = try { ls $current_dir } catch { [] }

    for entry in $entries {
        let segment = ($entry.name | path basename)
        let logical_name = if $logical_prefix == "" {
            $segment
        } else {
            $"($logical_prefix)/($segment)"
        }

        if $entry.type == "dir" {
            let directory = (resolve-under-base $base $logical_name $kind --nested --scope=$scope --base-is-canonical)
            $files = ($files | append (
                list-contained-resource-files-under $base $directory $logical_name $kind $suffix $scope
            ))
        } else if ($segment | str ends-with $suffix) {
            let name = ($logical_name | str replace -r $"(($suffix | str replace "." "\\."))$" '')
            let file = (resolve-under-base $base $logical_name $kind --nested --scope=$scope --base-is-canonical)
            $files = ($files | append {path: $file, name: $name})
        }
    }

    $files
}

# Enumerate nested resource files without following directory links.
export def list-contained-resource-files [
    base: string
    kind: string
    --suffix: string = ".nuon"
    --scope: string = ""
] {
    list-contained-resource-files-under $base $base "" $kind $suffix $scope
}

# Keep validation failures visible without unwinding the top-level TUI loop.
export def run-tui-resource-action [action: closure] {
    try {
        do $action
    } catch {|error|
        print $"(ansi red)($error.msg)(ansi reset)"
    }
}
