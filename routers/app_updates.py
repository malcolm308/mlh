"""Actualizaciones OTA de las apps (cliente y chofer).

Tres endpoints:

* `GET /healthz`  -> *liveness*. 200 mientras el proceso viva. No toca la BD:
  Render puede reiniciar el contenedor sin esperar a Postgres.
* `GET /readyz`   -> *readiness*. 200 solo si la BD principal responde. Render
  no manda trafico a una instancia que aun no esta lista, y no la tumba por un
  fallo transitorio de Mongo.
* `GET /app/version` -> decide si la app que pregunta necesita un parche
  ligero (`patch`), el APK completo (`apk`) o nada (`none`).

## Como se publica una version

El estado vive en `static/ota_client.json` y `static/ota_driver.json`. Formato:

```json
{
  "app": "client",
  "latest": {"version": "1.0.2", "version_code": 3, "apk": "app_latest.apk"},
  "releases": [
    {"version": "1.0.2", "version_code": 3},
    {"version": "1.0.1", "version_code": 2},
    {"version": "1.0.0", "version_code": 1}
  ],
  "patches": [
    {"version": "1.0.2-p1", "target_version_code": 2, "abi": "arm64-v8a",
     "file": "patch_cliente_2.zip", "md5": "..."}
  ]
}
```

Reglas (estrictas):

* app == latest                       -> `none`
* app hasta `_MAX_PATCH_DISTANCE` versiones por detras:
    * si hay un parche compilado para SU `versionCode` -> `patch`
    * si no hay parche para ese APK base             -> `apk`
* app mas atras que `_MAX_PATCH_DISTANCE`           -> `apk`
* version desconocida y mas nueva que `latest` -> `none` (no degradar)
* version desconocida y anterior       -> `apk` (salvo parche exacto)

El parche se ata al `versionCode` del APK instalado (`target_version_code`).
Asi un parche construido para la 1.0.1 nunca se aplica sobre la 1.0.0: esa
instalacion no tiene ni siquiera el plugin nativo de parches y recibiria el
APK completo.

Un parche solo se sirve si lleva a la version ACTUAL (`version` empieza por
`latest.version + '-'`). Si se sirviera uno viejo, la app quedaria marcada
como parcheada en una version intermedia y no volveria a actualizarse.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any
from urllib.parse import quote

from fastapi import APIRouter, HTTPException, Query, Request, Response
from pydantic import BaseModel

router = APIRouter(tags=["ota"])

STATIC_DIR = Path(__file__).resolve().parent.parent / "static"

# Alias aceptados por el parametro `app`.
_APP_ALIASES = {
    "client": "client",
    "cliente": "client",
    "taxi_client": "client",
    "pasajero": "client",
    "driver": "driver",
    "chofer": "driver",
    "taxi_driver": "driver",
    "conductor": "driver",
}

_MANIFEST_FILES = {
    "client": "ota_client.json",
    "driver": "ota_driver.json",
}

_DEFAULT_APKS = {
    "client": "app_latest.apk",
    "driver": "app_chofer_latest.apk",
}

# APK por arquitectura. Los telefonos de 32 bits rechazan el de 64 con
# "paquete no valido", asi que el endpoint tiene que devolver el correcto.
_APKS_POR_ABI = {
    "client": {"32": "app_cliente_32bits.apk", "64": "app_cliente_64bits.apk"},
    "driver": {"32": "app_chofer_32bits.apk", "64": "app_chofer_64bits.apk"},
}

# Cuantas versiones atras se acepta un parche. Mas atras, APK completo: los
# cambios nativos entre versiones lejanas pueden romper el parche.
_MAX_PATCH_DISTANCE = 3


class VersionRequest(BaseModel):
    """Cuerpo alternativo para clientes que prefieran POST."""

    version_actual: str
    app: str = "client"
    version_codigo: int | None = None
    abi: str | None = None


# --------------------------------------------------------------------------
# Utilidades
# --------------------------------------------------------------------------


def _normalizar_app(app: str) -> str:
    clave = (app or "").strip().lower()
    normalizada = _APP_ALIASES.get(clave)
    if normalizada is None:
        raise HTTPException(
            status_code=400,
            detail=f"App desconocida: {app!r}. Usa 'client' o 'driver'.",
        )
    return normalizada


def _base_publica(request: Request) -> str:
    """URL publica del backend, sin barra final.

    En Render la peticion llega por el proxy interno, asi que el esquema y el
    host reales vienen en `X-Forwarded-Proto` / `X-Forwarded-Host`. Sin esto la
    URL de descarga saldria en `http://` y Android bloquea el trafico en claro:
    el APK y el parche no se podrian bajar. `PUBLIC_BASE_URL` sigue mandando si
    esta definido (util si algun dia hay CDN delante).
    """
    base = (os.getenv("PUBLIC_BASE_URL") or "").strip().rstrip("/")
    if base:
        return base
    esquema = (
        request.headers.get("x-forwarded-proto") or request.url.scheme or "https"
    ).split(",")[0].strip()
    host = (
        request.headers.get("x-forwarded-host")
        or request.headers.get("host")
        or request.url.netloc
    ).split(",")[0].strip()
    return f"{esquema}://{host}".rstrip("/")


def _url_estatica(request: Request, archivo: str) -> str:
    # quote() protege nombres con espacios aunque los manifiestos solo usen
    # nombres ASCII simples ("app_cliente_64bits.apk", "patch_cliente_4024.zip").
    return f"{_base_publica(request)}/static/{quote(archivo)}"


def _version_limpia(valor: str) -> str:
    """Quita el `+build` de una version de pubspec: `1.0.2+3` -> `1.0.2`."""
    return (valor or "").strip().split("+", 1)[0].strip()


def _clave_version(valor: str) -> tuple:
    """Ordena versiones tipo `1.0.2`. Los tramos no numericos comparan como 0.

    No se usa `packaging` para no agregar una dependencia solo por esto, y las
    versiones de estas apps son siempre `mayor.menor.parche`.
    """
    limpia = _version_limpia(valor)
    partes: list[Any] = []
    for tramo in limpia.split("."):
        try:
            partes.append(int(tramo))
        except ValueError:
            partes.append(0)
    # Rellenar a 3 tramos para que 1.2 y 1.2.0 sean iguales.
    while len(partes) < 3:
        partes.append(0)
    return tuple(partes[:3])


def _leer_manifiesto(app_key: str) -> dict[str, Any]:
    """Lee el manifiesto de `static/`. Si no existe, usa variables de entorno."""
    ruta = STATIC_DIR / _MANIFEST_FILES[app_key]
    if ruta.exists():
        try:
            with ruta.open("r", encoding="utf-8") as fh:
                datos = json.load(fh)
            if isinstance(datos, dict) and "latest" in datos:
                return datos
        except Exception:
            # Un manifiesto corrupto no debe tumbar la API: se cae al respaldo
            # por variables de entorno y los clientes recibiran el APK.
            pass

    sufijo = app_key.upper()
    ultima = os.getenv(f"OTA_{sufijo}_LATEST_VERSION", "1.0.0")
    codigo = int(os.getenv(f"OTA_{sufijo}_LATEST_VERSION_CODE", "1"))
    anterior = os.getenv(f"OTA_{sufijo}_PREVIOUS_VERSION")
    releases = [{"version": ultima, "version_code": codigo}]
    if anterior:
        releases.append(
            {
                "version": anterior,
                "version_code": max(codigo - 1, 1),
            }
        )
    return {
        "app": app_key,
        "latest": {
            "version": ultima,
            "version_code": codigo,
            "apk": os.getenv(f"OTA_{sufijo}_APK", _DEFAULT_APKS[app_key]),
        },
        "releases": releases,
        "patches": [],
    }


def _abi_es_32(abi: str | None, codigo: int | None) -> bool:
    """`true` si el APK instalado es de 32 bits.

    La app manda su ABI cuando puede. Si no, se deduce del `versionCode`:
    `flutter build apk --split-per-abi` desplaza armeabi-v7a +1000 (3xxx) y
    arm64-v8a +2000 (4xxx) sobre la base 2xxx.
    """
    abi_norm = (abi or "").strip().lower()
    if abi_norm:
        return "armeabi" in abi_norm or "armv7" in abi_norm
    return codigo is not None and 3000 <= codigo < 4000


def _apk_file(app_key: str, codigo: int | None, abi: str | None,
              por_defecto: str) -> str:
    if app_key not in _APKS_POR_ABI:
        return por_defecto
    return _APKS_POR_ABI[app_key]["32" if _abi_es_32(abi, codigo) else "64"]


def _buscar_parche(manifiesto: dict, codigo_base: int | None,
                   version_ultima: str, abi: str | None) -> dict | None:
    """Parche compatible con el APK instalado, o `None`.

    Exige el `versionCode` exacto (un parche solo sirve para el APK base con
    el que se compilo), que lleve a la version actual y, si el manifiesto lo
    declara, el mismo ABI del telefono.
    """
    if not codigo_base:
        return None
    abi_norm = (abi or "").strip().lower()
    for parche in manifiesto.get("patches") or []:
        if not isinstance(parche, dict) or not parche.get("file"):
            continue
        try:
            if int(parche.get("target_version_code", -1)) != codigo_base:
                continue
        except (TypeError, ValueError):
            continue
        if not str(parche.get("version") or "").startswith(
                version_ultima + "-"):
            continue
        parche_abi = str(parche.get("abi") or "").strip().lower()
        if parche_abi and abi_norm and parche_abi != abi_norm:
            continue
        return parche
    return None


def _respuesta_parche(request: Request, comun: dict, parche: dict) -> dict:
    patch_url = _url_estatica(request, str(parche["file"]))
    destino = int(parche.get("target_version_code") or 0)
    return {
        **comun,
        "tipo_actualizacion": "patch",
        "url": patch_url,
        "patch_url": patch_url,
        "patch_version": str(parche.get("version") or ""),
        "patch_md5": str(parche.get("md5") or ""),
        "target_version_code": destino,
        "patch": {
            "version": str(parche.get("version") or ""),
            "patch_url": patch_url,
            "md5": str(parche.get("md5") or ""),
            "target_version_code": destino,
        },
        "mensaje": "Parche ligero disponible. Se aplicara al reabrir.",
    }


def _respuesta_apk(comun: dict, mensaje: str) -> dict:
    return {
        **comun,
        "tipo_actualizacion": "apk",
        "url": comun["url_apk"],
        "mensaje": mensaje,
    }


def _respuesta_version(
    request: Request,
    app_key: str,
    version_actual: str,
    version_codigo: int | None,
    abi: str | None,
) -> dict[str, Any]:
    if not _version_limpia(version_actual):
        raise HTTPException(status_code=400, detail="version_actual es obligatoria")

    manifiesto = _leer_manifiesto(app_key)
    latest = manifiesto.get("latest") or {}
    version_ultima = str(latest.get("version", "1.0.0"))
    codigo_ultima = int(latest.get("version_code", 1))
    apk_manifiesto = str(latest.get("apk") or _DEFAULT_APKS[app_key])

    releases = [
        r
        for r in (manifiesto.get("releases") or [])
        if isinstance(r, dict) and r.get("version")
    ]
    if not releases:
        releases = [{"version": version_ultima, "version_code": codigo_ultima}]

    version_actual_limpia = _version_limpia(version_actual)
    clave_actual = _clave_version(version_actual_limpia)

    # Indice de la version de la app dentro del historial (0 = ultima).
    indice: int | None = None
    for i, release in enumerate(releases):
        if _version_limpia(str(release["version"])) == version_actual_limpia:
            indice = i
            break

    # `versionCode` instalado: lo manda la app; si no, se toma del historial.
    codigo_instalado = version_codigo
    if codigo_instalado is None and indice is not None:
        codigo_instalado = int(releases[indice].get("version_code", 0) or 0)

    # APK completo segun el ABI. Los telefonos de 32 bits rechazan el de 64.
    apk_file = _apk_file(app_key, codigo_instalado, abi, apk_manifiesto)
    url_apk = _url_estatica(request, apk_file)

    comun = {
        "app": app_key,
        "version_actual": version_actual_limpia,
        "version_ultima": _version_limpia(version_ultima),
        "version_codigo_ultima": codigo_ultima,
        "url_apk": url_apk,
    }

    # Al dia.
    if version_actual_limpia == _version_limpia(version_ultima):
        return {**comun, "tipo_actualizacion": "none", "url": None}

    # La app va por delante del backend (build de pruebas o version retirada):
    # no se degrada a la fuerza.
    if indice is None and clave_actual > _clave_version(version_ultima):
        return {**comun, "tipo_actualizacion": "none", "url": None}

    # Parche ligero si existe uno compilado para el `versionCode` EXACTO del
    # APK instalado y la app no se salto demasiadas versiones. El parche se
    # ata al codigo base, asi que cada ABI (3xxx/4xxx) recibe el suyo.
    if indice is None or indice <= _MAX_PATCH_DISTANCE:
        parche = _buscar_parche(
            manifiesto, codigo_instalado, version_ultima, abi)
        if parche is not None:
            return _respuesta_parche(request, comun, parche)

    # Sin parche compatible (instalacion anterior al sistema OTA) o salto
    # demasiado grande: APK completo.
    if indice is not None and indice > _MAX_PATCH_DISTANCE:
        return _respuesta_apk(
            comun, "Tu version esta demasiado atrasada. Instala el APK.")
    return _respuesta_apk(
        comun, "No hay parche para esta instalacion. Instala el APK.")


# --------------------------------------------------------------------------
# Endpoints de salud
# --------------------------------------------------------------------------


@router.get("/healthz")
def healthz() -> dict[str, str]:
    """Liveness: el proceso esta vivo. Nunca consulta la BD."""
    return {"status": "ok"}


@router.get("/readyz")
def readyz(response: Response) -> dict[str, Any]:
    """Readiness: Postgres responde. Mongo se informa pero no bloquea.

    El core de la app (viajes, tarifas, billetera) vive en Postgres. Si Mongo
    falla, el proceso sigue sirviendo y se recupera solo; por eso no se marca
    la instancia como no lista y Render no la reinicia en bucle.
    """
    checks: dict[str, str] = {}
    listo = True

    try:
        from routers.Solicitud_de_viajes_v4 import get_connection

        with get_connection() as conn:
            cur = conn.cursor()
            cur.execute("SELECT 1")
            cur.fetchone()
            cur.close()
        checks["postgres"] = "ok"
    except Exception as exc:  # noqa: BLE001 - se reporta el tipo, no el stack
        checks["postgres"] = f"error: {type(exc).__name__}"
        listo = False

    try:
        from routers.Solicitud_de_viajes_v4 import mongo_client

        mongo_client.admin.command("ping")
        checks["mongodb"] = "ok"
    except Exception as exc:  # noqa: BLE001
        checks["mongodb"] = f"error: {type(exc).__name__}"

    if not listo:
        response.status_code = 503
        return {"status": "not_ready", "checks": checks}
    return {"status": "ready", "checks": checks}


# --------------------------------------------------------------------------
# Version de las apps
# --------------------------------------------------------------------------


@router.get("/app/version")
def app_version_get(
    request: Request,
    response: Response,
    version_actual: str = Query(..., min_length=1),
    app: str = Query("client"),
    version_codigo: int | None = Query(None),
    abi: str | None = Query(None),
) -> dict[str, Any]:
    """Consulta de version. Ver las reglas en el docstring del modulo."""
    response.headers["Cache-Control"] = "no-store"
    return _respuesta_version(
        request=request,
        app_key=_normalizar_app(app),
        version_actual=version_actual,
        version_codigo=version_codigo,
        abi=abi,
    )


@router.post("/app/version")
def app_version_post(
    request: Request,
    response: Response,
    body: VersionRequest,
) -> dict[str, Any]:
    """Misma logica que GET, para clientes que prefieran enviar JSON."""
    response.headers["Cache-Control"] = "no-store"
    return _respuesta_version(
        request=request,
        app_key=_normalizar_app(body.app),
        version_actual=body.version_actual,
        version_codigo=body.version_codigo,
        abi=body.abi,
    )
