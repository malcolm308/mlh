FROM ghcr.io/maplibre/martin:latest

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
      wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV MBTILES_URL=""
ENV MBTILES_SHA256=""
ENV MBTILES_PATH=/data/cuba.mbtiles

COPY tileserver/styles /styles
COPY tileserver/fonts /fonts
COPY martin/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

EXPOSE 10000

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD wget -q -O /dev/null "http://127.0.0.1:${PORT:-10000}/health" || exit 1

ENTRYPOINT ["/entrypoint.sh"]
