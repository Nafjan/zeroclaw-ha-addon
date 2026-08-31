#!/bin/sh
# Upgrade the persistent state contract without using the release version as a
# migration key.  Legacy semver markers are recognized as schema 0, captured in
# a checksummed snapshot, and removed only after the schema marker is committed.

set -eu
umask 077

[ "$#" -eq 3 ] || {
    echo "Usage: state-migrate <data_dir> <schema_file> <new_schema>" >&2
    exit 64
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
if [ -r /opt/zeroclaw/lib/state-inventory.sh ]; then
    # shellcheck disable=SC1091
    . /opt/zeroclaw/lib/state-inventory.sh
else
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/state-inventory.sh"
fi

die() {
    echo "ERROR: $*" >&2
    exit 1
}

validate_schema() {
    schema_value="$1"
    printf '%s' "$schema_value" | grep -Eq '^(0|[1-9][0-9]{0,2})$' ||
        die "state schema must be an integer from 0 through 255"
    [ "$schema_value" -le 255 ] ||
        die "state schema must be an integer from 0 through 255"
}

validate_new_schema() {
    schema_value="$1"
    printf '%s' "$schema_value" | grep -Eq '^[1-9][0-9]{0,2}$' ||
        die "new state schema must be an integer from 1 through 255"
    [ "$schema_value" -le 255 ] ||
        die "new state schema must be an integer from 1 through 255"
}

read_legacy_marker() {
    marker_path="$1"
    marker_label="$2"
    if [ -L "$marker_path" ]; then
        die "legacy ${marker_label} marker is a symlink"
    fi
    if [ -e "$marker_path" ]; then
        [ -f "$marker_path" ] || die "legacy ${marker_label} marker is not a regular file"
        marker_value=$(tr -d '\r' < "$marker_path")
        # run.sh reserves the old root-level marker name with a root-owned,
        # mode-0600 tombstone after schema migration.  Accept only the exact
        # schema-bound tombstone; a planner-created file with the same text is
        # still rejected because it cannot satisfy the ownership/mode check.
        if [ "$marker_value" = "schema-tombstone-${old_schema}" ] &&
            [ "$(stat -c '%u:%a' "$marker_path" 2>/dev/null || true)" = "0:600" ]; then
            return 0
        fi
        printf '%s' "$marker_value" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(-canary\.[0-9]+)?$' ||
            die "legacy ${marker_label} marker is malformed"
        if [ -n "$legacy_version" ] && [ "$legacy_version" != "$marker_value" ]; then
            die "legacy version markers disagree"
        fi
        legacy_version="$marker_value"
        legacy_source="$marker_label"
    fi
}

state_migrate() {
    data_dir="$1"
    schema_file="$2"
    new_schema="$3"

    [ -d "$data_dir" ] && [ ! -L "$data_dir" ] || die "data directory is not a real directory"
    case "$schema_file" in
        "$data_dir/.state-schema") ;;
        *) die "schema file must be ${data_dir}/.state-schema" ;;
    esac
    if [ -L "$schema_file" ]; then
        die "state schema marker is a symlink"
    fi
    if [ -e "$schema_file" ]; then
        [ -f "$schema_file" ] || die "state schema marker is not a regular file"
    fi
    validate_new_schema "$new_schema"

    old_schema=0
    if [ -f "$schema_file" ]; then
        old_schema=$(tr -d '\r' < "$schema_file")
        validate_schema "$old_schema"
    fi

    legacy_version=""
    legacy_source=""
    workspace_dir="$data_dir/workspace"
    if [ -L "$workspace_dir" ]; then
        die "workspace is a symlink"
    fi
    if [ -e "$workspace_dir" ] && [ ! -d "$workspace_dir" ]; then
        die "workspace is not a directory"
    fi
    read_legacy_marker "$data_dir/.state-version" ".state-version"
    read_legacy_marker "$workspace_dir/.last_version" "workspace/.last_version"

    if [ "$old_schema" -gt "$new_schema" ]; then
        die "refusing to migrate state schema backwards from ${old_schema} to ${new_schema}"
    fi
    if [ "$old_schema" -eq "$new_schema" ]; then
        # The integer schema is authoritative once it exists.  Remove any
        # validated legacy compatibility markers left by an interrupted
        # transition or restored pre-schema snapshot; run.sh will recreate
        # only its root-owned tombstone for the reserved root-level name.
        rm -f -- "$data_dir/.state-version" "$workspace_dir/.last_version" || true
        return 0
    fi

    migrations_dir="$data_dir/migrations"
    if [ -L "$migrations_dir" ]; then
        die "migrations directory is a symlink"
    fi
    if [ -e "$migrations_dir" ] && [ ! -d "$migrations_dir" ]; then
        die "migrations path is not a directory"
    fi
    mkdir -p "$migrations_dir"

    if [ -n "$legacy_version" ]; then
        old_label="legacy-${legacy_version}"
    else
        old_label="schema-${old_schema}"
    fi
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    backup_dir="$migrations_dir/${old_label}-to-schema-${new_schema}-${stamp}-$$"
    mkdir "$backup_dir"
    backup_committed=0
    cleanup_failed_backup() {
        status=$?
        if [ "$status" -ne 0 ] && [ "$backup_committed" -eq 0 ] &&
            [ -n "${backup_dir:-}" ] && [ -d "$backup_dir" ] && [ ! -L "$backup_dir" ]; then
            rm -rf -- "$backup_dir"
        fi
        exit "$status"
    }
    trap cleanup_failed_backup EXIT

    state_inventory_copy "$data_dir" "$backup_dir" || die "persistent state could not be snapshotted"
    state_inventory_copy_markers "$data_dir" "$backup_dir" || die "state markers could not be snapshotted"

    legacy_value="${legacy_version:-none}"
    legacy_origin="${legacy_source:-none}"
    {
        printf 'format=2\n'
        printf 'old_schema=%s\n' "$old_schema"
        printf 'new_schema=%s\n' "$new_schema"
        printf 'old_version=%s\n' "${legacy_version:-fresh}"
        printf 'new_version=schema-%s\n' "$new_schema"
        printf 'legacy_version=%s\n' "$legacy_value"
        printf 'legacy_marker_source=%s\n' "$legacy_origin"
        printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'backup_dir=%s\n' "$backup_dir"
    } > "$backup_dir/manifest"

    : > "$backup_dir/checksums"
    (
        cd "$backup_dir"
        find . -type f ! -name checksums -print | sort | while IFS= read -r file; do
            sha256sum "$file"
        done
    ) > "$backup_dir/checksums"
    sync

    if [ "${STATE_MIGRATE_TEST_FAIL_BEFORE_COMMIT:-false}" = "true" ]; then
        die "test failure injected before schema commit"
    fi

    marker_tmp="${schema_file}.tmp.$$"
    printf '%s\n' "$new_schema" > "$marker_tmp"
    chmod 0600 "$marker_tmp"
    mv -f "$marker_tmp" "$schema_file"
    sync
    backup_committed=1

    # The schema marker is now authoritative.  Keep the old values in the
    # checksummed snapshot, but remove active compatibility markers so a
    # planner-writable legacy path cannot create ambiguity on a later start.
    rm -f -- "$data_dir/.state-version" "$workspace_dir/.last_version" || true
    trap - EXIT
    printf 'STATE_MIGRATION snapshot=%s old_schema=%s new_schema=%s legacy=%s\n' \
        "$backup_dir" "$old_schema" "$new_schema" "$legacy_value"
}

state_migrate "$@"
