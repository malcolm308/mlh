#!/bin/sh
set -e

if [ -z "$MBTILES_URL" ]; then
  echo "ERROR: MBTILES_URL no configurada"
  exit 1
fi

PORT="${PORT:-10000}"

mkdir -p /data
echo "Descargando $MBTILES_URL..."
wget -q --show-progress -O "$MBTILES_PATH" "$MBTILES_URL"

if [ -n "$MBTILES_SHA256" ]; then
  echo "Verificando SHA256..."
  echo "$MBTILES_SHA256  $MBTILES_PATH" | sha256sum -c - || {
    echo "ERROR: SHA256 no coincide"
    exit 1
  }
  echo "SHA256 OK"
fi

echo "Arrancando Martin en puerto $PORT..."
exec martin /data --style /styles --font /fonts --listen-addresses "0.0.0.0:$PORT"
