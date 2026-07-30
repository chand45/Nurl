# Terminal UI Module
# Interactive interface for browsing and managing API requests

use resource-path.nu [validate-resource-name resolve-under-base list-contained-resource-files run-tui-resource-action]
use string-compat.nu [ascii-upcase]
use state-store.nu [open-state-record]

def get-collections-dir [] {
    let root = ($env.API_ROOT? | default (pwd))
    resolve-under-base $root "collections" "collections directory" --scope "API workspace"
}

# Main TUI entry point
export def "api tui" [] {
    print $"
(ansi blue_bold)╔════════════════════════════════════════╗
║       API Client - Terminal UI         ║
╚════════════════════════════════════════╝(ansi reset)

(ansi yellow)Navigation:(ansi reset)
  [1] Collections  - Browse and execute saved requests
  [2] History      - View and resend past requests
  [3] Environments - Manage environments
  [4] Quick Request- Execute a quick request
  [5] Chains       - Run request chains
  [q] Quit

"

    loop {
        let choice = (input "(ansi green)>(ansi reset) " | str trim)

        match $choice {
            "1" | "c" | "collections" => { run-tui-resource-action { api tui collections } }
            "2" | "h" | "history" => { run-tui-resource-action { api tui history } }
            "3" | "e" | "environments" => { run-tui-resource-action { api tui environments } }
            "4" | "r" | "request" => { run-tui-resource-action { api tui request } }
            "5" | "chain" => { run-tui-resource-action { api tui chains } }
            "q" | "quit" | "exit" => {
                print "(ansi blue)Goodbye!(ansi reset)"
                break
            }
            "?" | "help" => {
                print "  1/c = Collections, 2/h = History, 3/e = Environments"
                print "  4/r = Quick Request, 5 = Chains, q = Quit"
            }
            "" => {}
            _ => { print $"Unknown command: ($choice). Type '?' for help." }
        }
    }
}

# Collections browser
export def "api tui collections" [] {
    let collections_dir = (get-collections-dir)

    print $"(ansi blue)═══ Collections ═══(ansi reset)"

    if not ($collections_dir | path exists) {
        print "(ansi yellow)No collections found(ansi reset)"
        print "Create one with: api collection create <name>"
        return
    }

    let collections = ls $collections_dir | where type == dir | get name | each {|d| $d | path basename }

    if ($collections | is-empty) {
        print "(ansi yellow)No collections found(ansi reset)"
        return
    }

    # List collections
    print ""
    mut idx = 0
    for coll in $collections {
        $idx = $idx + 1
        print $"  [($idx)] ($coll)"
    }
    print "  [b] Back"
    print ""

    let choice = (input "Select collection: " | str trim)

    if $choice == "b" or $choice == "" {
        return
    }

    let coll_idx = try { ($choice | into int) - 1 } catch { -1 }

    if $coll_idx >= 0 and $coll_idx < ($collections | length) {
        let selected = ($collections | get $coll_idx)
        api tui collection-requests $selected
    }
}

# Browse requests in a collection
def "api tui collection-requests" [collection: string] {
    validate-resource-name "collection" $collection | ignore
    let collections_dir = (get-collections-dir)
    let collection_dir = (resolve-under-base $collections_dir $collection "collection" --scope "API workspace collections" --base-is-canonical)
    let requests_dir = (resolve-under-base $collection_dir "requests" "request directory" --scope $"collection '($collection)'" --base-is-canonical)

    print $"(ansi blue)═══ ($collection) Requests ═══(ansi reset)"

    if not ($requests_dir | path exists) {
        print "(ansi yellow)No requests in this collection(ansi reset)"
        return
    }

    let requests = (
        list-contained-resource-files $requests_dir "request" --suffix ".nuon" --scope "<collection>/requests"
        | each {|request_file|
        let req = (open-state-record $request_file.path $"request '($request_file.name)' in collection '($collection)'")
        {
            file: $request_file.path
            lookup: ($request_file.path | path relative-to $requests_dir | str replace --all "\\" "/")
            name: ($req.name? | default $request_file.name)
            method: ($req.method? | default "GET")
            url: ($req.url? | default "")
        }
    })

    if ($requests | is-empty) {
        print "(ansi yellow)No requests found(ansi reset)"
        return
    }

    print ""
    mut idx = 0
    for req in $requests {
        $idx = $idx + 1
        let method_color = match $req.method {
            "GET" => "green"
            "POST" => "blue"
            "PUT" => "yellow"
            "DELETE" => "red"
            _ => "white"
        }
        print $"  [($idx)] (ansi $method_color)($req.method | fill -w 6)(ansi reset) ($req.name)"
    }
    print "  [b] Back"
    print ""

    let choice = (input "Select request to send: " | str trim)

    if $choice == "b" or $choice == "" {
        return
    }

    let req_idx = try { ($choice | into int) - 1 } catch { -1 }

    if $req_idx >= 0 and $req_idx < ($requests | length) {
        let selected = ($requests | get $req_idx)
        print ""
        print $"(ansi dark_gray)Sending: ($selected.method) ($selected.url)(ansi reset)"
        print ""

        run-tui-resource-action { api send $selected.lookup -c $collection }

        print ""
        input "Press Enter to continue..."
    }
}

# History browser
export def "api tui history" [] {
    print $"(ansi blue)═══ History ═══(ansi reset)"
    print ""

    let entries = (api history list -l 15)

    if ($entries | is-empty) or $entries == null {
        print "(ansi yellow)No history found(ansi reset)"
        return
    }

    print ""
    print "  [r <id>] Resend request"
    print "  [s <id>] Show details"
    print "  [b]      Back"
    print ""

    let choice = (input "Command: " | str trim)

    if $choice == "b" or $choice == "" {
        return
    }

    if ($choice | str starts-with "r ") {
        let id = ($choice | str replace "r " "")
        api history resend $id
        print ""
        input "Press Enter to continue..."
    } else if ($choice | str starts-with "s ") {
        let id = ($choice | str replace "s " "")
        api history show $id
        print ""
        input "Press Enter to continue..."
    }
}

# Environments manager — now collection-scoped (A2)
export def "api tui environments" [] {
    print $"(ansi blue)═══ Environments ═══(ansi reset)"
    print ""

    # First: pick a collection
    let collections_dir = (get-collections-dir)

    if not ($collections_dir | path exists) {
        print "(ansi yellow)No collections found. Create one with: api collection create <name>(ansi reset)"
        return
    }

    let collections = try { ls $collections_dir | where type == dir | get name | each {|d| $d | path basename } } catch { [] }

    if ($collections | is-empty) {
        print "(ansi yellow)No collections found(ansi reset)"
        return
    }

    print "Select a collection:"
    print ""
    mut idx = 0
    for coll in $collections {
        $idx = $idx + 1
        print $"  [($idx)] ($coll)"
    }
    print "  [b] Back"
    print ""

    let coll_choice = (input "Collection: " | str trim)

    if $coll_choice == "b" or $coll_choice == "" { return }

    let coll_idx = try { ($coll_choice | into int) - 1 } catch { -1 }

    if $coll_idx < 0 or $coll_idx >= ($collections | length) {
        print "(ansi red)Invalid selection(ansi reset)"
        return
    }

    let collection = ($collections | get $coll_idx)

    print ""
    print $"(ansi blue)═══ Environments for '($collection)' ═══(ansi reset)"
    print ""

    api collection env list $collection

    print ""
    print "  [u <name>] Use environment"
    print "  [s <name>] Show environment"
    print "  [c <name>] Create environment"
    print "  [b]        Back"
    print ""

    let choice = (input "Command: " | str trim)

    if $choice == "b" or $choice == "" { return }

    if ($choice | str starts-with "u ") {
        let name = ($choice | str replace "u " "")
        run-tui-resource-action { api collection env use $collection $name }
    } else if ($choice | str starts-with "s ") {
        let name = ($choice | str replace "s " "")
        run-tui-resource-action { api collection env show $collection $name }
        print ""
        input "Press Enter to continue..."
    } else if ($choice | str starts-with "c ") {
        let name = ($choice | str replace "c " "")
        run-tui-resource-action { api collection env create $collection $name }
    }
}

# Quick request builder
export def "api tui request" [] {
    print $"(ansi blue)═══ Quick Request ═══(ansi reset)"
    print ""

    let method = (input "Method [GET]: " | str trim | ascii-upcase)
    let method = if $method == "" { "GET" } else { $method }

    let url = (input "URL: " | str trim)
    if $url == "" {
        print "(ansi red)URL is required(ansi reset)"
        return
    }

    let body = if $method in ["POST" "PUT" "PATCH"] {
        input "Body (JSON, empty to skip): " | str trim
    } else {
        ""
    }

    print ""
    print $"(ansi dark_gray)Executing: ($method) ($url)(ansi reset)"
    print ""

    if $body != "" {
        api request -m $method $url -b $body
    } else {
        api request -m $method $url
    }

    print ""
    input "Press Enter to continue..."
}

# Chains browser
export def "api tui chains" [] {
    print $"(ansi blue)═══ Request Chains ═══(ansi reset)"
    print ""

    api chain list

    print ""
    print "  [r <name>] Run chain"
    print "  [s <name>] Show chain"
    print "  [c <name>] Create chain"
    print "  [b]        Back"
    print ""

    let choice = (input "Command: " | str trim)

    if $choice == "b" or $choice == "" {
        return
    }

    if ($choice | str starts-with "r ") {
        let name = ($choice | str replace "r " "")
        run-tui-resource-action { api chain exec $name }
        print ""
        input "Press Enter to continue..."
    } else if ($choice | str starts-with "s ") {
        let name = ($choice | str replace "s " "")
        run-tui-resource-action { api chain show $name }
        print ""
        input "Press Enter to continue..."
    } else if ($choice | str starts-with "c ") {
        let name = ($choice | str replace "c " "")
        run-tui-resource-action { api chain create $name }
    }
}

# Interactive response explorer
export def "api explore" [result: record] {
    $result.response | explore
}

# Pretty print JSON response
export def "api pretty" [result: record] {
    if ($result.response.body? | default null) != null {
        let body = $result.response.body
        if ($body | describe | str starts-with "record") or ($body | describe | str starts-with "list") or ($body | describe | str starts-with "table") {
            $body | to json --indent 2
        } else {
            $body
        }
    } else {
        "(no body)"
    }
}

# Compact response summary
export def "api summary" [result: record] {
    let r = $result.response

    print $"Status: ($r.status) ($r.status_text)"
    print $"Time: ($r.time_ms)ms | Size: ($r.size_bytes) bytes"
    print $"Headers: ($r.headers | columns | length)"

    if ($r.body? | default null) != null {
        let body_type = ($r.body | describe)
        if ($body_type | str starts-with "list") {
            print $"Body: array with ($r.body | length) items"
        } else if ($body_type | str starts-with "record") {
            print $"Body: object with ($r.body | transpose | length) keys"
        } else {
            print $"Body: ($body_type)"
        }
    }
}
