# Pin the multi-arch manifest; update deliberately with a digest review.
FROM ghcr.io/home-assistant/base:3.24@sha256:94ff231402a5e7ad2a82e261ad5fa4ffae7d7bb095c3febb2edbdf309c9b6aca

ARG BUILD_VERSION=3.1.4.0
ARG BUILD_ARCH=aarch64
ARG ZEROCLAW_SHA256
ARG ZEROCLAW_SOURCE_COMMIT
ARG ADDON_SOURCE_COMMIT=unknown
ARG ZEROCLAW_SOURCE_DATE_EPOCH
ARG ZEROCLAW_LLVM_RNG_SEED
ARG REQUIRE_VERIFIED_ARTIFACT=false

LABEL \
    io.hass.version="${BUILD_VERSION}" \
    io.hass.type="app" \
    io.hass.arch="${BUILD_ARCH}" \
    org.opencontainers.image.title="ZeroClaw Home Assistant app" \
    org.opencontainers.image.source="https://github.com/Nafjan/zeroclaw-ha-addon" \
    org.opencontainers.image.revision="${ADDON_SOURCE_COMMIT}" \
    org.opencontainers.image.upstream.revision="${ZEROCLAW_SOURCE_COMMIT}" \
    org.opencontainers.image.build.source-date-epoch="${ZEROCLAW_SOURCE_DATE_EPOCH}" \
    org.opencontainers.image.build.llvm-rng-seed="${ZEROCLAW_LLVM_RNG_SEED}"

# Static musl binary — no runtime dependencies needed
RUN apk add --no-cache \
    ca-certificates=20260611-r0 \
    curl=8.20.0-r1 \
    jq=1.8.1-r0 \
    yq-go=4.53.3-r0 \
    findutils=4.10.0-r1 \
    coreutils=9.11-r0 \
    su-exec=0.3-r0 \
    && addgroup -S zeroclaw \
    && adduser -S -D -H -s /sbin/nologin -G zeroclaw zeroclaw

COPY zeroclaw-bin /usr/local/bin/zeroclaw
COPY binary-manifest.json /usr/share/zeroclaw/binary-manifest.json
RUN echo "${ZEROCLAW_SHA256}  /usr/local/bin/zeroclaw" | sha256sum -c - \
    && test "$(jq -r '.sha256' /usr/share/zeroclaw/binary-manifest.json)" = "${ZEROCLAW_SHA256}" \
    && test "$(jq -r '.source_commit' /usr/share/zeroclaw/binary-manifest.json)" = "${ZEROCLAW_SOURCE_COMMIT}" \
    && test "$(jq -r '.source_date_epoch' /usr/share/zeroclaw/binary-manifest.json)" = "${ZEROCLAW_SOURCE_DATE_EPOCH}" \
    && test "$(jq -r '.llvm_rng_seed' /usr/share/zeroclaw/binary-manifest.json)" = "${ZEROCLAW_LLVM_RNG_SEED}" \
    && if [ "${REQUIRE_VERIFIED_ARTIFACT}" = "true" ]; then test "$(jq -r '.artifact_status' /usr/share/zeroclaw/binary-manifest.json)" = "verified"; fi \
    && chmod +x /usr/local/bin/zeroclaw

# Policy library — pure-shell verdict decider, covered by bats tests
COPY lib/ /opt/zeroclaw/lib/
RUN chmod +x /opt/zeroclaw/lib/*.sh

COPY run.sh /
RUN chmod +x /run.sh

RUN mkdir -p /data/memory /data/logs /data/tools

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD test ! -e /data/capability/telegram-conflict && \
        curl -fsS --max-time 3 http://127.0.0.1:42617/health >/dev/null || exit 1

CMD ["/run.sh"]
