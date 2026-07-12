# Shared error contract for public command failures.

export def fail-command [message: string] {
    error make {msg: $message}
}
