# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
FROM docker.io/library/alpine:3.24.4@sha256:93b41ef40b1677fce8fcc64ff4af09daddfacf5040afde618bc46c1e2d1cc7d4

ARG TARGETARCH
ARG APP_SOURCE_REVISION=local-uncommitted
ARG APP_VERSION=4.0.0.0

LABEL org.opencontainers.image.title="ZeroClaw Home Assistant app" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.source="https://github.com/Nafjan/zeroclaw-ha-addon" \
      org.opencontainers.image.revision="${APP_SOURCE_REVISION}" \
      org.opencontainers.image.base.name="docker.io/library/alpine:3.24.4@sha256:93b41ef40b1677fce8fcc64ff4af09daddfacf5040afde618bc46c1e2d1cc7d4" \
      org.opencontainers.image.upstream.revision="99bd353c756f4e64f381cfe9c3002ebff32f3055" \
      io.hass.version="${APP_VERSION}" \
      io.hass.type="app" \
      io.hass.arch="aarch64" \
      io.zeroclaw.app.source.revision="${APP_SOURCE_REVISION}" \
      io.zeroclaw.runtime.source.repository="https://github.com/zeroclaw-labs/zeroclaw" \
      io.zeroclaw.runtime.source.revision="99bd353c756f4e64f381cfe9c3002ebff32f3055" \
      io.zeroclaw.runtime.version="0.8.7" \
      io.zeroclaw.runtime.target="aarch64-unknown-linux-musl" \
      io.zeroclaw.runtime.release-archive-sha256="eab013d82ed333689698a328b104ecaf5f5a76b046af30ab25482f0181518f3d" \
      io.zeroclaw.runtime.binary-sha256="f33279b7b42b54e56ea9dd1cc722e6d09e3c05533b6f70147d1f6d4dc204972f"

RUN set -eu; \
    test "$TARGETARCH" = arm64; \
    printf '%s' "$APP_SOURCE_REVISION" | grep -Eq '^(local-uncommitted(-dirty)?|[0-9a-f]{40}(-dirty-local-qualification)?)$' || { \
        echo 'APP_SOURCE_REVISION must be a full commit or an explicit local label' >&2; exit 1; \
    }; \
    printf '%s' "$APP_VERSION" | grep -Eq '^(4\.0\.0\.0|4\.0\.0-dev\.g[0-9a-f]{12}\.[0-9]+\.[1-9][0-9]*)$' || { \
        echo 'APP_VERSION must be stable 4.0.0.0 or a validated 4.0.0-dev candidate version' >&2; exit 1; \
    }; \
    apk add --no-cache \
        ca-certificates=20261020-r0 \
        python3=3.14.10-r1 \
        su-exec=0.3-r0; \
    addgroup -S -g 1000 zeroclaw; \
    adduser -S -D -H -u 1000 -G zeroclaw -h /data/native zeroclaw; \
    mkdir -p /data /opt/zeroclaw/native /usr/share/licenses/zeroclaw-runtime; \
    chown root:zeroclaw /data; \
    chmod 0750 /data /opt/zeroclaw /opt/zeroclaw/native

# BuildKit verifies each remote file before it is placed in the image. The
# runtime archive and source license files are pinned to the upstream 0.8.7
# source/release; the extracted executable is checked again below.
ADD --checksum=sha256:eab013d82ed333689698a328b104ecaf5f5a76b046af30ab25482f0181518f3d \
    https://github.com/zeroclaw-labs/zeroclaw/releases/download/v0.8.7/zeroclaw-aarch64-unknown-linux-musl.tar.gz \
    /tmp/zeroclaw-aarch64-unknown-linux-musl.tar.gz
ADD --checksum=sha256:69ad6d0b3c96424e823dd77c3625682fefbf7cc2871a624fa38f5d762c4bcc94 \
    https://raw.githubusercontent.com/zeroclaw-labs/zeroclaw/99bd353c756f4e64f381cfe9c3002ebff32f3055/LICENSE-MIT \
    /usr/share/licenses/zeroclaw-runtime/LICENSE-MIT
ADD --checksum=sha256:62c7a1e35f56406896d7aa7ca52d0cc0d272ac022b5d2796e7d6905db8a3636a \
    https://raw.githubusercontent.com/zeroclaw-labs/zeroclaw/99bd353c756f4e64f381cfe9c3002ebff32f3055/LICENSE-APACHE \
    /usr/share/licenses/zeroclaw-runtime/LICENSE-APACHE
ADD --checksum=sha256:e4c0a853eb087c74679d9a1dd831101f19441ba05814cf37ccffedcb52ac368f \
    https://raw.githubusercontent.com/zeroclaw-labs/zeroclaw/99bd353c756f4e64f381cfe9c3002ebff32f3055/NOTICE \
    /usr/share/licenses/zeroclaw-runtime/NOTICE

RUN python3 - <<'PY'
import hashlib
import os
from pathlib import Path, PurePosixPath
import stat
import tarfile

archive_path = Path("/tmp/zeroclaw-aarch64-unknown-linux-musl.tar.gz")
destination = Path("/usr/local/bin/zeroclaw")
expected = "f33279b7b42b54e56ea9dd1cc722e6d09e3c05533b6f70147d1f6d4dc204972f"
try:
    with tarfile.open(archive_path, mode="r:gz") as archive:
        candidates = [member for member in archive.getmembers()
                      if PurePosixPath(member.name).name == "zeroclaw"]
        if len(candidates) != 1 or not candidates[0].isfile():
            raise SystemExit("official archive must contain exactly one regular zeroclaw binary")
        member = candidates[0]
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or member.size > 256 * 1024 * 1024:
            raise SystemExit("official archive contains an unsafe zeroclaw path or size")
        source = archive.extractfile(member)
        if source is None:
            raise SystemExit("official archive binary could not be read")
        payload = source.read(256 * 1024 * 1024 + 1)
except (OSError, tarfile.TarError) as error:
    raise SystemExit("official runtime archive could not be read safely") from error

digest = hashlib.sha256(payload).hexdigest()
if digest != expected:
    raise SystemExit("official runtime executable digest did not match the pinned 0.8.7 binary")
with destination.open("xb") as output:
    output.write(payload)
os.chmod(destination, 0o555)
archive_path.unlink()
PY
RUN printf '%s  %s\n' \
        '69ad6d0b3c96424e823dd77c3625682fefbf7cc2871a624fa38f5d762c4bcc94' \
        /usr/share/licenses/zeroclaw-runtime/LICENSE-MIT | sha256sum -c - \
    && printf '%s  %s\n' \
        '62c7a1e35f56406896d7aa7ca52d0cc0d272ac022b5d2796e7d6905db8a3636a' \
        /usr/share/licenses/zeroclaw-runtime/LICENSE-APACHE | sha256sum -c - \
    && printf '%s  %s\n' \
        'e4c0a853eb087c74679d9a1dd831101f19441ba05814cf37ccffedcb52ac368f' \
        /usr/share/licenses/zeroclaw-runtime/NOTICE | sha256sum -c - \
    && chmod 0444 /usr/share/licenses/zeroclaw-runtime/LICENSE-MIT \
        /usr/share/licenses/zeroclaw-runtime/LICENSE-APACHE \
        /usr/share/licenses/zeroclaw-runtime/NOTICE

COPY --chown=root:root native/entrypoint.sh /usr/local/bin/zeroclaw-entrypoint
COPY --chown=root:root native/config.py /opt/zeroclaw/native/config.py
COPY --chown=root:root native/migrate.py /opt/zeroclaw/native/migrate.py
COPY --chown=root:root native/ha_preflight.py /opt/zeroclaw/native/ha_preflight.py
RUN chmod 0555 /usr/local/bin/zeroclaw-entrypoint \
    && chmod 0444 /opt/zeroclaw/native/config.py \
        /opt/zeroclaw/native/migrate.py \
        /opt/zeroclaw/native/ha_preflight.py

EXPOSE 42617/tcp

HEALTHCHECK --interval=30s --timeout=4s --start-period=45s --retries=3 \
    CMD ["su-exec", "zeroclaw:zeroclaw", "env", "-i", "HOME=/data/native", "PATH=/usr/local/bin:/usr/bin:/bin", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:42617/health', timeout=2).read(1)"]

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/zeroclaw-entrypoint"]
