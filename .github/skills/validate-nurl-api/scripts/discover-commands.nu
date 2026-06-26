#!/usr/bin/env nu
# discover-commands.nu — detect Nurl `api` command coverage gaps
#
# Parses every `export def "api ..."` in <root>/nu_modules/*.nu (the authoritative
# command surface) and diffs it against the sibling coverage.nuon manifest.
#
# Reports:
#   * uncovered : defined in code but missing from the manifest  -> ADD an entry
#   * stale     : in the manifest but no longer defined in code   -> REMOVE/RENAME
#   * help-drift (with --check-help): a command shown in `api help`
#                text that is not actually defined                -> fix the help/code
#
# Exit code is non-zero when uncovered or stale gaps exist, so this can gate CI.
#
# Usage (run with the full path to nu.exe if nu is not on PATH):
#   nu discover-commands.nu                      # auto-detect repo root
#   nu discover-commands.nu --check-help         # also cross-check api help text
#   nu discover-commands.nu --root C:\path\Nurl  # explicit repo root
#   nu discover-commands.nu --json               # machine-readable output

# Parse `export def "api ..."` names (with originating file) from every module.
def parse-defined [root: string] {
    let dir = ($root | path join "nu_modules")
    let modules = (ls $dir | where type == file | get name | where {|n| ($n | path parse | get extension) == "nu" })
    $modules
    | each {|f|
        open --raw $f
        | lines
        | each {|ln|
            let m = ($ln | parse --regex '^\s*export def\s+(?:--[a-z][a-z-]*\s+)*"(?<name>api[^"]*)"')
            if ($m | is-empty) { [] } else {
                $m | get name | each {|n| { name: $n, file: ($f | path basename) } }
            }
        }
        | flatten
    }
    | flatten
    | uniq-by name
    | sort-by name
}

# Extract `api ...` command phrases referenced in the `api help` text (mod.nu).
# Static parse — does not source api.nu, so it has no side effects.
def parse-help-refs [root: string] {
    let modfile = ($root | path join "nu_modules" "mod.nu")
    if not ($modfile | path exists) { return [] }
    open --raw $modfile
    | lines
    | each {|ln| $ln | parse --regex '^\s{2,}(?<cmd>api(?:\s+[a-z][a-z0-9-]*)+)' }
    | flatten
    | get cmd
    | each {|c| $c | str trim | str replace --all --regex '\s+' ' ' }
    | uniq
    | sort
}

def main [
    --root: string = ""   # repo root; defaults to 4 levels up from this script
    --check-help          # also cross-check `api help` text against defined commands
    --json                # emit machine-readable JSON instead of a report
] {
    let here = $env.FILE_PWD
    let repo_root = (if ($root | is-empty) {
        # here = <root>/.github/skills/validate-nurl-api/scripts
        $here | path dirname | path dirname | path dirname | path dirname
    } else {
        $root
    })
    let manifest_path = ($here | path dirname | path join "coverage.nuon")

    if not ($manifest_path | path exists) {
        error make { msg: $"coverage manifest not found: ($manifest_path)" }
    }
    if not (($repo_root | path join "nu_modules") | path exists) {
        error make { msg: $"nu_modules not found under repo root: ($repo_root). Pass --root <repo>." }
    }

    let defined = (parse-defined $repo_root)
    let defined_names = ($defined | get name)
    let manifest = (open $manifest_path)
    let covered = ($manifest | get command)

    let uncovered = ($defined | where {|d| $d.name not-in $covered })
    let stale = ($covered | where {|c| $c not-in $defined_names })
    let help_drift = (if $check_help {
        parse-help-refs $repo_root | where {|c| $c not-in $defined_names }
    } else { [] })

    let gap_count = (($uncovered | length) + ($stale | length))

    if $json {
        let payload = {
            repo_root: $repo_root
            manifest: $manifest_path
            defined_count: ($defined | length)
            covered_count: ($covered | length)
            uncovered: ($uncovered | each {|u| { command: $u.name, file: $u.file }})
            stale: $stale
            help_drift: $help_drift
            ok: ($gap_count == 0)
        }
        print ($payload | to json)
        exit (if ($gap_count == 0) { 0 } else { 1 })
    }

    print $"(ansi blue_bold)Nurl api command coverage(ansi reset)"
    print $"  repo root : ($repo_root)"
    print $"  manifest  : ($manifest_path)"
    print $"  defined   : ($defined | length) commands in code"
    print $"  covered   : ($covered | length) entries in manifest"
    print ""

    if ($uncovered | is-empty) {
        print $"(ansi green)OK(ansi reset)  no uncovered commands"
    } else {
        print $"(ansi red_bold)UNCOVERED \(($uncovered | length)\)(ansi reset)  defined in code, missing from coverage.nuon:"
        print ($uncovered | rename command file | table)
        print $"  -> add a record to coverage.nuon \(kind/group/test\) and a row in references/command-matrix.md"
    }
    print ""

    if ($stale | is-empty) {
        print $"(ansi green)OK(ansi reset)  no stale manifest entries"
    } else {
        print $"(ansi red_bold)STALE \(($stale | length)\)(ansi reset)  in coverage.nuon, not defined in code:"
        $stale | each {|s| print $"    - ($s)" }
        print $"  -> remove or rename these entries in coverage.nuon"
    }

    if $check_help {
        print ""
        if ($help_drift | is-empty) {
            print $"(ansi green)OK(ansi reset)  every `api help` command maps to a defined command"
        } else {
            print $"(ansi yellow_bold)HELP DRIFT \(($help_drift | length)\)(ansi reset)  shown in `api help` but not defined:"
            $help_drift | each {|h| print $"    - ($h)" }
        }
    }

    print ""
    if ($gap_count == 0) {
        print $"(ansi green_bold)PASS(ansi reset)  coverage manifest is in sync with the command surface"
        exit 0
    } else {
        print $"(ansi red_bold)FAIL(ansi reset)  ($gap_count) coverage gap\(s\) — see above"
        exit 1
    }
}
