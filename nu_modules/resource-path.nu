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
    let has_ambiguous_segment = ($segments | any {|segment|
        ($segment | str ends-with ".") or ($segment | str ends-with " ")
    })

    if $nested {
        let invalid_segment = ($segments | any {|segment|
            $segment == "" or ($segment =~ '^\.+$')
        })

        if $rooted or $invalid_segment or $has_ambiguous_segment {
            let location = if $scope == "" { "its resource directory" } else { $scope }
            invalid-resource-name $kind $name $"path must remain under ($location) and cannot contain empty, dot-only, or trailing-dot/space segments"
        }
    } else {
        if $rooted or $name == "" or ($name =~ '^\.+$') or ($segments | length) != 1 or $has_ambiguous_segment {
            invalid-resource-name $kind $name "expected one non-empty relative path segment without '/', '\\', or a trailing dot or space"
        }
    }

    $segments
}

def resolve-existing-component [
    path: string
    path_type: string
    kind: string
    logical_name: string
    location: string
] {
    let resolved = ($path | path expand)

    if $path_type == "symlink" and (($resolved | path type) == "symlink") {
        invalid-resource-name $kind $logical_name $"path must remain under ($location); unresolved or dangling links are not allowed"
    }

    $resolved
}

def canonicalize-base [
    base: string
    kind: string
    logical_name: string
    location: string
] {
    mut probe = ($base | path expand --no-symlink)
    mut probe_type = ($probe | path type)
    mut missing = []

    loop {
        if not ($probe_type | is-empty) {
            break
        }

        let parent = ($probe | path dirname)
        if $parent == $probe {
            break
        }

        $missing = ($missing | append ($probe | path basename))
        $probe = $parent
        $probe_type = ($probe | path type)
    }

    mut resolved = (resolve-existing-component $probe $probe_type $kind $logical_name $location)
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

    let location = if $scope == "" { $base } else { $scope }
    let canonical_base = if $base_is_canonical {
        $base
    } else {
        canonicalize-base $base $kind $logical_name $location
    }
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
            let candidate_type = ($candidate | path type)
            if not ($candidate_type | is-empty) {
                $candidate = (resolve-existing-component $candidate $candidate_type $kind $logical_name $location)
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
