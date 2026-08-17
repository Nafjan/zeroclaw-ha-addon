#!/bin/sh
# Preserve persistent ZeroClaw state across app upgrades.
#
# The previous entrypoint deleted sessions and brain.db whenever the app
# version changed.  This helper deliberately performs only a snapshot and an
# atomic version-marker update.  Schema-specific migrations can be added later
# without making rollback destructive.

set -eu

[ "$#" -eq 3 ] || { echo "Usage: state-migrate <data_dir> <version_file> <new_version>" >&2; exit 64; }

state_migrate() {
    data_dir=$1
    version_file=$2
    new_version=$3

    old_version=""
    if [ -f "$version_file" ]; then
        old_version=$(tr -d '\r\n' < "$version_file")
    fi

    if [ "$old_version" = "$new_version" ]; then
        return 0
    fi

    case "$old_version" in
        "") old_label=fresh ;;
        *[!A-Za-z0-9._-]*) old_label=unknown ;;
        *) old_label=$old_version ;;
    esac

    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    backup_dir="$data_dir/migrations/${old_label}-to-${new_version}-${stamp}-$$"
    mkdir -p "$backup_dir"

    copy_if_present() {
        source_path=$1
        target_path=$2
        if [ -e "$source_path" ]; then
            mkdir -p "$(dirname "$target_path")"
            cp -a "$source_path" "$target_path"
        fi
    }

    copy_if_present "$data_dir/brain.db" "$backup_dir/brain.db"
    copy_if_present "$data_dir/config.toml" "$backup_dir/config.toml"
    for session_path in "$data_dir"/workspace/sessions*; do
        [ -e "$session_path" ] || continue
        copy_if_present "$session_path" "$backup_dir/workspace/$(basename "$session_path")"
    done

    {
        printf 'old_version=%s\n' "$old_version"
        printf 'new_version=%s\n' "$new_version"
        printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'backup_dir=%s\n' "$backup_dir"
    } > "$backup_dir/manifest"

    # The manifest is accompanied by checksums for every copied file.  The
    # restore helper verifies these before moving anything back into place.
    : > "$backup_dir/checksums"
    (
        cd "$backup_dir"
        find . -type f ! -name checksums -print | sort | while IFS= read -r file; do
            sha256sum "$file"
        done
    ) > "$backup_dir/checksums"
    sync

    marker_tmp="${version_file}.tmp.$$"
    printf '%s\n' "$new_version" > "$marker_tmp"
    mv -f "$marker_tmp" "$version_file"
    sync
    printf 'STATE_MIGRATION snapshot=%s old=%s new=%s\n' "$backup_dir" "$old_version" "$new_version"
}

state_migrate "$@"
