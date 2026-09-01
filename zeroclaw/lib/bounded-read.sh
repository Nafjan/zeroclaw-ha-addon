#!/bin/bash
# Read one newline-delimited record without allowing an untrusted peer to
# allocate an unbounded shell string.  The caller supplies one absolute
# deadline for the whole header/request phase; the one-second read timeout
# also makes an idle peer release the listener promptly.

bounded_read_line() {
    local max_bytes="$1"
    local deadline_seconds="$2"
    local character=""
    local count=0

    BOUNDED_READ_LINE=""
    while [ "$count" -lt "$max_bytes" ]; do
        if ! IFS= read -r -N 1 -t 1 character; then
            return 1
        fi
        if [ "$character" = $'\n' ]; then
            return 0
        fi
        BOUNDED_READ_LINE="${BOUNDED_READ_LINE}${character}"
        count=$((count + 1))
        if [ "$SECONDS" -ge "$deadline_seconds" ]; then
            return 3
        fi
    done
    return 2
}
