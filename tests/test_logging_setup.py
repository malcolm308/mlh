"""Regresión: los INFO del arranque y del outbox deben verse en Render.

Antes no habia handler para los loggers de la app: uvicorn solo configura los
suyos, asi que `WS rechazado` (warning) salia pero `=== INICIANDO APLICACIÓN ===`
y `Outbox heartbeat` (info) desaparecian.

    python -m unittest tests.test_logging_setup -v
"""
from __future__ import annotations

import io
import logging
import os
import unittest
from unittest import mock

from app.logging_setup import configurar_logging


class TestLoggingSetup(unittest.TestCase):
    def setUp(self):
        self._nivel_original = logging.getLogger().level

    def tearDown(self):
        raiz = logging.getLogger()
        for handler in list(raiz.handlers):
            if getattr(handler, "_taxi_rapid_handler", False):
                raiz.removeHandler(handler)
        raiz.setLevel(self._nivel_original)

    def test_info_de_la_app_llega_a_la_consola(self):
        with mock.patch.dict(os.environ, {"LOG_LEVEL": "INFO"}):
            configurar_logging()
        propios = [h for h in logging.getLogger().handlers
                   if getattr(h, "_taxi_rapid_handler", False)]
        self.assertEqual(len(propios), 1)

        buf = io.StringIO()
        propios[0].setStream(buf)
        logging.getLogger("main_v2").info("=== INICIANDO APLICACIÓN ===")
        self.assertIn("INICIANDO APLICACIÓN", buf.getvalue())

    def test_idempotente_no_duplica_handlers(self):
        with mock.patch.dict(os.environ, {"LOG_LEVEL": "INFO"}):
            configurar_logging()
            configurar_logging()
        propios = [h for h in logging.getLogger().handlers
                   if getattr(h, "_taxi_rapid_handler", False)]
        self.assertEqual(len(propios), 1)

    def test_nivel_configurable_por_env(self):
        with mock.patch.dict(os.environ, {"LOG_LEVEL": "WARNING"}):
            configurar_logging()
        self.assertEqual(logging.getLogger().level, logging.WARNING)

    def test_nivel_invalido_cae_a_info(self):
        with mock.patch.dict(os.environ, {"LOG_LEVEL": "raro"}):
            configurar_logging()
        self.assertEqual(logging.getLogger().level, logging.INFO)


if __name__ == "__main__":
    unittest.main()
