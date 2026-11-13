"""Decisiones de `GET /app/version` (parche ligero vs APK completo).

Casos que cubren el fallo real: un telefono que **ya aplico un parche** sigue
reportando la version del parche (`1.0.25-p1`) pero conserva el `versionCode`
de su APK base (`4024`). Ese telefono tiene que seguir recibiendo parche,
aunque la version nueva ya sea 1.0.26.

    python -m unittest tests.test_ota_version -v
"""
import unittest
from types import SimpleNamespace

from routers import app_updates as ota

MANIFIESTO = {
    "app": "client",
    "latest": {
        "version": "1.0.26",
        "version_code": 4027,
        "apk": "app_cliente_64bits.apk",
    },
    "releases": [
        {"version": "1.0.26", "version_code": 4027},
        {"version": "1.0.25", "version_code": 4026},
        {"version": "1.0.24", "version_code": 4025},
        {"version": "1.0.23", "version_code": 4024},
        {"version": "1.0.22", "version_code": 4023},
    ],
    "patches": [
        {
            "version": "1.0.26-p1",
            "target_version_code": 4026,
            "file": "patch_cliente_4026.zip",
            "md5": "aaa",
            "abi": "arm64-v8a",
        },
        {
            "version": "1.0.26-p1",
            "target_version_code": 3026,
            "file": "patch_cliente_3026.zip",
            "md5": "ccc",
            "abi": "armeabi-v7a",
        },
        {
            "version": "1.0.26-p1",
            "target_version_code": 4024,
            "file": "patch_cliente_4024.zip",
            "md5": "bbb",
            "abi": "arm64-v8a",
        },
    ],
}


def _request():
    return SimpleNamespace(
        headers={
            "host": "rapi.example.com",
            "x-forwarded-proto": "https",
        },
        url=SimpleNamespace(scheme="https", netloc="rapi.example.com"),
    )


class DecisionOtaTest(unittest.TestCase):
    def setUp(self):
        self._original = ota._leer_manifiesto
        ota._leer_manifiesto = lambda app_key: MANIFIESTO

    def tearDown(self):
        ota._leer_manifiesto = self._original

    def decidir(self, version, codigo, abi=None, app="client"):
        return ota._respuesta_version(
            _request(), app, version, codigo, abi)["tipo_actualizacion"]

    def test_version_limpia_quita_parche_y_build(self):
        self.assertEqual(ota._version_limpia("1.0.26-p1"), "1.0.26")
        self.assertEqual(ota._version_limpia("1.0.26+2027"), "1.0.26")
        self.assertEqual(ota._version_limpia(" 1.0.24 "), "1.0.24")

    def test_al_dia(self):
        self.assertEqual(self.decidir("1.0.26", 4027), "none")

    def test_parche_para_la_base_inmediata(self):
        self.assertEqual(self.decidir("1.0.25", 4026), "patch")

    def test_parche_cuando_ya_se_aplico_uno(self):
        # Reporta la version del parche pero mantiene el versionCode base.
        self.assertEqual(self.decidir("1.0.25-p1", 4024), "patch")
        self.assertEqual(self.decidir("1.0.26-p1", 4026), "none")

    def test_sin_parche_para_esa_base_pide_apk(self):
        self.assertEqual(self.decidir("1.0.24", 4025), "apk")

    def test_salto_de_mas_de_tres_versiones(self):
        self.assertEqual(self.decidir("1.0.22", 4023), "apk")

    def test_manda_el_abi_del_apk_no_el_del_telefono(self):
        # Telefono de 64 bits con el APK de 32 bits instalado (versionCode 3026):
        # el parche valido es el armeabi-v7a, aunque el telefono diga arm64-v8a.
        self.assertEqual(
            self.decidir("1.0.25", 3026, "arm64-v8a"), "patch")
        # Y al reves: el codigo 4026 es un APK de 64 bits; no se le sirve el
        # parche de 32 bits aunque el telefono reporte armeabi-v7a.
        self.assertEqual(
            self.decidir("1.0.25", 4026, "armeabi-v7a"), "patch")
        self.assertEqual(
            self.decidir("1.0.25", 4026, "x86_64"), "patch")


if __name__ == "__main__":
    unittest.main()
