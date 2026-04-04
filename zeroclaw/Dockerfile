ARG BUILD_FROM
FROM ${BUILD_FROM}

# Debian base has real glibc — no musl/Alpine compatibility issues
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Copy the pre-built aarch64 binary (glibc-linked)
COPY zeroclaw /usr/local/bin/zeroclaw
RUN chmod +x /usr/local/bin/zeroclaw

# Copy startup script
COPY run.sh /
RUN chmod +x /run.sh

# Create data directories
RUN mkdir -p /data/memory /data/logs /data/tools

# Copy config files
COPY config/ /data/

# Health check
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD pgrep zeroclaw || exit 1

CMD ["/run.sh"]
