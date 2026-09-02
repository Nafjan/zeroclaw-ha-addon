# Pin the multi-arch manifest; update deliberately with a digest review.
FROM ghcr.io/home-assistant/base:3.24@sha256:94ff231402a5e7ad2a82e261ad5fa4ffae7d7bb095c3febb2edbdf309c9b6aca

ARG BUILD_VERSION
ARG BUILD_ARCH
ARG ZEROCLAW_SHA256
ARG ZEROCLAW_SOURCE_COMMIT
ARG ADDON_SOURCE_COMMIT
ARG ZEROCLAW_SOURCE_DATE_EPOCH
ARG ZEROCLAW_LLVM_RNG_SEED
ARG REQUIRE_VERIFIED_ARTIFACT
ARG ZEROCLAW_STATE_SCHEMA
ARG ALLOW_TEST_PROVIDER_OVERRIDE=false

# Every value that influences release identity or provenance is mandatory.  An
# out-of-band build must fail before it can produce an installable image.
RUN set -eu; \
    printf '%s' "${BUILD_VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; \
    printf '%s' "${BUILD_ARCH}" | grep -Eq '^aarch64$'; \
    printf '%s' "${ZEROCLAW_SHA256}" | grep -Eq '^[0-9a-f]{64}$'; \
    printf '%s' "${ZEROCLAW_SOURCE_COMMIT}" | grep -Eq '^[0-9a-f]{40}$'; \
    printf '%s' "${ADDON_SOURCE_COMMIT}" | grep -Eq '^[0-9a-f]{40}$'; \
    printf '%s' "${ZEROCLAW_SOURCE_DATE_EPOCH}" | grep -Eq '^[1-9][0-9]+$'; \
    printf '%s' "${ZEROCLAW_LLVM_RNG_SEED}" | grep -Eq '^[0-9]+$'; \
    printf '%s' "${ZEROCLAW_STATE_SCHEMA}" | grep -Eq '^[1-9][0-9]{0,2}$'; \
    case "${REQUIRE_VERIFIED_ARTIFACT}" in true|false) : ;; *) exit 1 ;; esac; \
    case "${ALLOW_TEST_PROVIDER_OVERRIDE}" in true|false) : ;; *) exit 1 ;; esac

ENV ZEROCLAW_ADDON_VERSION="${BUILD_VERSION}"
ENV ZEROCLAW_STATE_SCHEMA="${ZEROCLAW_STATE_SCHEMA}"
ENV ZEROCLAW_ADDON_SOURCE_COMMIT="${ADDON_SOURCE_COMMIT}"

LABEL \
    io.hass.version="${BUILD_VERSION}" \
    io.hass.type="app" \
    io.hass.arch="${BUILD_ARCH}" \
    org.opencontainers.image.title="ZeroClaw Home Assistant app" \
    org.opencontainers.image.version="${BUILD_VERSION}" \
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
COPY state-schema /usr/share/zeroclaw/state-schema
RUN echo "${ZEROCLAW_SHA256}  /usr/local/bin/zeroclaw" | sha256sum -c - \
    && test "$(jq -r '.sha256' /usr/share/zeroclaw/binary-manifest.json)" = "${ZEROCLAW_SHA256}" \
    && test "$(jq -r '.source_commit' /usr/share/zeroclaw/binary-manifest.json)" = "${ZEROCLAW_SOURCE_COMMIT}" \
    && test "$(jq -r '.source_date_epoch' /usr/share/zeroclaw/binary-manifest.json)" = "${ZEROCLAW_SOURCE_DATE_EPOCH}" \
    && test "$(jq -r '.llvm_rng_seed' /usr/share/zeroclaw/binary-manifest.json)" = "${ZEROCLAW_LLVM_RNG_SEED}" \
    && test "$(tr -d '\\r\\n' < /usr/share/zeroclaw/state-schema)" = "${ZEROCLAW_STATE_SCHEMA}" \
    && case "${REQUIRE_VERIFIED_ARTIFACT}" in true) test "$(jq -r '.artifact_status' /usr/share/zeroclaw/binary-manifest.json)" = "verified" ;; false) : ;; esac \
    && chmod +x /usr/local/bin/zeroclaw

# The deterministic provider endpoint used by the arm64 acceptance test is a
# test-image capability, never a runtime option. Release builds leave this
# marker absent, so ambient SMOKE_* or ZEROCLAW_* variables cannot redirect a
# production broker to an arbitrary endpoint.
RUN if [ "${ALLOW_TEST_PROVIDER_OVERRIDE}" = "true" ]; then \
        printf '%s\n' 'zeroclaw-ci-test-hooks-v1' > /usr/share/zeroclaw/test-hooks-enabled; \
        chmod 0444 /usr/share/zeroclaw/test-hooks-enabled; \
    else \
        rm -f /usr/share/zeroclaw/test-hooks-enabled; \
    fi

# Policy library — pure-shell verdict decider, covered by bats tests
COPY lib/ /opt/zeroclaw/lib/
RUN chmod +x /opt/zeroclaw/lib/*.sh

COPY run.sh /
RUN chmod +x /run.sh

RUN mkdir -p /data/memory /data/logs /data/tools

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD /opt/zeroclaw/lib/healthcheck.sh

CMD ["/run.sh"]
