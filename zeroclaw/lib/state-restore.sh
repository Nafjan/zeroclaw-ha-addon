#!/bin/sh
# Restore the schema-governed persistent state inventory captured by
# state-migrate.sh.  The current state is first snapshotted into a rollback
# directory, so a failed restore remains recoverable.

set -eu
umask 077

[ "$#" -eq 2 ] || {
    echo "Usage: state-restore <data_dir> <backup_dir>" >&2
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

DATA_DIR=$(cd "$1" 2>/dev/null && pwd -P) || die "data directory does not exist"
BACKUP_DIR=$(cd "$2" 2>/dev/null && pwd -P) || die "backup directory does not exist"
MIGRATIONS_DIR="$DATA_DIR/migrations"
SCHEMA_FILE="$DATA_DIR/.state-schema"

[ "$(dirname "$BACKUP_DIR")" = "$MIGRATIONS_DIR" ] ||
    die "backup must be a direct child of ${MIGRATIONS_DIR}"
[ -f "$BACKUP_DIR/manifest" ] || die "backup manifest is missing"
[ -f "$BACKUP_DIR/checksums" ] || die "backup checksums are missing"

manifest_value() {
    key="$1"
    sed -n "s/^${key}=//p" "$BACKUP_DIR/manifest" | head -n 1
}

OLD_SCHEMA=$(manifest_value old_schema)
NEW_SCHEMA=$(manifest_value new_schema)
OLD_VERSION=$(manifest_value old_version)
NEW_VERSION=$(manifest_value new_version)

if [ -n "$OLD_SCHEMA" ]; then
    printf '%s' "$OLD_SCHEMA" | grep -Eq '^(0|[1-9][0-9]{0,2})$' || die "backup old_schema is malformed"
    [ "$OLD_SCHEMA" -le 255 ] || die "backup old_schema is out of range"
fi
[ -n "$OLD_VERSION" ] || die "backup manifest has no old_version"

# Verify every file before creating or touching live state.  Generated paths
# are relative to BACKUP_DIR; reject traversal and symlink-based escapes.
if ! (
    cd "$BACKUP_DIR"
    while IFS=' ' read -r digest file; do
        [ -n "$digest" ] || continue
        case "$file" in
            ./*)
                case "$file" in
                    ./*/../*|./../*|../*|.|./|./..|..)
                        echo "ERROR: unsafe checksum path: $file" >&2
                        exit 1
                        ;;
                    *) ;;
                esac
                ;;
            *) echo "ERROR: unsafe checksum path: $file" >&2; exit 1 ;;
        esac
        printf '%s' "$digest" | grep -Eq '^[0-9a-fA-F]{64}$' || {
            echo "ERROR: invalid checksum in backup" >&2
            exit 1
        }
        [ ! -L "$file" ] || {
            echo "ERROR: backup contains a symlink: $file" >&2
            exit 1
        }
        actual=$(sha256sum "$file" | cut -d' ' -f1)
        [ "$actual" = "$digest" ] || {
            echo "ERROR: backup checksum mismatch for $file" >&2
            exit 1
        }
    done < checksums
); then
    exit 1
fi

[ -d "$MIGRATIONS_DIR" ] && [ ! -L "$MIGRATIONS_DIR" ] || die "migrations directory is unsafe"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
ROLLBACK_DIR="$MIGRATIONS_DIR/rollback-${STAMP}-$$"
STAGE_DIR="$MIGRATIONS_DIR/.restore-stage-${STAMP}-$$"
mkdir "$ROLLBACK_DIR" "$STAGE_DIR"

current_schema=legacy
if [ -e "$SCHEMA_FILE" ]; then
    [ ! -L "$SCHEMA_FILE" ] && [ -f "$SCHEMA_FILE" ] || die "current schema marker is unsafe"
    current_schema=$(tr -d '\r' < "$SCHEMA_FILE")
    printf '%s' "$current_schema" | grep -Eq '^(0|[1-9][0-9]{0,2})$' || die "current schema marker is malformed"
    [ "$current_schema" -le 255 ] || die "current schema marker is out of range"
fi

rollback_ready=0
restore_succeeded=0
recover_on_failure() {
    status=$?
    if [ "$restore_succeeded" -ne 1 ] && [ "$status" -ne 0 ]; then
        if [ "$rollback_ready" -eq 1 ] && state_inventory_remove "$DATA_DIR" &&
            state_inventory_copy "$ROLLBACK_DIR" "$DATA_DIR" &&
            state_inventory_copy_markers "$ROLLBACK_DIR" "$DATA_DIR"; then
            echo "ERROR: restore failed; live state was restored from rollback snapshot $ROLLBACK_DIR" >&2
        else
            echo "ERROR: restore failed and automatic recovery from $ROLLBACK_DIR also failed" >&2
            status=1
        fi
    fi
    rm -rf -- "$STAGE_DIR" 2>/dev/null || true
    if [ "$rollback_ready" -eq 0 ] && [ "$status" -ne 0 ]; then
        rm -rf -- "$ROLLBACK_DIR" 2>/dev/null || true
    fi
    exit "$status"
}
trap recover_on_failure EXIT

state_inventory_copy "$DATA_DIR" "$ROLLBACK_DIR" || die "current state could not be snapshotted"
state_inventory_copy_markers "$DATA_DIR" "$ROLLBACK_DIR" || die "current state markers could not be snapshotted"
{
    printf 'format=2\n'
    printf 'old_schema=%s\n' "$current_schema"
    printf 'new_schema=%s\n' "${OLD_SCHEMA:-legacy}"
    printf 'old_version=%s\n' "${current_schema}"
    printf 'new_version=%s\n' "${OLD_VERSION}"
    printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'backup_dir=%s\n' "$ROLLBACK_DIR"
} > "$ROLLBACK_DIR/manifest"
: > "$ROLLBACK_DIR/checksums"
(
    cd "$ROLLBACK_DIR"
    find . -type f ! -name checksums -print | sort | while IFS= read -r file; do
        sha256sum "$file"
    done
) > "$ROLLBACK_DIR/checksums"
sync
rollback_ready=1

state_inventory_copy "$BACKUP_DIR" "$STAGE_DIR" || die "restore staging failed; live state was not changed"
state_inventory_copy_markers "$BACKUP_DIR" "$STAGE_DIR" || die "restore marker staging failed; live state was not changed"

restore_succeeded=0
state_inventory_remove "$DATA_DIR" || die "current state could not be removed safely"
state_inventory_copy "$STAGE_DIR" "$DATA_DIR" || die "staged state could not be installed"
state_inventory_copy_markers "$STAGE_DIR" "$DATA_DIR" || die "staged state markers could not be installed"
if [ "${STATE_RESTORE_TEST_FAIL_AFTER_MUTATION:-false}" = "true" ]; then
    die "test failure injected after live-state replacement"
fi
restore_succeeded=1
sync
printf 'STATE_RESTORE backup=%s rollback_snapshot=%s restored_schema=%s restored_version=%s\n' \
    "$BACKUP_DIR" "$ROLLBACK_DIR" "${OLD_SCHEMA:-legacy}" "$OLD_VERSION"
