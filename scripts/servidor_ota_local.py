"""Servidor SOLO para probar las actualizaciones OTA contra un telefono.

No arranca la API completa (ni Postgres ni Mongo): monta unicamente el router
`routers/app_updates.py` y la carpeta `static/`, que es todo lo que necesita
`GET /app/version` y la descarga de parches/APK.

Uso:

    python scripts/servidor_ota_local.py --host 0.0.0.0 --port 8010

Luego se compila la app apuntando solo el OTA a este servidor:

    flutter build apk --split-per-abi \
      --dart-define=OTA_BASE_URL=http://192.168.1.10:8010

El login y los viajes siguen yendo a Render: `OTA_BASE_URL` no toca
`API_BASE_URL`. En produccion ese define se omite.
"""

from __future__ import annotations

import argparse
import socket
from pathlib import Path

import uvicorn
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from routers import app_updates

RAIZ = Path(__file__).resolve().parent.parent
STATIC_DIR = RAIZ / "static"


def _ip_local() -> str:
    """IP de este equipo en la red, para copiarla al `--dart-define`."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            # No envia nada: solo obliga al sistema a elegir la interfaz.
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"


def crear_app() -> FastAPI:
    # El router lee los manifiestos de `routers/../static`. Se fuerza por si
    # el script se ejecuta desde otra carpeta.
    app_updates.STATIC_DIR = STATIC_DIR

    api = FastAPI(title="RapiTaxi OTA (pruebas)")
    api.include_router(app_updates.router)
    api.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

    @api.get("/")
    def raiz() -> dict[str, object]:
        return {
            "servicio": "ota-local",
            "static": str(STATIC_DIR),
            "manifiestos": sorted(p.name for p in STATIC_DIR.glob("ota_*.json")),
        }

    return api


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8010)
    args = parser.parse_args()

    ip = _ip_local()
    print(f"OTA local en http://{args.host}:{args.port}")
    print(f"Para el telefono: http://{ip}:{args.port}")
    print(
        "  flutter build apk --split-per-abi "
        f"--dart-define=OTA_BASE_URL=http://{ip}:{args.port}"
    )
    uvicorn.run(crear_app(), host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
