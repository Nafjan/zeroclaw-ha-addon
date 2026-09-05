#!/bin/sh
# Shared, schema-governed persistent state inventory for migration and restore.
# Keep migrations outside this inventory: a snapshot must never contain older
# snapshots recursively.

STATE_INVENTORY_MAX_NODES=40000
STATE_INVENTORY_MAX_BYTES=268435456

state_inventory_paths() {
    printf '%s\n' \
        brain.db \
        config.toml \
        options.json \
        memory \
        logs \
        undo \
        provider \
        capability \
        approval-receipts \
        approved \
        audit \
        pending \
        routines \
        tools
}

state_inventory_validate_tree() {
    source_path="$1"
    if [ -L "$source_path" ]; then
        echo "ERROR: persistent state path is a symlink: $source_path" >&2
        return 1
    fi
    [ -e "$source_path" ] || return 0
    if [ -e "$source_path" ] && find "$source_path" -type l -print -quit | grep -q .; then
        echo "ERROR: persistent state tree contains a symlink: $source_path" >&2
        return 1
    fi
    special_path=$(find "$source_path" ! -type f ! -type d -print -quit 2>/dev/null) || {
        echo "ERROR: persistent state tree could not be inspected: $source_path" >&2
        return 1
    }
    [ -z "$special_path" ] || {
        echo "ERROR: persistent state tree contains a non-regular entry: $special_path" >&2
        return 1
    }
    node_count=$(find "$source_path" -print 2>/dev/null | wc -l | tr -d ' ')
    case "$node_count" in
        ''|*[!0-9]*)
            echo "ERROR: persistent state node count could not be measured: $source_path" >&2
            return 1
            ;;
    esac
    [ "$node_count" -le "$STATE_INVENTORY_MAX_NODES" ] || {
        echo "ERROR: persistent state tree exceeds the node limit: $source_path" >&2
        return 1
    }
    total_bytes=$(find "$source_path" -type f -exec wc -c {} \; 2>/dev/null |
        awk -v limit="$STATE_INVENTORY_MAX_BYTES" '{ total += $1; if (total > limit) exit 1 } END { print total + 0 }') || {
        echo "ERROR: persistent state tree exceeds the byte limit: $source_path" >&2
        return 1
    }
    case "$total_bytes" in
        ''|*[!0-9]*)
            echo "ERROR: persistent state byte count could not be measured: $source_path" >&2
            return 1
            ;;
    esac
}

state_inventory_copy_path() {
    source_path="$1"
    target_path="$2"
    state_inventory_validate_tree "$source_path" || return 1
    if [ -e "$source_path" ]; then
        mkdir -p "$(dirname "$target_path")"
        cp -a -- "$source_path" "$target_path"
    fi
}

state_inventory_copy() {
    source_root="$1"
    target_root="$2"
    mkdir -p "$target_root"

    set -- $(state_inventory_paths)
    for relative_path do
        state_inventory_copy_path \
            "$source_root/$relative_path" \
            "$target_root/$relative_path" || return 1
    done

    source_workspace="$source_root/workspace"
    if [ -L "$source_workspace" ]; then
        echo "ERROR: workspace is a symlink: $source_workspace" >&2
        return 1
    fi
    if [ -e "$source_workspace" ]; then
        [ -d "$source_workspace" ] || {
            echo "ERROR: workspace is not a directory: $source_workspace" >&2
            return 1
        }
        state_inventory_validate_tree "$source_workspace" || return 1
        for session_path in "$source_workspace"/sessions*; do
            [ -e "$session_path" ] || continue
            state_inventory_copy_path "$session_path" \
                "$target_root/workspace/$(basename "$session_path")" || return 1
        done
    fi
}

state_inventory_copy_markers() {
    source_root="$1"
    target_root="$2"
    state_inventory_copy_path "$source_root/.state-schema" "$target_root/.state-schema" || return 1
    state_inventory_copy_path "$source_root/.state-version" "$target_root/.state-version" || return 1

    source_workspace="$source_root/workspace"
    if [ -L "$source_workspace" ]; then
        echo "ERROR: workspace is a symlink: $source_workspace" >&2
        return 1
    fi
    if [ -e "$source_workspace" ]; then
        [ -d "$source_workspace" ] || {
            echo "ERROR: workspace is not a directory: $source_workspace" >&2
            return 1
        }
        state_inventory_copy_path "$source_workspace/.last_version" \
            "$target_root/workspace/.last_version" || return 1
    fi
}

state_inventory_remove() {
    data_root="$1"

    set -- $(state_inventory_paths)
    for relative_path do
        source_path="$data_root/$relative_path"
        state_inventory_validate_tree "$source_path" || return 1
    done
    state_inventory_validate_tree "$data_root/workspace" || return 1

    for relative_path do
        rm -rf -- "$data_root/$relative_path"
    done
    if [ -e "$data_root/workspace" ]; then
        for session_path in "$data_root/workspace"/sessions*; do
            [ -e "$session_path" ] || continue
            rm -rf -- "$session_path"
        done
    fi
    rm -f -- \
        "$data_root/.state-schema" \
        "$data_root/.state-version" \
        "$data_root/workspace/.last_version"
}
