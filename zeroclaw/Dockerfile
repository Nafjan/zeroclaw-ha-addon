ARG BUILD_FROM
FROM ${BUILD_FROM}

# Static musl binary — no runtime dependencies needed
RUN apk add --no-cache ca-certificates curl jq yq findutils coreutils

COPY zeroclaw-bin /usr/local/bin/zeroclaw
RUN chmod +x /usr/local/bin/zeroclaw

COPY run.sh /
RUN chmod +x /run.sh

RUN mkdir -p /data/memory /data/logs /data/tools
COPY data-config/ /data/

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD pgrep zeroclaw || exit 1

CMD ["/run.sh"]
