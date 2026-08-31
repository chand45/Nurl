# Regressions for public output, body-file, history-export, collection-show, and pretty contracts.

def surface-server [infra: string] {
    let started = try {
        {server: (start-command-error-server $infra), error: null}
    } catch {|error|
        {server: null, error: $error}
    }
    if $started.error != null {
        cleanup $infra
        error make {msg: $started.error.msg}
    }
    $started.server
}

def surface-error [result: record, expected: string, label: string] {
    assert ($result.exit_code != 0) $"($label) unexpectedly exited 0"
    assert equal ($result.stdout | str trim) "" $"($label) wrote stdout"
    assert ($result.stderr | str contains $expected) $"($label) stderr was not actionable"
    assert equal $result.stderr ($result.stderr | ansi strip) $"($label) stderr contained ANSI"
    assert (not ($result.stderr | str contains "curl ")) $"($label) emitted a curl command"
}

def --env surface-workspace [root: string, server: record] {
    $env.API_ROOT = $root
    api init | ignore
    api collection create contracts | ignore
    api request create existing GET $"http://127.0.0.1:($server.port)/json-object" --collection contracts | ignore
}

def test-output-mode-preflight [] {
    let root = (make-temp-dir "output-preflight")
    let infra = (make-temp-dir "output-preflight-server")
    let server = (surface-server $infra)
    let failure = try {
        surface-workspace $root $server
        api auth oauth2 configure output-oauth --client-id client --client-secret secret --token-url $"http://127.0.0.1:($server.port)/token" | ignore
        api request create oauth-saved GET $"http://127.0.0.1:($server.port)/should-not-run" --collection contracts --auth {type: oauth2, ref: output-oauth} | ignore

        let missing_body = ($root | path join "missing-body.json")
        let save_path = ($root | path join "must-not-save.json")
        let binary_path = ($root | path join "must-not-download.bin")
        let url = $"http://127.0.0.1:($server.port)/should-not-run"
        let before = (command-error-snapshot $root)
        let cases = [
            {label: "get", command: $"api get ($url | to nuon) --output unsupported"}
            {label: "post", command: $"api post ($url | to nuon) --output ''"}
            {label: "put", command: $"api put ($url | to nuon) --output Pretty"}
            {label: "patch", command: $"api patch ($url | to nuon) --output UNSUPPORTED"}
            {label: "delete", command: $"api delete ($url | to nuon) --output unsupported"}
            {label: "generic combined flags", command: $"api request -m POST ($url | to nuon) --output unsupported --raw --select status --dry-run --body-file ($missing_body | to nuon) --auth {type: oauth2, ref: output-oauth} --save ($save_path | to nuon) --binary-save ($binary_path | to nuon)"}
            {label: "saved reproduction", command: "api send existing --collection contracts --output unsupported --no-history"}
            {label: "saved auth", command: "api send oauth-saved --collection contracts --output JSON"}
            {label: "head", command: $"api head ($url | to nuon) --output unsupported"}
            {label: "options", command: $"api options ($url | to nuon) --output unsupported"}
        ]

        for case in $cases {
            let result = (run-command-process $root $case.command)
            surface-error $result "Unsupported output mode" $case.label
            assert equal (command-error-snapshot $root) $before $"($case.label) changed workspace state"
        }
        assert equal (command-error-wire-events $server | length) 0 "invalid output modes reached the protected endpoint"
        assert equal (open $server.count_file --raw | str trim) "0" "invalid output modes acquired an OAuth2 token"
        assert (not ($save_path | path exists)) "invalid output mode created --save output"
        assert (not ($binary_path | path exists)) "invalid output mode created --binary-save output"
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def test-supported-output-modes-and-raw-body [] {
    let root = (make-temp-dir "output-modes")
    let infra = (make-temp-dir "output-modes-server")
    let server = (surface-server $infra)
    let failure = try {
        surface-workspace $root $server
        let base = $"http://127.0.0.1:($server.port)"
        let supported = ["pretty" "raw" "body" "json" "headers" "status" "none"]

        for mode in $supported {
            let direct = (run-command-process $root $"api request -m GET (($base + '/direct-' + $mode) | to nuon) --output ($mode) --no-history")
            assert equal $direct.exit_code 0 $"direct --output ($mode) failed"
            assert equal ($direct.stderr | str trim) "" $"direct --output ($mode) wrote stderr"
            let saved = (run-command-process $root $"api send existing --collection contracts --output ($mode) --no-history")
            assert equal $saved.exit_code 0 $"saved --output ($mode) failed"
            assert equal ($saved.stderr | str trim) "" $"saved --output ($mode) wrote stderr"
            if $mode == "none" {
                assert equal ($direct.stdout | str trim) "" "--output none must keep stdout empty"
                assert equal ($saved.stdout | str trim) "" "saved --output none must keep stdout empty"
            } else if $mode == "json" {
                assert (not ($direct.stdout | str contains "_raw_body")) "direct JSON output exposed internal raw-body state"
                assert (not ($saved.stdout | str contains "_raw_body")) "saved JSON output exposed internal raw-body state"
            }
        }

        let surface_cases = [
            $"api get (($base + '/surface-get') | to nuon) --output status --no-history"
            $"api post (($base + '/surface-post') | to nuon) --output status --no-history"
            $"api put (($base + '/surface-put') | to nuon) --output status --no-history"
            $"api patch (($base + '/surface-patch') | to nuon) --output status --no-history"
            $"api delete (($base + '/surface-delete') | to nuon) --output status --no-history"
            $"api request -m GET (($base + '/surface-request') | to nuon) --output status --no-history"
            "api send existing --collection contracts --output status --no-history"
            $"api head (($base + '/surface-head') | to nuon) --output status --no-history"
            $"api options (($base + '/surface-options') | to nuon) --output status --no-history"
        ]
        for command in $surface_cases {
            let result = (run-command-process $root $command)
            assert equal $result.exit_code 0 $"supported output surface failed: ($command)"
            assert equal ($result.stdout | str trim) "200" $"supported output surface returned the wrong status: ($command)"
            assert equal ($result.stderr | str trim) "" $"supported output surface wrote stderr: ($command)"
        }

        let raw_object = (run-command-process $root $"api request -m GET (($base + '/json-object') | to nuon) --output raw")
        assert equal $raw_object.exit_code 0 $"raw object request failed: ($raw_object.stderr)"
        assert equal ($raw_object.stdout | str trim) '{"ok":true}' "--output raw must emit compact JSON object body only"
        assert equal $raw_object.stdout ($raw_object.stdout | ansi strip) "--output raw object contained ANSI"
        let persisted_history = (
            ls ($root | path join "history")
            | where type == dir
            | each {|directory|
                ls $directory.name
                | where name =~ '\.nuon$'
                | get name
                | each {|path| open $path --raw }
            }
            | flatten
            | str join "\n"
        )
        assert (not ($persisted_history | str contains "_raw_body")) "history persisted internal raw-body state"

        let raw_array = (run-command-process $root $"api request -m GET (($base + '/array') | to nuon) --output raw --no-history")
        assert equal $raw_array.exit_code 0 $"raw array request failed: ($raw_array.stderr)"
        assert equal ($raw_array.stdout | str trim) '[{"id":1}]' "--output raw must emit compact JSON array body only"
        assert equal $raw_array.stdout ($raw_array.stdout | ansi strip) "--output raw array contained ANSI"

        let raw_text = (run-command-process $root $"api request -m GET (($base + '/text') | to nuon) --output raw --no-history")
        assert equal $raw_text.exit_code 0 $"raw text request failed: ($raw_text.stderr)"
        assert equal ($raw_text.stdout | str trim) "plain-text-response" "--output raw changed plain text"
        assert equal $raw_text.stdout ($raw_text.stdout | ansi strip) "--output raw text contained ANSI"

        let raw_padded = (api request -m GET $"($base)/padded" --output raw --no-history)
        assert equal $raw_padded "  padded text  " "--output raw changed text whitespace"
        let raw_sentinel = (api request -m GET $"($base)/sentinel" --output raw --no-history)
        assert equal $raw_sentinel "prefix---RESPONSE_META---suffix" "--output raw confused body text with curl metadata"
        let raw_http_like = (api request -m GET $"($base)/http-like-text" --output raw --no-history)
        assert equal $raw_http_like "prefix\r\n\r\nHTTP/1.1 200 OK\r\n\r\nsuffix" "--output raw confused body text with response headers"
        let raw_json_string = (api request -m GET $"($base)/json-string" --output raw --no-history)
        assert equal $raw_json_string '"json-string-response"' "--output raw removed JSON string quotes"
        assert equal ($raw_json_string | describe) "string" "--output raw JSON string type changed"
        let null_save = ($root | path join "raw-null.json")
        let raw_json_null = (api request -m GET $"($base)/json-null" --output raw --save $null_save --no-history)
        assert equal $raw_json_null "null" "--output raw confused JSON null with an empty body"
        assert equal (open $null_save --raw) "null" "--output raw failed to save a JSON null body"

        let empty_save = ($root | path join "raw-empty.txt")
        let raw_empty_command = "let value = (api request -m GET " + (($base + "/empty") | to nuon) + " --output raw --save " + ($empty_save | to nuon) + " --no-history); " + '{type: ($value | describe), empty: ($value == null)} | to json --raw'
        let raw_empty = (run-command-process $root $raw_empty_command)
        assert equal $raw_empty.exit_code 0 $"raw empty request failed: ($raw_empty.stderr)"
        assert equal (($raw_empty.stdout | from json).type) "nothing" "empty raw body must return nothing"
        assert ($raw_empty.stdout | from json | get empty) "empty raw body must not render placeholder text"
        assert (not ($empty_save | path exists)) "empty raw body created a save file"

        let full_result_command = "let value = (api request -m GET " + (($base + "/raw-flag") | to nuon) + " --output raw --raw --no-history); " + '{type: ($value | describe), internal_raw: ("_raw_body" in ($value | columns))} | to json --raw'
        let full_result = (run-command-process $root $full_result_command)
        assert equal $full_result.exit_code 0 $"--raw precedence request failed: ($full_result.stderr)"
        let full_result_contract = ($full_result.stdout | from json)
        assert ($full_result_contract.type | str starts-with "record<") "--raw flag must take precedence and return the full result"
        assert equal $full_result_contract.internal_raw false "internal raw body leaked into the public result"

        let selected = (run-command-process $root $"api request -m GET (($base + '/selected') | to nuon) --output raw --select status --no-history")
        assert equal $selected.exit_code 0 $"--select precedence request failed: ($selected.stderr)"
        assert equal ($selected.stdout | str trim) "200" "--select must take precedence over --output raw"

        let save_path = ($root | path join "raw-save.json")
        let saved = (run-command-process $root $"api request -m GET (($base + '/save') | to nuon) --output raw --save ($save_path | to nuon) --no-history")
        assert equal $saved.exit_code 0 $"--output raw save request failed: ($saved.stderr)"
        assert equal ($saved.stdout | str trim) '{"ok":true}' "--output raw with --save changed stdout"
        assert equal ((open $save_path --raw | from json).ok) true "--save did not persist the response body"

        let binary_path = ($root | path join "raw-binary.bin")
        let binary = (run-command-process $root $"api get (($base + '/binary') | to nuon) --output raw --binary-save ($binary_path | to nuon) --no-history")
        assert equal $binary.exit_code 0 $"--output raw binary-save request failed: ($binary.stderr)"
        assert equal ($binary.stderr | str trim) "" "--output raw binary-save wrote stderr"
        assert equal $binary.stdout ($binary.stdout | ansi strip) "--output raw binary-save emitted ANSI"
        assert (($binary.stdout | str trim) | str contains "[binary saved to:") "--output raw binary-save must return only its safe body marker"
        assert equal ((open $binary_path --raw | from json).ok) true "--binary-save did not persist exact response bytes"

        let before_dry_run = (command-error-wire-events $server | length)
        let dry_run = (run-command-process $root $"api request -m GET (($base + '/dry-run') | to nuon) --output raw --dry-run --no-history")
        assert equal $dry_run.exit_code 0 "--output raw dry-run failed"
        assert (($dry_run.stdout | str trim) | str starts-with "curl ") "dry-run must take precedence and emit curl"
        assert equal (command-error-wire-events $server | length) $before_dry_run "dry-run reached the protected endpoint"

        let expected_requests = (($supported | length) * 2) + ($surface_cases | length) + 13
        assert equal (command-error-wire-events $server | length) $expected_requests "supported output tests did not execute every expected request"
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def assert-body-file-error [root: string, command: string, expected: string, label: string] {
    let before = (command-error-snapshot $root)
    let result = (run-command-process $root $command)
    surface-error $result $expected $label
    assert equal (command-error-snapshot $root) $before $"($label) partially mutated the workspace"
}

def test-body-file-contracts [] {
    let root = (make-temp-dir "body-files")
    let infra = (make-temp-dir "body-files-server")
    let server = (surface-server $infra)
    let failure = try {
        surface-workspace $root $server
        let base = $"http://127.0.0.1:($server.port)"
        let missing = ($root | path join "definitely-missing-body.json")
        let directory = ($root | path join "body-directory")
        mkdir $directory
        let request_file = ($root | path join "collections" "contracts" "requests" "existing.nuon")
        let request_before = (open $request_file --raw)

        let cases = [
            {label: "post missing file", command: $"api post (($base + '/missing-post') | to nuon) --body-file ($missing | to nuon) --raw --no-history", expected: "not found"}
            {label: "generic directory body", command: $"api request -m POST (($base + '/directory-request') | to nuon) --body-file ($directory | to nuon) --raw --no-history", expected: "must be a readable file"}
            {label: "post form with missing file", command: $"api post (($base + '/missing-post-form') | to nuon) --form {x: y} --body-file ($missing | to nuon) --raw --no-history", expected: "not found"}
            {label: "put form with missing file", command: $"api put (($base + '/missing-put-form') | to nuon) --form {x: y} --body-file ($missing | to nuon) --raw --no-history", expected: "not found"}
            {label: "patch form with missing file", command: $"api patch (($base + '/missing-patch-form') | to nuon) --form {x: y} --body-file ($missing | to nuon) --raw --no-history", expected: "not found"}
            {label: "generic form with missing file", command: $"api request -m POST (($base + '/missing-request-form') | to nuon) --form {x: y} --body-file ($missing | to nuon) --raw --no-history", expected: "not found"}
            {label: "saved override missing", command: $"api send existing --collection contracts --body-file ($missing | to nuon) --raw --no-history", expected: "not found"}
            {label: "create missing file", command: $"api request create new-request POST (($base + '/create') | to nuon) --collection new-collection --body-file ($missing | to nuon)", expected: "not found"}
            {label: "create directory body", command: $"api request create directory-request POST (($base + '/create-directory') | to nuon) --collection contracts --body-file ($directory | to nuon)", expected: "must be a readable file"}
            {label: "update missing file", command: $"api request update existing --collection contracts --method PATCH --body-file ($missing | to nuon)", expected: "not found"}
            {label: "update directory body", command: $"api request update existing --collection contracts --method PATCH --body-file ($directory | to nuon)", expected: "must be a readable file"}
        ]
        for case in $cases {
            assert-body-file-error $root $case.command $case.expected $case.label
        }
        assert (not (($root | path join "collections" "new-collection") | path exists)) "failed create auto-created its collection"
        assert equal (open $request_file --raw) $request_before "failed update changed the saved request"
        assert equal (command-error-wire-events $server | length) 0 "invalid body files reached the protected endpoint"

        let json_body = ($root | path join "valid body 世界.json")
        '{"title":"valid","count":2}' | save -f $json_body
        let text_body = ($root | path join "valid body.txt")
        "plain body" | save -f $text_body

        let valid_post = (run-command-process $root $"api post (($base + '/valid-post') | to nuon) --body-file ($json_body | to nuon) --raw --no-history")
        assert equal $valid_post.exit_code 0 "valid post body-file failed"
        let valid_generic = (run-command-process $root $"api request -m POST (($base + '/valid-request') | to nuon) --body-file ($text_body | to nuon) --raw --no-history")
        assert equal $valid_generic.exit_code 0 "valid generic body-file failed"
        let valid_form = (run-command-process $root $"api post (($base + '/valid-form') | to nuon) --form {x: y} --body-file ($json_body | to nuon) --raw --no-history")
        assert equal $valid_form.exit_code 0 "valid form with body-file preflight failed"

        api request create valid-file POST $"($base)/valid-create" --collection contracts --body-file $json_body | ignore
        assert equal (api request show valid-file --collection contracts).body.content.title "valid"
        api request update existing --collection contracts --body-file $text_body | ignore
        assert equal (api request show existing --collection contracts).body.content "plain body"
        mut expected_wire_requests = 3

        let linked_body = ($root | path join "linked body.json")
        let linked = if $nu.os-info.name == "windows" {
            let result = (^powershell -NoProfile -NonInteractive -Command 'New-Item -ItemType SymbolicLink -Path $args[0] -Target $args[1] | Out-Null' $linked_body $json_body | complete)
            $result.exit_code == 0
        } else {
            let result = (^ln -s $json_body $linked_body | complete)
            $result.exit_code == 0
        }
        if $linked {
            let linked_result = (run-command-process $root $"api post (($base + '/valid-linked-file') | to nuon) --body-file ($linked_body | to nuon) --raw --no-history")
            assert equal $linked_result.exit_code 0 "readable symlinked body-file failed"
            $expected_wire_requests = $expected_wire_requests + 1
        }
        assert equal (command-error-wire-events $server | length) $expected_wire_requests "valid body-file executions did not reach the endpoint"

        if $nu.os-info.name != "windows" {
            let unreadable = ($root | path join "unreadable-body.json")
            "{}" | save -f $unreadable
            ^chmod 000 $unreadable
            let unreadable_result = (run-command-process $root $"api post (($base + '/unreadable') | to nuon) --body-file ($unreadable | to nuon) --raw --no-history")
            ^chmod 600 $unreadable
            surface-error $unreadable_result "could not be read" "unreadable body file"
            assert equal (command-error-wire-events $server | length) $expected_wire_requests "unreadable body file reached the endpoint"
        }
        null
    } catch {|error| $error }

    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def test-history-export-format-contract [] {
    let root = (make-temp-dir "history-format")
    let output_dir = (make-temp-dir "history-format-output")
    $env.API_ROOT = $root
    api init | ignore
    let ids = 1..10 | each {|n|
        api history save {
            method: "GET"
            url: $"https://example.invalid/history/($n)"
            headers: {}
            body: null
        } {
            status: 200
            status_text: "OK"
            headers: {}
            body: {sequence: $n}
            time_ms: 1
            size_bytes: 11
        }
    }
    let expected_ids = ($ids | reverse)

    let failure = try {
        let history_before = (command-error-snapshot ($root | path join "history"))
        let cases = [
            {format: "unsupported", output: ($output_dir | path join "unsupported.json")}
            {format: "JSON", output: ($output_dir | path join "uppercase.json")}
            {format: "", output: ($output_dir | path join "empty.json")}
        ]
        for case in $cases {
            let command = $"api history export --format ($case.format | to nuon) --output ($case.output | to nuon)"
            let result = (run-command-process $root $command)
            surface-error $result "Unsupported history export format" $"history format '($case.format)'"
            assert (not ($case.output | path exists)) "invalid history format created an output file"
            assert equal (command-error-snapshot ($root | path join "history")) $history_before "invalid history format changed history"
        }

        let unsupported_stdout = (run-command-process $root "api history export --format unsupported")
        surface-error $unsupported_stdout "Unsupported history export format" "history unsupported stdout"

        let limit_cases = [
            {name: "zero", limit: 0, expected: 0}
            {name: "one", limit: 1, expected: 1}
            {name: "exact", limit: 10, expected: 10}
            {name: "overlarge", limit: 1000, expected: 10}
        ]
        let csv_columns = [id timestamp method url status time_ms]

        for format in ["json" "csv"] {
            for case in $limit_cases {
                let stdout_result = (run-command-process $root $"api history export --format ($format) --limit ($case.limit)")
                assert equal $stdout_result.exit_code 0 $"($format) stdout export with ($case.name) limit failed"
                assert equal ($stdout_result.stderr | str trim) "" $"($format) stdout export with ($case.name) limit wrote stderr"
                assert equal $stdout_result.stdout ($stdout_result.stdout | ansi strip) $"($format) stdout export contained ANSI"
                let stdout_rows = if $format == "json" {
                    $stdout_result.stdout | from json
                } else {
                    assert equal ($stdout_result.stdout | lines | first) "id,timestamp,method,url,status,time_ms" "CSV header changed"
                    $stdout_result.stdout | from csv
                }
                assert equal ($stdout_rows | length) $case.expected $"($format) stdout export selected the wrong count for ($case.name)"
                assert equal ($stdout_rows | each {|row| $row.id }) ($expected_ids | first $case.expected) $"($format) stdout export order changed for ($case.name)"
                if $format == "csv" and $case.expected > 0 {
                    assert equal ($stdout_rows | columns) $csv_columns "CSV fields changed"
                }
                if $case.expected > 0 {
                    if $format == "json" {
                        assert ($stdout_rows | all {|row| ($row | columns) == [id timestamp environment request response] }) "JSON full-entry schema changed"
                        assert ($stdout_rows | all {|row| ($row.request | columns) == [method url headers body] }) "JSON request schema changed"
                        assert ($stdout_rows | all {|row| ($row.response | columns) == [status status_text headers body time_ms size_bytes] }) "JSON response schema changed"
                        assert ($stdout_rows | all {|row| ($row.response.status | describe) == "int" }) "JSON status type changed"
                        assert ($stdout_rows | all {|row| ($row.response.time_ms | describe) == "int" }) "JSON time_ms type changed"
                    } else {
                        assert ($stdout_rows | all {|row| ($row.status | describe) == "int" }) "CSV status type changed"
                        assert ($stdout_rows | all {|row| ($row.time_ms | describe) == "int" }) "CSV time_ms type changed"
                    }
                }

                let extension = if $format == "json" { "json" } else { "csv" }
                let output_file = ($output_dir | path join $"($format)-($case.name).($extension)")
                let file_result = (run-command-process $root $"api history export --format ($format) --limit ($case.limit) --output ($output_file | to nuon)")
                assert equal $file_result.exit_code 0 $"($format) file export with ($case.name) limit failed"
                assert equal ($file_result.stderr | str trim) "" $"($format) file export with ($case.name) limit wrote stderr"
                assert equal (($file_result.stdout | ansi strip) | str trim) $"Exported ($case.expected) entries to ($output_file)" $"($format) file export confirmation changed"
                assert ($output_file | path exists) $"($format) file export did not create output"
                let output_raw = (open $output_file --raw)
                assert equal $output_raw ($output_raw | ansi strip) $"($format) export file contained ANSI"
                let file_rows = (open $output_file)
                assert equal ($file_rows | length) $case.expected $"($format) file export selected the wrong count for ($case.name)"
                assert equal ($file_rows | each {|row| $row.id }) ($expected_ids | first $case.expected) $"($format) file export order changed for ($case.name)"
                if $format == "csv" {
                    assert equal (open $output_file --raw | lines | first) "id,timestamp,method,url,status,time_ms" "CSV file header changed"
                    if $case.expected > 0 {
                        assert equal ($file_rows | columns) $csv_columns "CSV file fields changed"
                    }
                }
            }
        }
        assert equal (command-error-snapshot ($root | path join "history")) $history_before "valid history export mutated history"

        let index_path = ($root | path join "history" "index.nuon")
        rm $index_path
        assert (not ($index_path | path exists)) "history export rebuild test did not remove the index"
        api history rebuild-index | ignore
        assert equal (open $index_path | get id) $expected_ids "rebuilt history index order changed"
        let rebuilt_history = (command-error-snapshot ($root | path join "history"))
        for format in ["json" "csv"] {
            let stdout_result = (run-command-process $root $"api history export --format ($format) --limit 10")
            assert equal $stdout_result.exit_code 0 $"rebuilt ($format) stdout export failed"
            assert equal ($stdout_result.stderr | str trim) "" $"rebuilt ($format) stdout export wrote stderr"
            assert equal $stdout_result.stdout ($stdout_result.stdout | ansi strip) $"rebuilt ($format) stdout export contained ANSI"
            let stdout_rows = if $format == "json" {
                $stdout_result.stdout | from json
            } else {
                $stdout_result.stdout | from csv
            }
            assert equal ($stdout_rows | get id) $expected_ids $"rebuilt ($format) stdout export order changed"

            let output_file = ($output_dir | path join $"rebuilt.($format)")
            let file_result = (run-command-process $root $"api history export --format ($format) --limit 10 --output ($output_file | to nuon)")
            assert equal $file_result.exit_code 0 $"rebuilt ($format) file export failed"
            assert equal ($file_result.stderr | str trim) "" $"rebuilt ($format) file export wrote stderr"
            assert equal (($file_result.stdout | ansi strip) | str trim) $"Exported 10 entries to ($output_file)" $"rebuilt ($format) file export confirmation changed"
            assert equal (open $output_file | get id) $expected_ids $"rebuilt ($format) file export order changed"
        }
        assert equal (command-error-snapshot ($root | path join "history")) $rebuilt_history "post-rebuild exports mutated history"

        let sentinel = "INDEX-PATH-ESCAPE-SENTINEL"
        let outside_file = ($root | path join "outside-history.nuon")
        {value: $sentinel} | to nuon | save -f $outside_file
        let index_path = ($root | path join "history" "index.nuon")
        let unsafe_summary = {
            id: "outside-history"
            timestamp: "2999-01-01T00:00:00Z"
            method: "GET"
            url: "https://example.invalid/unsafe-index"
            status: 200
            time_ms: 1
            date_dir: ".."
        }
        open $index_path | append $unsafe_summary | to nuon | save -f $index_path
        let unsafe_index_before = (command-error-snapshot ($root | path join "history"))
        let guarded_file = ($output_dir | path join "guarded-index.json")
        let guarded_result = (run-command-process $root $"api history export --format json --output ($guarded_file | to nuon)")
        assert equal $guarded_result.exit_code 0 "history export rejected rather than skipped an unsafe index path"
        assert equal ($guarded_result.stderr | str trim) "" "unsafe index guard wrote stderr"
        let guarded_raw = (open $guarded_file --raw)
        assert (not ($guarded_raw | str contains $sentinel)) "history export read a path outside the history directory"
        assert equal (open $guarded_file | length) 10 "unsafe index path changed the exported history count"
        assert equal (command-error-snapshot ($root | path join "history")) $unsafe_index_before "unsafe index guard mutated history"
        null
    } catch {|error| $error }

    cleanup $root
    cleanup $output_dir
    if $failure != null { error make {msg: $failure.msg} }
}

def test-collection-show-schema [] {
    let root = (make-temp-dir "collection-show")
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        api collection create empty --description "empty collection" | ignore
        let empty = (api collection show empty)
        assert ($empty | describe | str starts-with "record") "empty collection details must be a record"
        assert equal $empty.metadata.name "empty"
        assert equal $empty.metadata.description "empty collection"
        assert equal $empty.active_environment null
        assert equal ($empty.requests | length) 0
        assert equal ($empty.environments | length) 0

        let collection = "team api.v1 世界"
        let secret = "COLLECTION-SHOW-SECRET-SENTINEL"
        api collection create $collection --description "populated collection" | ignore
        api collection env create $collection default | ignore
        api collection env create $collection "dev 世界" --activate | ignore
        api collection env set $collection token $secret --target "dev 世界" | ignore
        let long_url = "https://example.invalid/a/path/that/is/longer/than/fifty/characters/login"
        api request create "auth/login 世界" POST $long_url --collection $collection --auth {type: bearer, token: COLLECTION-SHOW-SECRET-SENTINEL} | ignore
        api request create status GET "https://example.invalid/status" --collection $collection | ignore

        let details = (api collection show $collection)
        assert equal ($details | columns) [metadata active_environment requests environments] "collection detail fields changed"
        assert equal $details.metadata.name $collection
        assert equal $details.metadata.description "populated collection"
        assert equal $details.active_environment "dev 世界"
        assert equal ($details.requests | length) 2
        assert ("auth/login 世界" in $details.requests.name)
        assert equal ($details.requests | where name == "auth/login 世界" | first | get method) "POST"
        assert equal ($details.requests | where name == "auth/login 世界" | first | get url) $long_url
        assert equal ($details.environments | length) 2
        assert equal ($details.environments | where name == "dev 世界" | first | get active) true
        assert equal ($details.environments | where name == "dev 世界" | first | get variables) 1
        assert equal ($details.environments | where name == "default" | first | get active) false
        assert (not (($details | to nuon) | str contains $secret)) "collection details exposed an environment or request secret"

        let rendered = (run-command-process $root $"api collection show ($collection | to nuon)")
        assert equal $rendered.exit_code 0 "collection details human rendering failed"
        assert equal ($rendered.stderr | str trim) "" "collection details human rendering wrote stderr"
        for field in ["metadata" "active_environment" "requests" "environments" "auth/login 世界" "dev 世界"] {
            assert ($rendered.stdout | str contains $field) $"collection details rendering omitted ($field)"
        }
        assert (not ($rendered.stdout | str contains $secret)) "collection details human rendering exposed a secret"
        null
    } catch {|error| $error }

    cleanup $root
    if $failure != null { error make {msg: $failure.msg} }
}

def test-history-read-stream-contracts [] {
    let root = (make-temp-dir "history-read-streams")
    $env.API_ROOT = $root
    api init | ignore
    let id = (api history save {
        method: "POST"
        url: "https://example.invalid/history-stream"
        headers: {X-Test: "safe"}
        body: {input: 1}
    } {
        status: 201
        status_text: "Created"
        headers: {Content-Type: "application/json"}
        body: {output: 2}
        time_ms: 9
        size_bytes: 12
    })

    let human = (run-command-process $root "api history list --limit 1")
    assert equal $human.exit_code 0 "human history list failed"
    assert equal ($human.stderr | str trim) "" "human history list wrote stderr"
    assert equal $human.stdout ($human.stdout | ansi strip) "human history list contained ANSI"
    for heading in ["id" "timestamp" "method" "status" "url"] {
        assert ($human.stdout | str contains $heading) $"human history list omitted the ($heading) column"
    }
    assert ($human.stdout | str contains ($id | str substring 0..10)) "human history list omitted the saved ID prefix"
    assert ($human.stdout =~ '\d{2}:\d{2}:\d{2}') "human history list omitted the HH:MM:SS timestamp"

    let machine_command = (
        "let listed = (api history list --limit 1); "
        + "let searched = (api history search history-stream --limit 1); "
        + "let shown = (api history show " + ($id | to nuon) + "); "
        + "let fetched = (api history get " + ($id | to nuon) + "); "
        + '{list: $listed, search: $searched, show: $shown, get: $fetched} | to json --raw'
    )
    let machine = (run-command-process $root $machine_command)
    assert equal $machine.exit_code 0 "typed history read subprocess failed"
    assert equal ($machine.stderr | str trim) "" "typed history read subprocess wrote stderr"
    assert equal $machine.stdout ($machine.stdout | ansi strip) "typed history read output contained ANSI"
    let parsed = ($machine.stdout | from json)
    assert equal ($parsed.list | columns) [id timestamp method status url time_ms] "typed list schema changed"
    assert equal ($parsed.search | columns) [id timestamp method status url] "typed search schema changed"
    assert equal ($parsed.list | first | get id) $id
    assert equal ($parsed.search | first | get id) $id
    assert (($parsed.list | first | get timestamp) =~ '^\d{2}:\d{2}:\d{2}$') "typed list timestamp must remain HH:MM:SS"
    assert (($parsed.search | first | get timestamp) =~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') "typed search timestamp shape changed"
    assert equal ($parsed.list | first | get method | describe) "string"
    assert equal ($parsed.list | first | get status | describe) "int"
    assert equal ($parsed.list | first | get url | describe) "string"
    assert equal ($parsed.list | first | get time_ms | describe) "int"
    assert equal $parsed.show $parsed.get "typed show/get records diverged"
    assert equal ($parsed.show | columns) [id timestamp environment request response] "typed show/get schema changed"
    assert equal ($parsed.show.request | columns) [method url headers body] "typed request schema changed"
    assert equal ($parsed.show.response | columns) [status status_text headers body time_ms size_bytes] "typed response schema changed"
    assert equal ($parsed.show.response.status | describe) "int"
    assert equal ($parsed.show.response.time_ms | describe) "int"
    cleanup $root
}

def pretty-result [body: any] {
    {
        request: {method: "GET", url: "https://example.invalid", headers: {}, body: null}
        response: {status: 200, status_text: "OK", headers: {}, body: $body, time_ms: 1, size_bytes: 1}
        timestamp: "2026-01-01T00:00:00Z"
    }
}

def test-pretty-table-contract [] {
    let table_body = [[id name]; [1 alpha]]
    let table_pretty = (api pretty (pretty-result $table_body))
    assert equal ($table_pretty | describe) "string" "api pretty table output must be a JSON string"
    assert ($table_pretty | str contains "\n") "api pretty table output must be indented"
    assert equal ($table_pretty | from json | first | get id) 1
    assert equal $table_pretty ($table_pretty | ansi strip) "api pretty table output contained ANSI"

    let empty_table = ($table_body | where id == 2)
    assert equal (api pretty (pretty-result $empty_table)) "[]" "api pretty empty table must be a JSON array"
    assert equal (api pretty (pretty-result [1 2 3]) | from json) [1 2 3]

    let nested = {outer: [{id: 1, tags: ["a" "b"]}]}
    assert equal (api pretty (pretty-result $nested) | from json) $nested
    let record_body = {id: 1, name: "alpha"}
    assert equal (api pretty (pretty-result $record_body) | from json) $record_body

    let json_string = '{"id":1}'
    assert equal (api pretty (pretty-result $json_string)) $json_string "api pretty must preserve JSON strings"
    assert equal (api pretty (pretty-result "plain text")) "plain text" "api pretty must preserve non-JSON strings"
    assert equal (api pretty (pretty-result null)) "(no body)" "api pretty null body contract changed"

    let piped_id = (api pretty (pretty-result $table_body) | from json | first | get id)
    assert equal $piped_id 1 "api pretty table output is not pipeline-compatible JSON"

    let root = (make-temp-dir "pretty-real")
    let infra = (make-temp-dir "pretty-real-server")
    let server = (surface-server $infra)
    let failure = try {
        $env.API_ROOT = $root
        api init | ignore
        let raw = (api request -m GET $"http://127.0.0.1:($server.port)/array" --raw --no-history)
        assert ($raw.response.body | describe | str starts-with "table") "local JSON array did not produce a table body"
        let pretty = (api pretty $raw)
        assert equal ($pretty | from json | first | get id) 1 "api pretty failed on a real raw HTTP table body"
        assert equal $pretty ($pretty | ansi strip) "real api pretty output contained ANSI"
        null
    } catch {|error| $error }
    let stop_failure = try { stop-command-error-server $server; null } catch {|error| $error }
    cleanup $root
    cleanup $infra
    if $failure != null { error make {msg: $failure.msg} }
    if $stop_failure != null { error make {msg: $stop_failure.msg} }
}

def test-runner-skip-summary-contract [] {
    let passed = {name: "pass", status: "pass", error: ""}
    let failed = {name: "fail", status: "fail", error: "expected failure"}
    let network_skip = {name: "network", status: "skip", error: "network unavailable"}
    let capability_skip = {name: "capability", status: "skip", error: "node unavailable"}
    let duplicate_capability_skip = {name: "capability duplicate", status: "skip", error: "node unavailable"}
    let platform_skip = {name: "platform", status: "skip", error: "POSIX permission fixture"}
    let blank_skip = {name: "blank", status: "skip", error: "  "}
    let null_skip = {name: "null", status: "skip", error: null}
    let missing_skip = {name: "missing", status: "skip"}

    let zero = (summarize-test-results [$passed])
    assert equal $zero.total 1
    assert equal $zero.passed 1
    assert equal $zero.failed 0
    assert equal $zero.skipped 0
    assert equal $zero.skip_reasons []
    assert equal $zero.skip_note "" "zero-skip success note changed"

    let capability = (summarize-test-results [$passed $capability_skip $duplicate_capability_skip])
    assert equal $capability.skipped 2
    assert equal $capability.skip_reasons [{reason: "node unavailable", count: 2}]
    assert equal $capability.skip_note "2 skipped"
    assert (not ($capability.skip_note | str contains "network")) "capability skip was mislabeled as network-related"

    let offline = (summarize-test-results [$passed $network_skip])
    assert equal $offline.skip_reasons [{reason: "network unavailable", count: 1}]
    assert equal $offline.skip_note "1 skipped"

    let mixed = (
        summarize-test-results [
            $passed
            $failed
            $network_skip
            $capability_skip
            $duplicate_capability_skip
            $platform_skip
            $blank_skip
            $null_skip
            $missing_skip
        ]
    )
    assert equal $mixed.total 9
    assert equal $mixed.passed 1
    assert equal $mixed.failed 1 "failure accounting changed"
    assert equal $mixed.skipped 7
    assert equal $mixed.skip_reasons [
        {reason: "POSIX permission fixture", count: 1}
        {reason: "network unavailable", count: 1}
        {reason: "node unavailable", count: 2}
        {reason: "unspecified", count: 3}
    ] "mixed skip reasons were not grouped and sorted deterministically"
    assert equal $mixed.skip_note "7 skipped"
}

def run-suite-surface-contracts []: nothing -> list<record> {
    print $"\n(ansi yellow)── Public command surface contracts ──(ansi reset)"
    [
        (run-test "output modes validate before side effects on every HTTP surface" { test-output-mode-preflight })
        (run-test "supported output modes and raw-body precedence stay deterministic" { test-supported-output-modes-and-raw-body })
        (run-test "explicit body-file failures are nonzero and mutation-free" { test-body-file-contracts })
        (run-test "history export formats validate before output or mutation" { test-history-export-format-contract })
        (run-test "human and typed history readers preserve streams and schemas" { test-history-read-stream-contracts })
        (run-test "collection show returns metadata, requests, and environments safely" { test-collection-show-schema })
        (run-test "api pretty serializes table and nested JSON bodies" { test-pretty-table-contract })
        (run-test "runner summaries group truthful skip causes deterministically" { test-runner-skip-summary-contract })
    ]
}
