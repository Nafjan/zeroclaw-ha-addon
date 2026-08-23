#!/bin/sh
# Filter model replies before they cross the Telegram boundary.
#
# ZeroClaw's gateway may return a provider's text verbatim when a model emits
# a non-native tool-call format. Internal tool syntax must never become a
# user-visible Telegram message. Exit 2 when such syntax is detected so the
# caller can send a safe, generic failure message instead of implying that an
# action completed.
set -u

awk '
function is_fence_start(line) {
    return line ~ /^[[:space:]]*```+[[:space:]]*(tool[_-]?calls?|invoke)([[:space:]]+.*)?[[:space:]]*$/
}

function is_fence_end(line) {
    return line ~ /^[[:space:]]*```+[[:space:]]*$/
}

function is_xml_start(line) {
    return line ~ /<[[:space:]]*(tool[_-]?calls?|function[_-]?calls?)([[:space:]>]|$)/
}

function is_xml_end(line) {
    return line ~ /<\/[[:space:]]*(tool[_-]?calls?|function[_-]?calls?)[[:space:]]*>/
}

function contains_internal_command(line) {
    # Catch helpers at non-identifier boundaries so shell, function-style,
    # punctuation-delimited, and standalone JSON forms cannot cross the
    # Telegram boundary. The model must never turn an internal helper into a
    # Telegram-visible instruction.
    return line ~ /(^|[^[:alnum:]_.-])(ha[.]action_guarded|memory_recall|zc[.][a-z0-9_]+|ha-[a-z0-9-]+)([^[:alnum:]_.-]|$)/
}

BEGIN {
    internal = 0
    in_fence = 0
    in_xml = 0
}

{
    line = $0

    if (in_fence) {
        internal = 1
        if (is_fence_end(line)) in_fence = 0
        next
    }

    if (is_fence_start(line)) {
        internal = 1
        in_fence = 1
        next
    }

    if (in_xml) {
        internal = 1
        if (is_xml_end(line)) in_xml = 0
        next
    }

    if (is_xml_start(line)) {
        internal = 1
        if (!is_xml_end(line)) in_xml = 1
        next
    }

    if (contains_internal_command(line)) {
        internal = 1
        next
    }

    print line
}

END {
    if (internal) exit 2
}
'
