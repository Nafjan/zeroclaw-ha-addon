#!/bin/sh
# Restore only the state files captured by state-migrate.sh.
#
# Usage: state-restore <data_dir> <backup_dir>
# The app must be stopped before invoking this helper.  The current state is
# moved into a new rollback snapshot first, so a failed/incorrect rollback is
# recoverable without deleting the data directory.

set -eu

[ "$#" -eq 2 ] || {
    echo "Usage: state-restore <data_dir> <backup_dir>" >&2
    exit 64
}

DATA_DIR=$(cd "$1" 2>/dev/null && pwd -P) || {
    echo "ERROR: data directory does not exist" >&2
    exit 1
}
BACKUP_DIR=$(cd "$2" 2>/dev/null && pwd -P) || {
    echo "ERROR: backup directory does not exist" >&2
    exit 1
}
MIGRATIONS_DIR="$DATA_DIR/migrations"
VERSION_FILE="${ZEROCLAW_VERSION_FILE:-$DATA_DIR/.state-version}"

[ "$(dirname "$BACKUP_DIR")" = "$MIGRATIONS_DIR" ] || {
    echo "ERROR: backup must be a direct child of ${MIGRATIONS_DIR}" >&2
    exit 1
}
[ -f "$BACKUP_DIR/manifest" ] || { echo "ERROR: backup manifest is missing" >&2; exit 1; }
[ -f "$BACKUP_DIR/checksums" ] || { echo "ERROR: backup checksums are missing" >&2; exit 1; }

grep -q '^old_version=' "$BACKUP_DIR/manifest" || {
    echo "ERROR: backup manifest has no old_version" >&2
    exit 1
}
OLD_VERSION=$(sed -n 's/^old_version=//p' "$BACKUP_DIR/manifest" | head -n 1)
NEW_VERSION=$(sed -n 's/^new_version=//p' "$BACKUP_DIR/manifest" | head -n 1)

# Verify the snapshot before moving the live state.  All paths in the
# generated checksum file are relative to BACKUP_DIR and are checked to avoid
# turning a tampered manifest into a path traversal primitive.
if ! (
    cd "$BACKUP_DIR"
    while IFS='  ' read -r digest file; do
        [ -n "$digest" ] || continue
        case "$file" in
            ./*)
                case "$file" in
                    ./*/../*|./../*|../*)
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
        actual=$(sha256sum "$file" | cut -d' ' -f1)
        [ "$actual" = "$digest" ] || {
            echo "ERROR: backup checksum mismatch for $file" >&2
            exit 1
        }
    done < checksums
); then
    exit 1
fi

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
ROLLBACK_DIR="$MIGRATIONS_DIR/rollback-${STAMP}-$$"
STAGE_DIR="$MIGRATIONS_DIR/.restore-stage-${STAMP}-$$"
[ ! -L "$MIGRATIONS_DIR" ] || {
    echo "ERROR: migrations directory is a symlink" >&2
    exit 1
}
mkdir "$ROLLBACK_DIR" "$STAGE_DIR"
mkdir -p "$ROLLBACK_DIR/workspace" "$STAGE_DIR/workspace"

CURRENT_VERSION=""
if [ -f "$VERSION_FILE" ]; then
    CURRENT_VERSION=$(tr -d '\r\n' < "$VERSION_FILE")
fi
ROLLBACK_OLD_VERSION="${CURRENT_VERSION:-${NEW_VERSION:-}}"

write_snapshot_metadata() {
    snapshot_dir="$1"
    old_version="$2"
    new_version="$3"
    {
        printf 'old_version=%s\n' "$old_version"
        printf 'new_version=%s\n' "$new_version"
        printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'backup_dir=%s\n' "$snapshot_dir"
    } > "$snapshot_dir/manifest"
    : > "$snapshot_dir/checksums"
    (
        cd "$snapshot_dir"
        find . -type f ! -name manifest ! -name checksums -print | sort | while IFS= read -r file; do
            sha256sum "$file"
        done
    ) > "$snapshot_dir/checksums"
    sync
}

copy_state_set() {
    source_root="$1"
    target_root="$2"
    for state_file in brain.db config.toml; do
        source_path="$source_root/$state_file"
        target_path="$target_root/$state_file"
        if [ -e "$source_path" ]; then
            [ ! -L "$source_path" ] || {
                echo "ERROR: state file is a symlink: $source_path" >&2
                return 1
            }
            mkdir -p "$(dirname "$target_path")"
            cp -a -- "$source_path" "$target_path"
        fi
    done
    source_workspace="$source_root/workspace"
    target_workspace="$target_root/workspace"
    if [ -e "$source_workspace" ]; then
        [ ! -L "$source_workspace" ] || {
            echo "ERROR: workspace is a symlink: $source_workspace" >&2
            return 1
        }
        mkdir -p "$target_workspace"
        for session_path in "$source_workspace"/sessions*; do
            [ -e "$session_path" ] || continue
            [ ! -L "$session_path" ] || {
                echo "ERROR: session state is a symlink: $session_path" >&2
                return 1
            }
            cp -a -- "$session_path" "$target_workspace/$(basename "$session_path")"
        done
    fi
}

remove_live_state_set() {
    rm -f -- "$DATA_DIR/brain.db" "$DATA_DIR/config.toml"
    workspace="$DATA_DIR/workspace"
    if [ -e "$workspace" ]; then
        [ ! -L "$workspace" ] || {
            echo "ERROR: live workspace is a symlink" >&2
            return 1
        }
        for session_path in "$workspace"/sessions*; do
            [ -e "$session_path" ] || continue
            rm -rf -- "$session_path"
        done
    fi
}

restore_version_marker() {
    restore_version="$1"
    if [ -n "$restore_version" ]; then
        MARKER_TMP="${VERSION_FILE}.tmp.$$"
        printf '%s\n' "$restore_version" > "$MARKER_TMP"
        chmod 0600 "$MARKER_TMP"
        mv -f "$MARKER_TMP" "$VERSION_FILE"
    else
        rm -f -- "$VERSION_FILE"
    fi
}

# Build the rollback snapshot and the replacement tree completely before
# touching live state.  A failed copy therefore leaves the running state
# unchanged and never creates a rollback directory without a manifest.
if ! copy_state_set "$DATA_DIR" "$ROLLBACK_DIR"; then
    echo "ERROR: current state could not be snapshotted; refusing restore" >&2
    exit 1
fi
if ! write_snapshot_metadata "$ROLLBACK_DIR" "$ROLLBACK_OLD_VERSION" "$OLD_VERSION"; then
    echo "ERROR: rollback snapshot metadata could not be written; refusing restore" >&2
    exit 1
fi
if ! copy_state_set "$BACKUP_DIR" "$STAGE_DIR"; then
    echo "ERROR: restore staging failed; live state was not changed" >&2
    exit 1
fi

RESTORE_MUTATION_STARTED=0
RESTORE_SUCCEEDED=0
recover_on_failure() {
    status=$?
    if [ "$RESTORE_MUTATION_STARTED" -eq 1 ] && [ "$RESTORE_SUCCEEDED" -ne 1 ] && [ "$status" -ne 0 ]; then
        if remove_live_state_set && copy_state_set "$ROLLBACK_DIR" "$DATA_DIR" && \
            restore_version_marker "$ROLLBACK_OLD_VERSION"; then
            echo "ERROR: restore failed; live state was restored from rollback snapshot $ROLLBACK_DIR" >&2
        else
            echo "ERROR: restore failed and automatic recovery from $ROLLBACK_DIR also failed" >&2
            status=1
        fi
    fi
    rm -rf -- "$STAGE_DIR" 2>/dev/null || true
    if [ "$RESTORE_MUTATION_STARTED" -eq 0 ] && [ "$status" -ne 0 ]; then
        rm -rf -- "$ROLLBACK_DIR" 2>/dev/null || true
    fi
    exit "$status"
}
trap recover_on_failure EXIT

RESTORE_MUTATION_STARTED=1
remove_live_state_set
copy_state_set "$STAGE_DIR" "$DATA_DIR"
if [ "${STATE_RESTORE_TEST_FAIL_AFTER_MUTATION:-false}" = "true" ]; then
    echo "ERROR: test failure injected after live-state replacement" >&2
    exit 1
fi
restore_version_marker "$OLD_VERSION"
RESTORE_SUCCEEDED=1
sync
printf 'STATE_RESTORE backup=%s rollback_snapshot=%s restored_version=%s\n' \
    "$BACKUP_DIR" "$ROLLBACK_DIR" "${OLD_VERSION:-fresh}"
