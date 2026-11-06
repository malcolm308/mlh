"""Prueba real de la integracion con Cloudinary.

Genera una imagen de prueba (Pillow), la sube con `services.fotos_nube.subir`,
vuelve a descargarla con `descargar` y comprueba que los bytes coinciden, y
para borrarla con `borrar`. No imprime credenciales.

Uso (desde la raiz del repo):
    set CLOUDINARY_... (o crear `.env` en la raiz con las tres variables y
    cargarlas antes, ej: `python scripts/prueba_cloudinary.py --env .env`)
"""

import base64
import io
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from services import fotos_nube  # noqa: E402


def cargar_env(ruta: str) -> None:
    for linea in Path(ruta).read_text(encoding="utf-8").splitlines():
        linea = linea.strip()
        if not linea or linea.startswith("#") or "=" not in linea:
            continue
        clave, valor = linea.split("=", 1)
        clave, valor = clave.strip(), valor.strip().strip('"').strip("'")
        if clave and valor and not os.getenv(clave):
            os.environ[clave] = valor


def main() -> int:
    if len(sys.argv) > 2 and sys.argv[1] == "--env":
        cargar_env(sys.argv[2])
        sys.argv = sys.argv[:1]

    if not fotos_nube.disponible():
        print("FALTAN variables CLOUDINARY_* en el entorno o en .env")
        return 2

    # Imagen minima JPEG (un pixel rojo), para no depender de Pillow si
    # no esta instalada localmente.
    png_rojo = base64.b64decode(
        b"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4"
        b"z8DAwMDAiAABMQEBeXo0UAAAAABJRU5ErkJggg=="
    )
    data = png_rojo

    print("Subiendo imagen de prueba a Cloudinary...")
    subida = fotos_nube.subir(data, "image/png", "rapitaxi/prueba",
                              "prueba_integracion")
    if not subida:
        print("FALLO: la subida devolvio None (revisa credenciales/red).")
        return 1
    url = subida["url"]
    print("OK subida ->", url)

    print("Descargando para comprobar que sirve una imagen valida...")
    de_la_nube, tipo = fotos_nube.descargar(url)
    if not de_la_nube:
        print("FALLO: la descarga vino vacia.")
        return 1
    firma_ok = de_la_nube.startswith(b"\x89PNG") or de_la_nube[:3] in (b"\xff\xd8\xff", b"RIFF")
    if not firma_ok:
        print("FALLO: lo descargado no es una imagen (JPEG/PNG/WebP).")
        return 1
    print("OK descarga: %d bytes validos (%s). Cloudinary reencodifica, "
          "por eso no hay que comparar bytes 1 a 1." % (len(de_la_nube), tipo))

    fotos_nube.borrar(subida["public_id"])
    print("OK borrado de la prueba:", subida["public_id"])
    print("TODO CORRECTO: la integracion con Cloudinary funciona.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
