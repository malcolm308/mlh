"""Publica un APK (y opcionalmente un parche) en `static/` y actualiza el
manifiesto OTA que lee `GET /app/version`.

Ejemplos:

    # APK nuevo del cliente, sin parche (instalaciones viejas bajan el APK)
    python scripts/publicar_ota.py --app client --version 1.0.2 --version-code 3 \
        --apk frontend/taxi_client/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk

    # Parche para quien tenga el APK base 1.0.1 (versionCode 2)
    python scripts/publicar_ota.py --app client --version 1.0.2 --version-code 3 \
        --apk .../app-arm64-v8a-release.apk \
        --patch frontend/taxi_client/dist/patch.zip \
        --patch-version 1.0.2-p1 --target-version-code 2

El parche SIEMPRE se ata al `versionCode` del APK sobre el que se compilo: un
telefono con otra base no lo recibe (el backend le manda el APK completo).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
STATIC_DIR = RAIZ / "static"

MANIFIESTOS = {
    "client": "ota_client.json",
    "driver": "ota_driver.json",
}
APK_DESTINO = {
    "client": "app_latest.apk",
    "driver": "app_chofer_latest.apk",
}
PARCHE_DESTINO = {
    "client": "patch_latest.zip",
    "driver": "patch_chofer_latest.zip",
}

# Cuantas versiones se conservan en el historial. Con 2 basta para distinguir
# "un salto" de "muy atrasada"; se guardan 5 por comodidad al diagnosticar.
MAX_RELEASES = 5


def _md5(ruta: Path) -> str:
    h = hashlib.md5()
    with ruta.open("rb") as fh:
        for bloque in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(bloque)
    return h.hexdigest()


def _cargar_manifiesto(app: str) -> dict:
    ruta = STATIC_DIR / MANIFIESTOS[app]
    if ruta.exists():
        with ruta.open("r", encoding="utf-8") as fh:
            datos = json.load(fh)
        if isinstance(datos, dict):
            return datos
    return {"app": app, "latest": {}, "releases": [], "patches": []}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", choices=sorted(MANIFIESTOS), required=True)
    parser.add_argument("--version", required=True, help="1.0.2 (sin +build)")
    parser.add_argument("--version-code", type=int, required=True)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--patch", type=Path, help="patch.zip generado por pack")
    parser.add_argument("--patch-version", help="1.0.2-p1")
    parser.add_argument("--target-version-code", type=int,
                        help="versionCode del APK base para el que sirve el parche")
    args = parser.parse_args()

    if not args.apk.is_file():
        raise SystemExit(f"No existe el APK: {args.apk}")
    if args.patch and not (args.patch_version and args.target_version_code):
        raise SystemExit("--patch exige --patch-version y --target-version-code")

    STATIC_DIR.mkdir(parents=True, exist_ok=True)

    # 1. APK completo.
    destino_apk = STATIC_DIR / APK_DESTINO[args.app]
    shutil.copyfile(args.apk, destino_apk)
    print(f"[ota] APK  -> {destino_apk} ({destino_apk.stat().st_size:,} bytes)")

    # 2. Manifiesto.
    manifiesto = _cargar_manifiesto(args.app)
    anterior = (manifiesto.get("latest") or {}).get("version")

    releases = [
        r for r in (manifiesto.get("releases") or [])
        if isinstance(r, dict) and str(r.get("version", "")).strip()
        and str(r.get("version", "")).strip() != args.version
    ]
    releases.insert(0, {"version": args.version, "version_code": args.version_code})
    releases = releases[:MAX_RELEASES]

    patches = [
        p for p in (manifiesto.get("patches") or [])
        if isinstance(p, dict) and p.get("file")
    ]
    if args.patch:
        if not args.patch.is_file():
            raise SystemExit(f"No existe el parche: {args.patch}")
        destino_parche = STATIC_DIR / PARCHE_DESTINO[args.app]
        shutil.copyfile(args.patch, destino_parche)
        md5 = _md5(destino_parche)
        # Un solo parche por APK base: reemplaza el anterior de ese vc.
        patches = [
            p for p in patches
            if int(p.get("target_version_code", -1)) != args.target_version_code
        ]
        patches.insert(0, {
            "version": args.patch_version,
            "target_version_code": args.target_version_code,
            "file": destino_parche.name,
            "md5": md5,
            "published_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        })
        print(f"[ota] parche -> {destino_parche} (md5 {md5})")

    manifiesto.update({
        "app": args.app,
        "latest": {
            "version": args.version,
            "version_code": args.version_code,
            "apk": destino_apk.name,
        },
        "releases": releases,
        "patches": patches,
        "updated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    })

    ruta_manifiesto = STATIC_DIR / MANIFIESTOS[args.app]
    with ruta_manifiesto.open("w", encoding="utf-8") as fh:
        json.dump(manifiesto, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    print(f"[ota] manifiesto -> {ruta_manifiesto}")
    print(f"[ota] {anterior or '?'} -> {args.version} (vc {args.version_code})")
    print("[ota] recuerda subir a git los archivos de static/")


if __name__ == "__main__":
    main()
