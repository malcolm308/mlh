"""Regresión estatica del 422 por URLs mal construidas en Flutter.

    python -m unittest tests.test_flutter_query_urls -v

No hay toolchain Dart en este entorno, asi que se fija el contrato en el
codigo fuente: la query de `/trips/requested-nearby` debe construirse con
`Uri(queryParameters:)` (que pone los '&') y el WebSocket debe renovar el
JWT en cada conexion.
"""
from __future__ import annotations

import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
SERVICIOS = RAIZ / "frontend" / "taxi_driver" / "lib" / "services"


def _leer(nombre: str) -> str:
    return (SERVICIOS / nombre).read_text(encoding="utf-8")


class TestUrlsFlutter(unittest.TestCase):
    def test_background_usa_queryparameters(self):
        codigo = _leer("ofertas_background_service.dart")
        self.assertIn(".replace(queryParameters: params)", codigo)
        self.assertIn("'radius_km': '5'", codigo)
        self.assertIn("'lng': '$lng'", codigo)
        #La concatenación que producia '?lat=23.1lng=-82.3radius_km=5'
        self.assertNotIn("..write('lng=$lng')", codigo)
        self.assertNotIn("..write('radius_km=5&limit=20')", codigo)

    def test_api_service_mantiene_ampersands(self):
        codigo = _leer("api_service.dart")
        self.assertIn(
            "'/trips/requested-nearby?lat=$lat&lng=$lng&radius_km=$radiusKm&limit=$limit$id$tipo'",
            codigo,
        )

    def test_ws_renueva_token_en_cada_conexion(self):
        codigo = _leer("ws_chofer.dart")
        self.assertIn("Future<void> _conectar() async", codigo)
        self.assertIn("TokenStore.instance.leerAccess()", codigo)
        self.assertNotIn("  void _conectar() {", codigo)
        self.assertIn("import 'token_store.dart';", codigo)


if __name__ == "__main__":
    unittest.main()
