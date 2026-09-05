#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: classify-canary-tag-missing.sh IMAGE TARGET_TAG ERROR_FILE" >&2
  exit 2
fi

image="$1"
target_tag="$2"
error_file="$3"

case "$image" in
  ""|*[!A-Za-z0-9._/:@-]*) exit 2 ;;
esac
case "$target_tag" in
  ""|*[!A-Za-z0-9._-]*) exit 2 ;;
esac
test -f "$error_file"

# Command substitution removes trailing newlines; remove CR only so CRLF is
# tolerated without accepting additional lines or arbitrary diagnostic text.
diagnostic="$(tr -d '\r' < "$error_file" | tr '[:upper:]' '[:lower:]')"
expected_prefix="error: $(printf '%s' "$image" | tr '[:upper:]' '[:lower:]'):$(printf '%s' "$target_tag" | tr '[:upper:]' '[:lower:]'): "

case "$diagnostic" in
  "${expected_prefix}not found"|\
  "${expected_prefix}manifest unknown"|\
  "${expected_prefix}name unknown"|\
  "${expected_prefix}no such manifest")
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
