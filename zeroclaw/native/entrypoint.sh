#!/bin/sh
set -eu

fail() {
    printf 'ZeroClaw native startup: %s\n' "$1" >&2
    exit 1
}

DATA_DIR=/data
NATIVE_DIR=/data/native
OPTIONS_FILE=/data/options.json

[ "$(id -u)" = 0 ] || fail 'entrypoint must start as root to prepare persistent data safely'
[ -d "$DATA_DIR" ] && [ ! -L "$DATA_DIR" ] || fail '/data is missing or is not a real directory'
[ "$(stat -c '%u' "$DATA_DIR")" = 0 ] || fail '/data must remain root-owned'
[ -f "$OPTIONS_FILE" ] && [ ! -L "$OPTIONS_FILE" ] || fail 'Home Assistant options.json is missing or is not a regular file'
[ "$(stat -c '%u' "$OPTIONS_FILE")" = 0 ] || fail 'Home Assistant options.json must remain root-owned'
chown 0:0 "$OPTIONS_FILE"
chmod 0600 "$OPTIONS_FILE"
[ "$(stat -c '%u:%g:%a' "$OPTIONS_FILE")" = 0:0:600 ] || fail 'Home Assistant options.json must remain root-private'

# Let the daemon traverse the data root without granting it write access to
# options, migration receipts, or legacy state stored alongside native data.
chown 0:1000 "$DATA_DIR"
chmod 0750 "$DATA_DIR"

env -i HOME=/root PATH=/usr/local/bin:/usr/bin:/bin \
    python3 /opt/zeroclaw/native/migrate.py prepare "$DATA_DIR" ||
    fail 'persistent data preparation failed'

# A prior app version may have left /data/workspace writable by UID 1000.
# Keep that legacy tree inactive and inaccessible to the native daemon. Seal
# only the directory itself; migration has already validated its contents and
# rollback snapshots remain root-private under /data.
if ! env -i HOME=/root PATH=/usr/local/bin:/usr/bin:/bin python3 - <<'PY'
import os
import stat

legacy = "/data/workspace"
try:
    before = os.lstat(legacy)
except FileNotFoundError:
    raise SystemExit(0)
if not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode):
    raise SystemExit("legacy workspace is not a real directory")
flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(legacy, flags)
try:
    current = os.fstat(descriptor)
    if (not stat.S_ISDIR(current.st_mode)
            or (current.st_dev, current.st_ino) != (before.st_dev, before.st_ino)):
        raise SystemExit("legacy workspace changed while opening")
    os.fchown(descriptor, 0, 0)
    os.fchmod(descriptor, 0o700)
    sealed = os.fstat(descriptor)
    if (sealed.st_uid, sealed.st_gid, stat.S_IMODE(sealed.st_mode)) != (0, 0, 0o700):
        raise SystemExit("legacy workspace could not be sealed")
finally:
    os.close(descriptor)
PY
then
    fail 'legacy workspace could not be sealed safely'
fi

[ -d "$NATIVE_DIR" ] && [ ! -L "$NATIVE_DIR" ] || fail 'migration did not create a real /data/native directory'

# The migration helper has already rejected links and special files. Recheck
# every object without following links before assigning only this native tree
# to the unprivileged daemon account.
if ! env -i HOME=/root PATH=/usr/local/bin:/usr/bin:/bin \
    python3 - "$NATIVE_DIR" <<'PY'
import os
import stat
import sys

root = sys.argv[1]
root_stat = os.lstat(root)
if not stat.S_ISDIR(root_stat.st_mode) or stat.S_ISLNK(root_stat.st_mode):
    raise SystemExit("native data root is not a real directory")

for current, directories, files in os.walk(root, topdown=True, followlinks=False):
    for name in directories:
        path = os.path.join(current, name)
        mode = os.lstat(path).st_mode
        if not stat.S_ISDIR(mode) or stat.S_ISLNK(mode):
            raise SystemExit("native data tree contains a non-directory path")
        os.chown(path, 1000, 1000, follow_symlinks=False)
    for name in files:
        path = os.path.join(current, name)
        relative = os.path.relpath(path, root).replace(os.sep, "/")
        mode = os.lstat(path).st_mode
        if relative == "data/daemon.sock" and stat.S_ISSOCK(mode):
            # ZeroClaw may leave its known RPC socket behind after SIGKILL.
            # The migration helper permits exactly this path, and upstream
            # removes it while starting the next daemon.
            os.chown(path, 1000, 1000, follow_symlinks=False)
            continue
        if not stat.S_ISREG(mode) or stat.S_ISLNK(mode):
            raise SystemExit("native data tree contains a non-regular file")
        os.chown(path, 1000, 1000, follow_symlinks=False)
    os.chown(current, 1000, 1000, follow_symlinks=False)

os.chmod(root, 0o700, follow_symlinks=False)
PY
then
    fail 'native data ownership validation failed'
fi

env -i HOME=/root PATH=/usr/local/bin:/usr/bin:/bin \
    python3 /opt/zeroclaw/native/config.py \
        --options "$OPTIONS_FILE" \
        --output "$NATIVE_DIR/config.toml" ||
    fail 'native configuration generation failed'

env -i HOME=/root PATH=/usr/local/bin:/usr/bin:/bin \
    python3 /opt/zeroclaw/native/ha_preflight.py --config "$NATIVE_DIR/config.toml" ||
    fail 'native Home Assistant MCP preflight failed'

[ -f "$NATIVE_DIR/config.toml" ] && [ ! -L "$NATIVE_DIR/config.toml" ] || fail 'native config is missing or is not a regular file'
chown -h 1000:1000 "$NATIVE_DIR/config.toml"
[ "$(stat -c '%u:%g:%a' "$NATIVE_DIR/config.toml")" = 1000:1000:600 ] || fail 'native config must be owned by zeroclaw:zeroclaw with mode 0600'
[ "$(stat -c '%u:%g:%a' "$NATIVE_DIR")" = 1000:1000:700 ] || fail 'native data root permissions are not private'

exec su-exec zeroclaw:zeroclaw env -i \
    HOME=/data/native \
    PATH=/usr/local/bin:/usr/bin:/bin \
    /usr/local/bin/zeroclaw --config-dir /data/native daemon
