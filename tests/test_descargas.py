"""Enlaces cortos de descarga `/c64`, `/c32`, `/d64` y `/d32`.

Sustituyen al acortador externo (shty.in): cada ruta responde 302 directo al
APK de `/static`, sin pagina intermedia. La redireccion es relativa para que el
telefono siga en https detras del proxy de Render.

    python -m unittest tests.test_descargas -v
"""
import tempfile
import unittest
from pathlib import Path

from fastapi import HTTPException

from routers import descargas


class DescargasTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._original = descargas.STATIC_DIR
        descargas.STATIC_DIR = Path(self._tmp.name)

    def tearDown(self):
        descargas.STATIC_DIR = self._original
        self._tmp.cleanup()

    def _publicar(self, archivo):
        (Path(self._tmp.name) / archivo).write_bytes(b"apk")

    def _assert_redirige(self, respuesta, archivo):
        self.assertEqual(respuesta.status_code, 302)
        self.assertEqual(respuesta.headers["location"], f"/static/{archivo}")
        self.assertEqual(respuesta.headers["cache-control"], "no-store")

    def test_cliente_64(self):
        self._publicar(descargas.APK_CLIENTE_64)
        self._assert_redirige(descargas.apk_cliente_64(),
                             descargas.APK_CLIENTE_64)

    def test_cliente_32(self):
        self._publicar(descargas.APK_CLIENTE_32)
        self._assert_redirige(descargas.apk_cliente_32(),
                             descargas.APK_CLIENTE_32)

    def test_chofer_64(self):
        self._publicar(descargas.APK_CHOFER_64)
        self._assert_redirige(descargas.apk_chofer_64(),
                             descargas.APK_CHOFER_64)

    def test_chofer_32(self):
        self._publicar(descargas.APK_CHOFER_32)
        self._assert_redirige(descargas.apk_chofer_32(),
                             descargas.APK_CHOFER_32)

    def test_apk_sin_publicar_da_404_claro(self):
        with self.assertRaises(HTTPException) as ctx:
            descargas.apk_cliente_64()
        self.assertEqual(ctx.exception.status_code, 404)
        self.assertIn(descargas.APK_CLIENTE_64, ctx.exception.detail)


if __name__ == "__main__":
    unittest.main()
