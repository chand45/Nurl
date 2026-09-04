# Protocol text helpers compatible with supported Nushell runtimes.

export def ascii-upcase []: string -> string {
    $in
    | str replace --all "a" "A"
    | str replace --all "b" "B"
    | str replace --all "c" "C"
    | str replace --all "d" "D"
    | str replace --all "e" "E"
    | str replace --all "f" "F"
    | str replace --all "g" "G"
    | str replace --all "h" "H"
    | str replace --all "i" "I"
    | str replace --all "j" "J"
    | str replace --all "k" "K"
    | str replace --all "l" "L"
    | str replace --all "m" "M"
    | str replace --all "n" "N"
    | str replace --all "o" "O"
    | str replace --all "p" "P"
    | str replace --all "q" "Q"
    | str replace --all "r" "R"
    | str replace --all "s" "S"
    | str replace --all "t" "T"
    | str replace --all "u" "U"
    | str replace --all "v" "V"
    | str replace --all "w" "W"
    | str replace --all "x" "X"
    | str replace --all "y" "Y"
    | str replace --all "z" "Z"
}

export def ascii-equal-ignore-case [left: string, right: string]: nothing -> bool {
    ($left | ascii-upcase) == ($right | ascii-upcase)
}

export def optional-get [key: any] {
    let value = $in
    let shape = ($value | describe)
    let is_list = (($shape | str starts-with "list") or ($shape | str starts-with "table"))
    if $is_list and (($key | describe) == "string") {
        $value | each --keep-empty {|row| try { $row | get $key } catch { null } }
    } else {
        try { $value | get $key } catch { null }
    }
}

# Encode one application/x-www-form-urlencoded component as UTF-8 bytes.
export def form-encode-component [value: string] {
    $value
    | url encode --all
    | str replace --all "%20" "+"
    | str replace --all "%2A" "*"
    | str replace --all "%2D" "-"
    | str replace --all "%2E" "."
    | str replace --all "%5F" "_"
}

export def form-encode-record [data: record] {
    $data | transpose key value | each {|field|
        let key = (form-encode-component $field.key)
        let raw_value = ($field.value | default "" | into string)
        let value = (form-encode-component $raw_value)
        $"($key)=($value)"
    } | str join "&"
}
