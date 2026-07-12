#!/usr/bin/env nu
# discover-commands.nu — detect Nurl `api` command coverage gaps
#
# Parses every `export def "api ..."` in <root>/nu_modules/*.nu (the authoritative
# command surface) and diffs it against the sibling coverage.nuon manifest.
#
# Reports:
#   * uncovered : defined in code but missing from the manifest  -> ADD an entry
#   * stale     : in the manifest but no longer defined in code   -> REMOVE/RENAME
#   * source duplicates: a command is exported more than once       -> KEEP one export
#   * duplicates: a command appears more than once in the manifest  -> KEEP one entry
#   * help-drift (with --check-help): a command shown in `api help`
#                text that is not actually defined                -> fix the help/code
#
# Exit code is non-zero when any coverage, duplicate, or help gap exists.
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
    | sort-by name
}

# Extract curated command-list rows from `api help`, keeping examples separate.
# Static parse — does not source api.nu, so it has no side effects.
def parse-help-row [line: string] {
    let parsed = ($line | parse --regex '^\s*(?:[-*]\s+)?(?<syntax>api(?:\s+\S+)+?)\s{2,}(?<description>[A-Z#].*)$')
    if ($parsed | is-empty) {
        return []
    }
    let row = ($parsed | first)
    let syntax = ($row.syntax | str trim | str replace --all --regex '\s+' ' ')
    let description = ($row.description | str trim)
    let example = (
        ($description | str starts-with "#")
        or ($syntax =~ '(?:^|\s)[A-Z][A-Za-z0-9_-]*(?:\s|$)')
    )
    if $example {
        [{kind: example, syntax: $syntax}]
    } else {
        let command = (
            $syntax
            | parse --regex '^(?<command>api(?:\s+[a-z][a-z0-9-]*)+)'
            | get command
            | first
            | str replace --all --regex '\s+' ' '
        )
        [{kind: command, syntax: $syntax, command: $command}]
    }
}

def parse-help-example [line: string] {
    let row = (parse-help-row $line)
    if not ($row | is-empty) {
        return ($row | each {|item| {kind: example, syntax: $item.syntax} })
    }
    let parsed = ($line | parse --regex '^\s*(?:[-*]\s+)?(?<syntax>api(?:\s+\S+)+)\s*$')
    if ($parsed | is-empty) {
        []
    } else {
        [{
            kind: example
            syntax: ($parsed | first | get syntax | str trim | str replace --all --regex '\s+' ' ')
        }]
    }
}

def parse-help-refs [root: string] {
    let modfile = ($root | path join "nu_modules" "mod.nu")
    if not ($modfile | path exists) { return {commands: [], examples: []} }
    let command_sections = [
        "Setup"
        "Global Variables"
        "Collection Environments"
        "Authentication — stored credentials"
        "Requests"
        "Saved Requests"
        "History"
        "Collections"
        "Chaining"
        "Response Helpers \\(pass a --raw result record\\)"
        "TUI"
    ]
    let rows = (
        open --raw $modfile
        | lines
        | reduce -f {in_help: false, in_fence: false, section: "", rows: []} {|line, state|
            let trimmed = ($line | str trim)
            if not $state.in_help {
                if $line =~ '^\s*export def\s+"api help"' {
                    $state | update in_help true
                } else {
                    $state
                }
            } else if $trimmed == "}" and (not $state.in_fence) {
                $state | update in_help false
            } else if ($trimmed | str starts-with "```") {
                $state | update in_fence (not $state.in_fence)
            } else if $state.in_fence {
                $state
            } else {
                let heading = ($line | parse --regex '^\s*\(ansi yellow\)(?<section>[^:]+):\(ansi reset\)')
                if not ($heading | is-empty) {
                    $state | update section ($heading | first | get section | str trim)
                } else if $state.section in $command_sections {
                    $state | update rows ($state.rows | append (parse-help-row $line))
                } else {
                    $state | update rows ($state.rows | append (parse-help-example $line))
                }
            }
        }
        | get rows
    )
    {
        commands: ($rows | where kind == command | get command? | default [] | uniq | sort)
        examples: ($rows | where kind == example | get syntax? | default [] | uniq | sort)
    }
}

def main [
    --root: string = ""   # repo root; defaults to 4 levels up from this script
    --manifest: string = "" # coverage manifest; defaults to the skill's coverage.nuon
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
    let manifest_path = (if ($manifest | is-empty) {
        $here | path dirname | path join "coverage.nuon"
    } else {
        $manifest
    })

    if not ($manifest_path | path exists) {
        error make { msg: $"coverage manifest not found: ($manifest_path)" }
    }
    if not (($repo_root | path join "nu_modules") | path exists) {
        error make { msg: $"nu_modules not found under repo root: ($repo_root). Pass --root <repo>." }
    }

    let defined_exports = (parse-defined $repo_root)
    let source_duplicates = (
        $defined_exports
        | group-by name
        | transpose command entries
        | where {|row| ($row.entries | length) > 1 }
        | each {|row| {
            command: $row.command
            files: ($row.entries | get file | uniq | sort)
            count: ($row.entries | length)
        }}
    )
    let defined = ($defined_exports | uniq-by name)
    let defined_names = ($defined | get name)
    let manifest = (open $manifest_path)
    let covered = ($manifest | get command)
    let duplicates = (
        $manifest
        | group-by command
        | transpose command entries
        | where {|row| ($row.entries | length) > 1 }
        | get command
    )

    let uncovered = ($defined | where {|d| $d.name not-in $covered })
    let stale = ($covered | where {|c| $c not-in $defined_names })
    let help_refs = (if $check_help { parse-help-refs $repo_root } else { {commands: [], examples: []} })
    let help_drift = (if $check_help {
        $help_refs.commands | where {|command| $command not-in $defined_names }
    } else { [] })

    let gap_count = (($uncovered | length) + ($stale | length) + ($source_duplicates | length) + ($duplicates | length) + ($help_drift | length))

    if $json {
        let payload = {
            repo_root: $repo_root
            manifest: $manifest_path
            defined_count: ($defined | length)
            defined_export_count: ($defined_exports | length)
            covered_count: ($covered | length)
            uncovered: ($uncovered | each {|u| { command: $u.name, file: $u.file }})
            stale: $stale
            source_duplicates: $source_duplicates
            duplicates: $duplicates
            help_commands: $help_refs.commands
            help_examples: $help_refs.examples
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
    print $"  exports   : ($defined_exports | length) command exports before deduplication"
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

    print ""
    if ($source_duplicates | is-empty) {
        print $"(ansi green)OK(ansi reset)  no duplicate command exports in source"
    } else {
        print $"(ansi red_bold)SOURCE DUPLICATES \(($source_duplicates | length)\)(ansi reset)  repeated export names:"
        print ($source_duplicates | table)
        print $"  -> keep one source export per public command name"
    }

    print ""
    if ($duplicates | is-empty) {
        print $"(ansi green)OK(ansi reset)  no duplicate manifest entries"
    } else {
        print $"(ansi red_bold)DUPLICATES \(($duplicates | length)\)(ansi reset)  repeated in coverage.nuon:"
        $duplicates | each {|command| print $"    - ($command)" }
        print $"  -> keep one manifest entry per exported command"
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
