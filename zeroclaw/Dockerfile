FROM ghcr.io/home-assistant/aarch64-base-debian:bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    procps \
    && rm -rf /var/lib/apt/lists/*

COPY zeroclaw /usr/local/bin/zeroclaw
RUN chmod +x /usr/local/bin/zeroclaw

COPY run.sh /
RUN chmod +x /run.sh

RUN mkdir -p /data/memory /data/logs /data/tools

COPY config/ /data/

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD pgrep zeroclaw || exit 1

CMD ["/run.sh"]
