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

FORMAT=$(manifest_value format)
OLD_SCHEMA=$(manifest_value old_schema)
NEW_SCHEMA=$(manifest_value new_schema)
OLD_VERSION=$(manifest_value old_version)
NEW_VERSION=$(manifest_value new_version)

[ "$FORMAT" = "2" ] || die "backup manifest format is unsupported"
if [ -n "$OLD_SCHEMA" ]; then
    printf '%s' "$OLD_SCHEMA" | grep -Eq '^(0|[1-9][0-9]{0,2})$' || die "backup old_schema is malformed"
    [ "$OLD_SCHEMA" -le 255 ] || die "backup old_schema is out of range"
fi
[ -n "$OLD_VERSION" ] || die "backup manifest has no old_version"
[ -n "$NEW_SCHEMA" ] || die "backup manifest has no new_schema"
printf '%s' "$NEW_SCHEMA" | grep -Eq '^[1-9][0-9]{0,2}$' || die "backup new_schema is malformed"
[ "$NEW_SCHEMA" -le 255 ] || die "backup new_schema is out of range"
[ "$NEW_VERSION" = "schema-${NEW_SCHEMA}" ] || die "backup new_version does not match new_schema"
case "$OLD_VERSION" in
    fresh) ;;
    *.*.*.*|*.*.*.*-canary.*)
        printf '%s' "$OLD_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(-canary\.[0-9]+)?$' ||
            die "backup old_version is malformed"
        ;;
    *) die "backup old_version is malformed" ;;
esac

# Verify every file before creating or touching live state.  Generated paths
# are relative to BACKUP_DIR; reject traversal and symlink-based escapes.
if ! (
    cd "$BACKUP_DIR"
    while IFS=' ' read -r digest file; do
        [ -n "$digest" ] || continue
        # GNU sha256sum uses a leading '*' before the pathname in binary mode;
        # accept that equivalent checksum representation as well as the
        # ordinary two-space text-mode form.
        file="${file#\*}"
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
runtime_lock_held=0
RUNTIME_LOCK_DIR="$DATA_DIR/.state-runtime-lock"
release_runtime_lock() {
    if [ "$runtime_lock_held" -eq 1 ]; then
        rm -f -- "$RUNTIME_LOCK_DIR/pid"
        rmdir "$RUNTIME_LOCK_DIR" 2>/dev/null || true
        runtime_lock_held=0
    fi
}
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
    release_runtime_lock
    exit "$status"
}

# The launcher holds this root-only lock for the entire lifetime of the app.
# Restore takes the same lock, so validation, snapshot, removal, and install
# cannot race a planner/broker process or a concurrent restore.  A stale lock
# from a terminated app is cleared only after confirming its recorded PID is no
# longer live; malformed locks fail closed.
if [ -e "$RUNTIME_LOCK_DIR" ]; then
    [ ! -L "$RUNTIME_LOCK_DIR" ] && [ -d "$RUNTIME_LOCK_DIR" ] && \
        [ -f "$RUNTIME_LOCK_DIR/pid" ] || die "persistent-state runtime lock is malformed"
    runtime_pid=$(cat "$RUNTIME_LOCK_DIR/pid" 2>/dev/null || true)
    case "$runtime_pid" in
        ''|*[!0-9]*) die "persistent-state runtime lock owner is invalid" ;;
    esac
    kill -0 "$runtime_pid" 2>/dev/null && \
        die "the app or another maintenance operation is still running; stop it before restore"
    rm -f -- "$RUNTIME_LOCK_DIR/pid"
    rmdir "$RUNTIME_LOCK_DIR" 2>/dev/null || die "stale persistent-state runtime lock could not be cleared"
fi
mkdir "$RUNTIME_LOCK_DIR" || die "could not acquire persistent-state runtime lock"
printf '%s\n' "$$" > "$RUNTIME_LOCK_DIR/pid"
chmod 0600 "$RUNTIME_LOCK_DIR/pid"
runtime_lock_held=1
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
