ARG BUILD_FROM
FROM ${BUILD_FROM}

# The pre-built binary is linked against glibc.
# HAOS Alpine base uses musl, so install glibc compatibility layer.
RUN apk add --no-cache \
    ca-certificates \
    curl \
    gcompat

# gcompat provides a full glibc shim for musl, including fcntl64 and __res_init

# Copy the pre-built aarch64 binary
COPY zeroclaw /usr/local/bin/zeroclaw
RUN chmod +x /usr/local/bin/zeroclaw

# Copy startup script
COPY run.sh /
RUN chmod +x /run.sh

# Create data directories
RUN mkdir -p /data/memory /data/logs /data/tools

# Copy config files
COPY config/ /data/

# Non-root execution
RUN addgroup -g 1000 zeroclaw && \
    adduser -u 1000 -G zeroclaw -D zeroclaw && \
    chown -R zeroclaw:zeroclaw /data

USER zeroclaw

# Health check — verify process is running
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD pgrep zeroclaw || exit 1

CMD ["/run.sh"]
