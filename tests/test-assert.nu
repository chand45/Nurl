export def assert [condition: bool, message?: string] {
    if not $condition {
        error make {msg: ($message | default "Assertion failed")}
    }
}

export def "assert equal" [actual: any, expected: any, message?: string] {
    if $actual != $expected {
        let detail = $"Expected ($expected | to nuon), got ($actual | to nuon)"
        error make {msg: ($message | default $detail)}
    }
}

export def "assert not" [condition: bool, message?: string] {
    if $condition {
        error make {msg: ($message | default "Expected condition to be false")}
    }
}
