# ASCII-only case helpers for protocol tokens.

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
