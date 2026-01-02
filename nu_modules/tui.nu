# Terminal UI Module
# Interactive interface for browsing and managing API requests

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
            "1" | "c" | "collections" => { api tui collections }
            "2" | "h" | "history" => { api tui history }
            "3" | "e" | "environments" => { api tui environments }
            "4" | "r" | "request" => { api tui request }
            "5" | "chain" => { api tui chains }
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
    let root = ($env.API_ROOT? | default (pwd))
    let collections_dir = ($root | path join "collections")

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
    let root = ($env.API_ROOT? | default (pwd))
    let requests_dir = ($root | path join "collections" $collection "requests")

    print $"(ansi blue)═══ ($collection) Requests ═══(ansi reset)"

    if not ($requests_dir | path exists) {
        print "(ansi yellow)No requests in this collection(ansi reset)"
        return
    }

    let request_files = try { ls $requests_dir | where name =~ '\.nuon$' | get name } catch { [] }
    let requests = $request_files | each {|f|
        let req = (open $f)
        {
            file: $f
            name: ($req.name? | default ($f | path basename | str replace ".nuon" ""))
            method: ($req.method? | default "GET")
            url: ($req.url? | default "")
        }
    }

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

        api send $selected.name -c $collection

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

# Environments manager
export def "api tui environments" [] {
    print $"(ansi blue)═══ Environments ═══(ansi reset)"
    print ""

    api env list

    print ""
    print "  [u <name>] Use environment"
    print "  [s <name>] Show environment"
    print "  [c <name>] Create environment"
    print "  [b]        Back"
    print ""

    let choice = (input "Command: " | str trim)

    if $choice == "b" or $choice == "" {
        return
    }

    if ($choice | str starts-with "u ") {
        let name = ($choice | str replace "u " "")
        api env use $name
    } else if ($choice | str starts-with "s ") {
        let name = ($choice | str replace "s " "")
        api env show $name
        print ""
        input "Press Enter to continue..."
    } else if ($choice | str starts-with "c ") {
        let name = ($choice | str replace "c " "")
        api env create $name
    }
}

# Quick request builder
export def "api tui request" [] {
    print $"(ansi blue)═══ Quick Request ═══(ansi reset)"
    print ""

    let method = (input "Method [GET]: " | str trim | str upcase)
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
        api chain exec $name
        print ""
        input "Press Enter to continue..."
    } else if ($choice | str starts-with "s ") {
        let name = ($choice | str replace "s " "")
        api chain show $name
        print ""
        input "Press Enter to continue..."
    } else if ($choice | str starts-with "c ") {
        let name = ($choice | str replace "c " "")
        api chain create $name
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
        if ($body | describe | str starts-with "record") or ($body | describe | str starts-with "list") {
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
    print $"Headers: ($r.headers | length)"

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
