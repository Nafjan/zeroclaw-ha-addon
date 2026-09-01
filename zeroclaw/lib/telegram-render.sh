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
    return line ~ /(^|[^[:alnum:]_.-])(ha[.]action_guarded|memory_recall|zc[.][a-z0-9_]+|zc-[a-z0-9-]+|ha-[a-z0-9-]+)([^[:alnum:]_.-]|$)/
}

function contains_internal_envelope(line) {
    # A provider may return a generic tool/function envelope even when it does
    # not name one of our helpers.  Treat JSON-ish tool/function envelopes as
    # internal protocol, never as user-facing prose.
    return line ~ /^[[:space:]]*(\{|\[)/ &&
      ((line ~ /"tool(_call|_name)?"[[:space:]]*:/) ||
       (line ~ /"function(_call)?"[[:space:]]*:/) ||
       (line ~ /"name"[[:space:]]*:/ && line ~ /"arguments?"[[:space:]]*:/))
}

function contains_credential(line) {
    # Reject common bearer/key forms rather than attempting lossy redaction.
    # The broker already prevents configured credentials from entering normal
    # model output; this is a final Telegram-boundary defense-in-depth check.
    return line ~ /(^|[^[:alnum:]])Bearer[[:space:]]+[A-Za-z0-9._~+\/-]{16,}/ ||
      line ~ /(^|[^[:alnum:]])(sk-|nvapi-|ark-)[A-Za-z0-9_-]{12,}/ ||
      line ~ /"(authorization|api[_-]?key|access[_-]?token|secret[_-]?key)"[[:space:]]*:[[:space:]]*"[^"]{12,}"/
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

    if (contains_internal_envelope(line) || contains_credential(line)) {
        internal = 1
        next
    }

    print line
}

END {
    if (internal) exit 2
}
'
