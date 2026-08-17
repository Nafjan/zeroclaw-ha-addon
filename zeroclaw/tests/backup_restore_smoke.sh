#!/bin/sh
# Exercise the persistent-data contract used by Supervisor backups.
#
# Supervisor persists an app's /data volume. The test models that volume,
# verifies that a backup can restore it byte-for-byte, and proves that
# ephemeral /run state is not part of the archive we ask Supervisor to own.

set -eu

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

SOURCE="$ROOT/source"
RESTORE="$ROOT/restore"
ARCHIVE="$ROOT/zeroclaw-backup.tar"

mkdir -p \
    "$SOURCE/data/workspace/sessions-1" \
    "$SOURCE/data/migrations/3.1.3.3-to-3.1.3.5" \
    "$SOURCE/data/audit"

printf 'brain-before-backup\n' > "$SOURCE/data/brain.db"
printf 'config-before-backup\n' > "$SOURCE/data/config.toml"
printf 'session-before-backup\n' > "$SOURCE/data/workspace/sessions-1/state.db"
printf 'old_version=3.1.3.3\nnew_version=3.1.3.5\n' \
    > "$SOURCE/data/migrations/3.1.3.3-to-3.1.3.5/manifest"
printf '{"event":"intent"}\n' > "$SOURCE/data/audit/2026-08-17.jsonl"
# options.json is Supervisor-owned configuration state. It must be recoverable,
# but remains secret-bearing and is never copied into the planner workspace.
printf '{"openrouter_api_key":"backup-secret"}\n' > "$SOURCE/data/options.json"
chmod 0600 "$SOURCE/data/options.json"

# This is deliberately outside the Supervisor-owned backup scope.
mkdir -p "$ROOT/ephemeral/run/zeroclaw"
printf 'telegram-offset=42\n' > "$ROOT/ephemeral/run/zeroclaw/telegram-offset"

tar -cf "$ARCHIVE" -C "$SOURCE" data
mkdir -p "$RESTORE"
tar -xf "$ARCHIVE" -C "$RESTORE"

for path in \
    data/brain.db \
    data/config.toml \
    data/workspace/sessions-1/state.db \
    data/migrations/3.1.3.3-to-3.1.3.5/manifest \
    data/audit/2026-08-17.jsonl \
    data/options.json; do
    cmp "$SOURCE/$path" "$RESTORE/$path"
done

test "$(stat -c '%a' "$RESTORE/data/options.json" 2>/dev/null || stat -f '%Lp' "$RESTORE/data/options.json")" = "600"
if tar -tf "$ARCHIVE" | grep -Eq '(^|/)(run|ephemeral)(/|$)'; then
    echo "ERROR: ephemeral runtime state entered the backup archive" >&2
    exit 1
fi

printf 'BACKUP_RESTORE_OK persistent_data_restored=true ephemeral_runtime_excluded=true\n'
