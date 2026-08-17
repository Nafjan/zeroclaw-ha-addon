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
mkdir "$ROLLBACK_DIR"
mkdir -p "$ROLLBACK_DIR/workspace"

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

move_live() {
    source_path="$1"
    target_path="$2"
    if [ -e "$source_path" ]; then
        mkdir -p "$(dirname "$target_path")"
        mv "$source_path" "$target_path"
    fi
}

restore_copy() {
    source_path="$1"
    target_path="$2"
    if [ -e "$source_path" ]; then
        mkdir -p "$(dirname "$target_path")"
        cp -a "$source_path" "$target_path"
    fi
}

move_live "$DATA_DIR/brain.db" "$ROLLBACK_DIR/brain.db"
move_live "$DATA_DIR/config.toml" "$ROLLBACK_DIR/config.toml"
for session_path in "$DATA_DIR"/workspace/sessions*; do
    [ -e "$session_path" ] || continue
    move_live "$session_path" "$ROLLBACK_DIR/workspace/$(basename "$session_path")"
done

restore_copy "$BACKUP_DIR/brain.db" "$DATA_DIR/brain.db"
restore_copy "$BACKUP_DIR/config.toml" "$DATA_DIR/config.toml"
for session_path in "$BACKUP_DIR"/workspace/sessions*; do
    [ -e "$session_path" ] || continue
    restore_copy "$session_path" "$DATA_DIR/workspace/$(basename "$session_path")"
done

if [ -n "$OLD_VERSION" ]; then
    MARKER_TMP="${VERSION_FILE}.tmp.$$"
    printf '%s\n' "$OLD_VERSION" > "$MARKER_TMP"
    chmod 0600 "$MARKER_TMP"
    mv -f "$MARKER_TMP" "$VERSION_FILE"
else
    rm -f "$VERSION_FILE"
fi
write_snapshot_metadata "$ROLLBACK_DIR" "$ROLLBACK_OLD_VERSION" "$OLD_VERSION"
sync
printf 'STATE_RESTORE backup=%s rollback_snapshot=%s restored_version=%s\n' \
    "$BACKUP_DIR" "$ROLLBACK_DIR" "${OLD_VERSION:-fresh}"
