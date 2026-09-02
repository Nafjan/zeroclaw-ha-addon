#!/bin/sh
# Restore the schema-governed persistent state inventory captured by
# state-migrate.sh.  The current state is first snapshotted into a rollback
# directory, so a failed restore remains recoverable.

set -eu
umask 077

[ "$(id -u)" -eq 0 ] || {
    echo "state restore must run as root" >&2
    exit 1
}

RECOVERY_MODE=false
if [ "${1:-}" = "recover" ]; then
    [ "$#" -eq 2 ] || {
        echo "Usage: state-restore recover <data_dir>" >&2
        exit 64
    }
    DATA_ARG="$2"
    RECOVERY_MODE=true
else
    [ "$#" -eq 2 ] || {
        echo "Usage: state-restore <data_dir> <backup_dir>" >&2
        exit 64
    }
    DATA_ARG="$1"
fi

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

DATA_DIR=$(cd "$DATA_ARG" 2>/dev/null && pwd -P) || die "data directory does not exist"
MIGRATIONS_DIR="$DATA_DIR/migrations"
SCHEMA_FILE="$DATA_DIR/.state-schema"
STATE_APP_SLUG="${ZEROCLAW_STATE_APP_SLUG:-zeroclaw}"
CURRENT_VERSION="${ZEROCLAW_ADDON_VERSION:-}"
CURRENT_SOURCE_COMMIT="${ZEROCLAW_ADDON_SOURCE_COMMIT:-}"
IDENTITY_OVERRIDE="${STATE_RESTORE_ALLOW_IDENTITY_OVERRIDE:-false}"
AUDIT_DIR="$DATA_DIR/audit"

verify_snapshot() {
    snapshot_dir="$1"
    [ -d "$snapshot_dir" ] && [ ! -L "$snapshot_dir" ] || die "snapshot directory is unsafe: $snapshot_dir"
    [ -f "$snapshot_dir/manifest" ] && [ ! -L "$snapshot_dir/manifest" ] || die "snapshot manifest is missing"
    [ -f "$snapshot_dir/checksums" ] && [ ! -L "$snapshot_dir/checksums" ] || die "snapshot checksums are missing"
    if ! (
        cd "$snapshot_dir"
        while IFS=' ' read -r digest file; do
            [ -n "$digest" ] || continue
            # GNU sha256sum uses a leading '*' before the pathname in binary
            # mode; accept that equivalent checksum representation as well as
            # the ordinary two-space text-mode form.
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
                echo "ERROR: invalid checksum in snapshot" >&2
                exit 1
            }
            [ ! -L "$file" ] || {
                echo "ERROR: snapshot contains a symlink: $file" >&2
                exit 1
            }
            actual=$(sha256sum "$file" | cut -d' ' -f1)
            [ "$actual" = "$digest" ] || {
                echo "ERROR: snapshot checksum mismatch for $file" >&2
                exit 1
            }
        done < checksums
    ); then
        exit 1
    fi
}

clear_directory_entries() {
    clear_dir="$1"
    [ -d "$clear_dir" ] && [ ! -L "$clear_dir" ] || die "approval state directory is unsafe: $clear_dir"
    state_inventory_validate_tree "$clear_dir" || die "approval state directory could not be validated: $clear_dir"
    for clear_entry in "$clear_dir"/* "$clear_dir"/.[!.]* "$clear_dir"/..?*; do
        [ -e "$clear_entry" ] || [ -L "$clear_entry" ] || continue
        rm -rf -- "$clear_entry"
    done
}

increment_restore_epoch() {
    RESTORE_EPOCH_FILE="$DATA_DIR/.approval-restore-epoch"
    restore_epoch=0
    if [ -e "$RESTORE_EPOCH_FILE" ] || [ -L "$RESTORE_EPOCH_FILE" ]; then
        [ -f "$RESTORE_EPOCH_FILE" ] && [ ! -L "$RESTORE_EPOCH_FILE" ] || die "approval restore epoch is unsafe"
        restore_epoch=$(tr -d '\r\n' < "$RESTORE_EPOCH_FILE")
        printf '%s' "$restore_epoch" | grep -Eq '^[0-9]+$' || die "approval restore epoch is malformed"
    fi
    restore_epoch=$((restore_epoch + 1))
    restore_epoch_tmp="${RESTORE_EPOCH_FILE}.tmp.$$"
    printf '%s\n' "$restore_epoch" > "$restore_epoch_tmp"
    chown root:root "$restore_epoch_tmp"
    chmod 0600 "$restore_epoch_tmp"
    mv -f "$restore_epoch_tmp" "$RESTORE_EPOCH_FILE"
}

invalidate_approval_state() {
    approval_rollback_dir="${1:-}"
    # Restoring the ordinary inventory must never resurrect a ticket, callback,
    # reply, or planner draft that was valid only in the pre-restore world.
    mkdir -p "$DATA_DIR/approved" "$DATA_DIR/approval-receipts/tickets" \
        "$DATA_DIR/approval-receipts/.claims" "$DATA_DIR/approval-receipts/.locks" \
        "$DATA_DIR/approval-receipts/outcomes" "$DATA_DIR/pending" \
        "$DATA_DIR/capability/telegram-replies" "$DATA_DIR/capability/telegram-callbacks"
    if [ -n "$approval_rollback_dir" ] &&
        [ -d "$approval_rollback_dir/approval-receipts/ticket-nonces" ] &&
        [ ! -L "$approval_rollback_dir/approval-receipts/ticket-nonces" ]; then
        state_inventory_validate_tree "$approval_rollback_dir/approval-receipts/ticket-nonces" ||
            die "rollback ticket nonce history could not be validated"
        mkdir -p "$DATA_DIR/approval-receipts/ticket-nonces"
        state_inventory_validate_tree "$DATA_DIR/approval-receipts/ticket-nonces" ||
            die "restored ticket nonce history could not be validated"
        for nonce_entry in "$approval_rollback_dir/approval-receipts/ticket-nonces"/*; do
            [ -e "$nonce_entry" ] || [ -L "$nonce_entry" ] || continue
            nonce_name=$(basename "$nonce_entry")
            [ ! -e "$DATA_DIR/approval-receipts/ticket-nonces/$nonce_name" ] || continue
            cp -a -- "$nonce_entry" "$DATA_DIR/approval-receipts/ticket-nonces/$nonce_name"
        done
    fi
    clear_directory_entries "$DATA_DIR/approved"
    clear_directory_entries "$DATA_DIR/approval-receipts/tickets"
    clear_directory_entries "$DATA_DIR/approval-receipts/.claims"
    clear_directory_entries "$DATA_DIR/approval-receipts/.locks"
    clear_directory_entries "$DATA_DIR/approval-receipts/outcomes"
    clear_directory_entries "$DATA_DIR/capability/telegram-replies"
    clear_directory_entries "$DATA_DIR/capability/telegram-callbacks"
    clear_directory_entries "$DATA_DIR/pending"

    for restore_receipt in "$DATA_DIR"/approval-receipts/*.sha256; do
        [ -f "$restore_receipt" ] && [ ! -L "$restore_receipt" ] || continue
        rm -f -- "$restore_receipt"
    done
    rm -f -- "$DATA_DIR/capability/telegram-bot-id" \
        "$DATA_DIR/capability/.telegram-approval-rate.lock"
    RESTORE_OFFSET_FILE="$DATA_DIR/capability/telegram-offset"
    if [ -e "$RESTORE_OFFSET_FILE" ] || [ -L "$RESTORE_OFFSET_FILE" ]; then
        [ -f "$RESTORE_OFFSET_FILE" ] && [ ! -L "$RESTORE_OFFSET_FILE" ] ||
            die "Telegram restore cursor is unsafe"
    fi
    restore_offset_tmp="${RESTORE_OFFSET_FILE}.tmp.$$"
    printf '%s\n' '-1' > "$restore_offset_tmp"
    chown root:root "$restore_offset_tmp"
    chmod 0600 "$restore_offset_tmp"
    mv -f "$restore_offset_tmp" "$RESTORE_OFFSET_FILE"
    increment_restore_epoch
}

transaction_manifest_value() {
    key="$1"
    sed -n "s/^${key}=//p" "$TRANSACTION_DIR/manifest" | head -n 1
}

write_transaction_state() {
    transaction_state="$1"
    case "$transaction_state" in
        prepared|mutating|committed|recovered) ;;
        *) die "restore transaction state is invalid" ;;
    esac
    [ -d "$TRANSACTION_DIR" ] && [ ! -L "$TRANSACTION_DIR" ] || die "restore transaction directory is unsafe"
    transaction_state_tmp="${TRANSACTION_DIR}/state.tmp.$$"
    printf '%s\n' "$transaction_state" > "$transaction_state_tmp"
    chmod 0600 "$transaction_state_tmp"
    mv -f "$transaction_state_tmp" "${TRANSACTION_DIR}/state"
    sync
}

restore_test_kill_if_requested() {
    [ "${STATE_RESTORE_TEST_KILL_PHASE:-}" = "$1" ] || return 0
    kill -KILL "$$"
}

recover_incomplete_restore() {
    [ -d "$MIGRATIONS_DIR" ] && [ ! -L "$MIGRATIONS_DIR" ] || die "migrations directory is unsafe"
    TRANSACTION_DIR=""
    for transaction_candidate in "$MIGRATIONS_DIR"/.restore-transaction-*; do
        [ -e "$transaction_candidate" ] || [ -L "$transaction_candidate" ] || continue
        [ -d "$transaction_candidate" ] && [ ! -L "$transaction_candidate" ] ||
            die "restore transaction path is unsafe"
        [ -z "$TRANSACTION_DIR" ] || die "multiple incomplete restore transactions found"
        TRANSACTION_DIR="$transaction_candidate"
    done
    [ -n "$TRANSACTION_DIR" ] || return 0
    [ -f "$TRANSACTION_DIR/manifest" ] && [ ! -L "$TRANSACTION_DIR/manifest" ] ||
        die "restore transaction manifest is missing"
    [ -f "$TRANSACTION_DIR/state" ] && [ ! -L "$TRANSACTION_DIR/state" ] ||
        die "restore transaction state is missing"
    transaction_format=$(transaction_manifest_value format)
    [ "$transaction_format" = 1 ] || die "restore transaction format is unsupported"
    transaction_state=$(tr -d '\r\n' < "$TRANSACTION_DIR/state")
    case "$transaction_state" in
        prepared|mutating|committed|recovered) ;;
        *) die "restore transaction state is invalid" ;;
    esac
    rollback_name=$(transaction_manifest_value rollback_dir)
    stage_name=$(transaction_manifest_value stage_dir)
    case "$rollback_name" in
        rollback-[A-Za-z0-9._-]*) ;;
        *) die "restore transaction rollback path is invalid" ;;
    esac
    case "$stage_name" in
        .restore-stage-[A-Za-z0-9._-]*) ;;
        *) die "restore transaction stage path is invalid" ;;
    esac
    ROLLBACK_DIR="$MIGRATIONS_DIR/$rollback_name"
    STAGE_DIR="$MIGRATIONS_DIR/$stage_name"
    verify_snapshot "$ROLLBACK_DIR"

    recovery_lock_held=0
    RECOVERY_LOCK_DIR="$DATA_DIR/.state-runtime-lock"
    release_recovery_runtime_lock() {
        if [ "$recovery_lock_held" -eq 1 ]; then
            rm -f -- "$RECOVERY_LOCK_DIR/pid"
            rmdir "$RECOVERY_LOCK_DIR" 2>/dev/null || true
            recovery_lock_held=0
        fi
    }
    if [ -e "$RECOVERY_LOCK_DIR" ]; then
        [ ! -L "$RECOVERY_LOCK_DIR" ] && [ -d "$RECOVERY_LOCK_DIR" ] &&
            [ -f "$RECOVERY_LOCK_DIR/pid" ] || die "persistent-state runtime lock is malformed"
        recovery_pid=$(cat "$RECOVERY_LOCK_DIR/pid" 2>/dev/null || true)
        case "$recovery_pid" in
            ''|*[!0-9]*) die "persistent-state runtime lock owner is invalid" ;;
        esac
        kill -0 "$recovery_pid" 2>/dev/null &&
            die "the app or another maintenance operation is still running; stop it before restore recovery"
        rm -f -- "$RECOVERY_LOCK_DIR/pid"
        rmdir "$RECOVERY_LOCK_DIR" 2>/dev/null || die "stale persistent-state runtime lock could not be cleared"
    fi
    mkdir "$RECOVERY_LOCK_DIR" || die "could not acquire persistent-state runtime lock for restore recovery"
    printf '%s\n' "$$" > "$RECOVERY_LOCK_DIR/pid"
    chmod 0600 "$RECOVERY_LOCK_DIR/pid"
    recovery_lock_held=1
    trap release_recovery_runtime_lock EXIT

    case "$transaction_state" in
        prepared|mutating)
            state_inventory_remove "$DATA_DIR" || die "interrupted restore left unsafe live state; manual recovery is required"
            state_inventory_copy "$ROLLBACK_DIR" "$DATA_DIR" || die "rollback snapshot could not be installed during recovery"
            state_inventory_copy_markers "$ROLLBACK_DIR" "$DATA_DIR" || die "rollback snapshot markers could not be installed during recovery"
            invalidate_approval_state "$ROLLBACK_DIR"
            sync
            write_transaction_state recovered
            ;;
        committed|recovered)
            ;;
    esac
    if [ -e "$STAGE_DIR" ] || [ -L "$STAGE_DIR" ]; then
        [ -d "$STAGE_DIR" ] && [ ! -L "$STAGE_DIR" ] || die "restore stage path is unsafe"
        state_inventory_validate_tree "$STAGE_DIR" || die "restore stage could not be validated during cleanup"
        rm -rf -- "$STAGE_DIR"
    fi
    rm -rf -- "$TRANSACTION_DIR"
    echo "STATE_RESTORE_RECOVERY state=${transaction_state} rollback_snapshot=${ROLLBACK_DIR}"
    release_recovery_runtime_lock
    trap - EXIT
}

if [ "$RECOVERY_MODE" = true ]; then
    recover_incomplete_restore
    exit 0
fi

BACKUP_DIR=$(cd "$2" 2>/dev/null && pwd -P) || die "backup directory does not exist"

printf '%s' "$STATE_APP_SLUG" | grep -Eq '^[a-z][a-z0-9_]{0,30}$' || die "current state app slug is malformed"
case "$IDENTITY_OVERRIDE" in
    true|false) ;;
    *) die "state restore identity override must be true or false" ;;
esac
case "$CURRENT_VERSION" in
    '') ;;
    *.*.*.*|*.*.*.*-canary.*)
        printf '%s' "$CURRENT_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(-canary\.[0-9]+)?$' ||
            die "current app version is malformed"
        ;;
    *) die "current app version is malformed" ;;
esac
case "$CURRENT_SOURCE_COMMIT" in
    '') ;;
    *) printf '%s' "$CURRENT_SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || die "current app source commit is malformed" ;;
esac

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
SNAPSHOT_APP_SLUG=$(manifest_value app_slug)
SNAPSHOT_TARGET_VERSION=$(manifest_value target_version)
SNAPSHOT_TARGET_SOURCE_COMMIT=$(manifest_value target_source_commit)

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

case "$SNAPSHOT_APP_SLUG" in
    '')
        [ "$IDENTITY_OVERRIDE" = "true" ] || die "backup app identity is missing; set STATE_RESTORE_ALLOW_IDENTITY_OVERRIDE=true for an audited legacy restore"
        ;;
    *)
        printf '%s' "$SNAPSHOT_APP_SLUG" | grep -Eq '^[a-z][a-z0-9_]{0,30}$' || die "backup app identity is malformed"
        ;;
esac
case "$SNAPSHOT_TARGET_VERSION" in
    ''|unknown) ;;
    *.*.*.*|*.*.*.*-canary.*)
        printf '%s' "$SNAPSHOT_TARGET_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(-canary\.[0-9]+)?$' ||
            die "backup target version is malformed"
        ;;
    *) die "backup target version is malformed" ;;
esac
case "$SNAPSHOT_TARGET_SOURCE_COMMIT" in
    ''|unknown) ;;
    *) printf '%s' "$SNAPSHOT_TARGET_SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || die "backup target source commit is malformed" ;;
esac

identity_mismatch=""
if [ -n "$SNAPSHOT_APP_SLUG" ] && [ "$SNAPSHOT_APP_SLUG" != "$STATE_APP_SLUG" ]; then
    identity_mismatch="app_slug"
fi
if [ -n "$CURRENT_VERSION" ] && [ "$SNAPSHOT_TARGET_VERSION" != "" ] &&
    [ "$SNAPSHOT_TARGET_VERSION" != "unknown" ] && [ "$SNAPSHOT_TARGET_VERSION" != "$CURRENT_VERSION" ]; then
    identity_mismatch="${identity_mismatch:-target_version}"
fi
if [ -n "$CURRENT_SOURCE_COMMIT" ] && [ "$SNAPSHOT_TARGET_SOURCE_COMMIT" != "" ] &&
    [ "$SNAPSHOT_TARGET_SOURCE_COMMIT" != "unknown" ] &&
    [ "$SNAPSHOT_TARGET_SOURCE_COMMIT" != "$CURRENT_SOURCE_COMMIT" ]; then
    identity_mismatch="${identity_mismatch:-target_source_commit}"
fi
[ -z "$identity_mismatch" ] || [ "$IDENTITY_OVERRIDE" = "true" ] ||
    die "backup identity does not match the installed app (${identity_mismatch}); set STATE_RESTORE_ALLOW_IDENTITY_OVERRIDE=true for an audited override"

verify_snapshot "$BACKUP_DIR"

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
TRANSACTION_DIR=""
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
    rollback_restored=0
    if [ "$restore_succeeded" -ne 1 ] && [ "$status" -ne 0 ]; then
        if [ "$rollback_ready" -eq 1 ] && state_inventory_remove "$DATA_DIR" &&
            state_inventory_copy "$ROLLBACK_DIR" "$DATA_DIR" &&
            state_inventory_copy_markers "$ROLLBACK_DIR" "$DATA_DIR"; then
            echo "ERROR: restore failed; live state was restored from rollback snapshot $ROLLBACK_DIR" >&2
            rollback_restored=1
        else
            echo "ERROR: restore failed and automatic recovery from $ROLLBACK_DIR also failed" >&2
            status=1
        fi
    fi
    rm -rf -- "$STAGE_DIR" 2>/dev/null || true
    if [ "$rollback_restored" -eq 1 ] && [ -n "$TRANSACTION_DIR" ]; then
        rm -rf -- "$TRANSACTION_DIR" 2>/dev/null || true
    fi
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
    printf 'app_slug=%s\n' "$STATE_APP_SLUG"
    printf 'target_version=%s\n' "${CURRENT_VERSION:-unknown}"
    printf 'target_source_commit=%s\n' "${CURRENT_SOURCE_COMMIT:-unknown}"
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
TRANSACTION_DIR="$MIGRATIONS_DIR/.restore-transaction-${STAMP}-$$"
mkdir "$TRANSACTION_DIR"
chmod 0700 "$TRANSACTION_DIR"
{
    printf 'format=1\n'
    printf 'rollback_dir=%s\n' "$(basename "$ROLLBACK_DIR")"
    printf 'stage_dir=%s\n' "$(basename "$STAGE_DIR")"
    printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$TRANSACTION_DIR/manifest"
chmod 0600 "$TRANSACTION_DIR/manifest"
write_transaction_state prepared

# The journal is durable before any live inventory entry is removed.  Startup
# recovery uses it to distinguish an interrupted restore from an ordinary
# stale runtime lock and reinstalls the verified rollback snapshot.
write_transaction_state mutating
restore_test_kill_if_requested before-remove
state_inventory_remove "$DATA_DIR" || die "current state could not be removed safely"
restore_test_kill_if_requested after-remove
state_inventory_copy "$STAGE_DIR" "$DATA_DIR" || die "staged state could not be installed"
state_inventory_copy_markers "$STAGE_DIR" "$DATA_DIR" || die "staged state markers could not be installed"
restore_test_kill_if_requested after-install

invalidate_approval_state "$ROLLBACK_DIR"
restore_test_kill_if_requested after-invalidate

preserve_current_file() {
    preserve_relative_path="$1"
    preserve_source="$ROLLBACK_DIR/$preserve_relative_path"
    preserve_target="$DATA_DIR/$preserve_relative_path"
    [ -e "$preserve_source" ] || [ -L "$preserve_source" ] || return 0
    [ -f "$preserve_source" ] && [ ! -L "$preserve_source" ] ||
        die "current monotonic state file is unsafe: $preserve_relative_path"
    preserve_parent=$(dirname -- "$preserve_target")
    case "$preserve_parent" in
        "$DATA_DIR") ;;
        "$DATA_DIR"/*)
            preserve_parent_relative=${preserve_parent#"$DATA_DIR"/}
            preserve_parent_cursor="$DATA_DIR"
            preserve_parent_remaining="$preserve_parent_relative"
            # The relative paths passed to this helper are fixed by the
            # broker-owned inventory. Create only missing components, and
            # reject a symlink or non-directory at every boundary.
            while [ -n "$preserve_parent_remaining" ]; do
                case "$preserve_parent_remaining" in
                    */*)
                        preserve_parent_component=${preserve_parent_remaining%%/*}
                        preserve_parent_remaining=${preserve_parent_remaining#*/}
                        ;;
                    *)
                        preserve_parent_component="$preserve_parent_remaining"
                        preserve_parent_remaining=""
                        ;;
                esac
                [ -n "$preserve_parent_component" ] || continue
                preserve_parent_cursor="$preserve_parent_cursor/$preserve_parent_component"
                if [ -e "$preserve_parent_cursor" ] || [ -L "$preserve_parent_cursor" ]; then
                    [ -d "$preserve_parent_cursor" ] && [ ! -L "$preserve_parent_cursor" ] ||
                        die "current monotonic state parent is unsafe: $preserve_parent_cursor"
                else
                    mkdir "$preserve_parent_cursor" ||
                        die "current monotonic state parent could not be created: $preserve_parent_cursor"
                fi
            done
            ;;
        *) die "current monotonic state parent is outside the data directory" ;;
    esac
    [ -d "$preserve_parent" ] && [ ! -L "$preserve_parent" ] ||
        die "current monotonic state parent is unsafe: $preserve_parent"
    if [ -e "$preserve_target" ] || [ -L "$preserve_target" ]; then
        [ -f "$preserve_target" ] && [ ! -L "$preserve_target" ] ||
            die "restored monotonic state file is unsafe: $preserve_relative_path"
    fi
    preserve_tmp="${preserve_target}.preserve.$$"
    [ ! -e "$preserve_tmp" ] && [ ! -L "$preserve_tmp" ] ||
        die "monotonic state temporary path is occupied: $preserve_relative_path"
    cp -a -- "$preserve_source" "$preserve_tmp" ||
        die "current monotonic state could not be staged: $preserve_relative_path"
    mv -f -- "$preserve_tmp" "$preserve_target" ||
        die "current monotonic state could not be installed: $preserve_relative_path"
}

preserve_current_tree() {
    preserve_relative_path="$1"
    preserve_source="$ROLLBACK_DIR/$preserve_relative_path"
    preserve_target="$DATA_DIR/$preserve_relative_path"
    [ -e "$preserve_source" ] || [ -L "$preserve_source" ] || return 0
    [ -d "$preserve_source" ] && [ ! -L "$preserve_source" ] ||
        die "current monotonic state tree is unsafe: $preserve_relative_path"
    state_inventory_validate_tree "$preserve_source" ||
        die "current monotonic state tree could not be validated: $preserve_relative_path"
    if [ -e "$preserve_target" ] || [ -L "$preserve_target" ]; then
        [ -d "$preserve_target" ] && [ ! -L "$preserve_target" ] ||
            die "restored monotonic state tree is unsafe: $preserve_relative_path"
    else
        mkdir "$preserve_target" ||
            die "restored monotonic state tree could not be created: $preserve_relative_path"
    fi
    state_inventory_validate_tree "$preserve_target" ||
        die "restored monotonic state tree could not be validated: $preserve_relative_path"
    # Both source and target trees were validated above. Copying the contents
    # in one bounded operation avoids recursive shell state/variable aliasing;
    # current files replace same-named restored files while restored-only
    # history remains present.
    cp -a -- "$preserve_source"/. "$preserve_target"/ ||
        die "current monotonic state tree could not be merged: $preserve_relative_path"
}

# Restore must not rewind state that limits future capability/provider work or
# proves what already happened. Keep the current snapshot's durable quotas,
# reservations, completed admissions, audit rows, and abuse-rate state. The
# ordinary backup still supplies planner data and non-monotonic configuration;
# actionable approval state below is invalidated separately.
preserve_current_file capability/quota.json
preserve_current_file capability/read-quota.json
preserve_current_file capability/telegram-approval-rate.json
preserve_current_file provider/quota.json
preserve_current_file audit/planner/.quota.json
preserve_current_file capability/telegram-conflict
preserve_current_file capability/telegram-conflict.token
preserve_current_tree capability/action-admissions
preserve_current_tree audit

clear_transient_runtime_lock() {
    transient_lock="$1"
    if [ -e "$transient_lock" ] || [ -L "$transient_lock" ]; then
        [ -d "$transient_lock" ] && [ ! -L "$transient_lock" ] ||
            die "transient runtime lock is unsafe: $transient_lock"
        transient_owner="${transient_lock}/owner"
        if [ -e "$transient_owner" ] || [ -L "$transient_owner" ]; then
            [ -f "$transient_owner" ] && [ ! -L "$transient_owner" ] ||
                die "transient runtime lock owner is unsafe: $transient_lock"
            transient_pid=$(cat "$transient_owner" 2>/dev/null || true)
            case "$transient_pid" in
                ''|*[!0-9]*) die "transient runtime lock owner is invalid: $transient_lock" ;;
            esac
            kill -0 "$transient_pid" 2>/dev/null &&
                die "transient runtime lock is active: $transient_lock"
            rm -f -- "$transient_owner"
        fi
        rmdir "$transient_lock" 2>/dev/null ||
            die "transient runtime lock could not be cleared: $transient_lock"
    fi
}

# Locks are coordination state, not monotonic evidence. Do not let a backup
# or preserved audit tree resurrect a lock from a process that no longer
# exists. The fixed paths and empty-directory requirement keep this cleanup
# fail-closed and prevent recursive deletion through planner-controlled data.
for transient_lock in \
    "$DATA_DIR/capability/.quota.lock" \
    "$DATA_DIR/capability/.read-quota.lock" \
    "$DATA_DIR/capability/.telegram-approval-rate.lock" \
    "$DATA_DIR/capability/.telegram-approval-admission.lock" \
    "$DATA_DIR/provider/.ledger.lock" \
    "$DATA_DIR/audit/.lock" \
    "$DATA_DIR/audit/planner/.quota.lock"; do
    clear_transient_runtime_lock "$transient_lock"
done

if [ "$IDENTITY_OVERRIDE" = "true" ] || [ -n "$identity_mismatch" ]; then
    [ -d "$AUDIT_DIR" ] && [ ! -L "$AUDIT_DIR" ] || die "audit directory is unavailable for identity override"
    override_tmp="${AUDIT_DIR}/.state-restore-override.$$"
    jq -nc --arg app "$STATE_APP_SLUG" --arg snapshot_app "$SNAPSHOT_APP_SLUG" \
        --arg version "$CURRENT_VERSION" --arg snapshot_version "$SNAPSHOT_TARGET_VERSION" \
        --arg source_commit "$CURRENT_SOURCE_COMMIT" --arg snapshot_source_commit "$SNAPSHOT_TARGET_SOURCE_COMMIT" \
        --argjson epoch "$restore_epoch" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{kind:"state_restore_identity_override",app_slug:$app,snapshot_app_slug:$snapshot_app,
          current_version:$version,snapshot_target_version:$snapshot_version,
          current_source_commit:$source_commit,snapshot_target_source_commit:$snapshot_source_commit,
          restore_epoch:$epoch,created_at:$ts}' > "$override_tmp" || die "identity override audit could not be rendered"
    chown root:root "$override_tmp"
    chmod 0600 "$override_tmp"
    cat "$override_tmp" >> "$AUDIT_DIR/$(date -u +%Y-%m-%d).jsonl" || die "identity override audit could not be persisted"
    rm -f "$override_tmp"
fi
if [ "${STATE_RESTORE_TEST_FAIL_AFTER_MUTATION:-false}" = "true" ]; then
    die "test failure injected after live-state replacement"
fi
restore_test_kill_if_requested before-commit
sync
write_transaction_state committed
restore_succeeded=1
restore_test_kill_if_requested after-commit
rm -rf -- "$STAGE_DIR" "$TRANSACTION_DIR" 2>/dev/null || true
printf 'STATE_RESTORE backup=%s rollback_snapshot=%s restored_schema=%s restored_version=%s\n' \
    "$BACKUP_DIR" "$ROLLBACK_DIR" "${OLD_SCHEMA:-legacy}" "$OLD_VERSION"
