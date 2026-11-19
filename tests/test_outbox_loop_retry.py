"""Regresión del outbox que 'muere silenciosamente' en Render.

    python -m unittest tests.test_outbox_loop_retry -v

Fija tres cosas: log de arranque, excepcion visible al inicializar y reintento
cada 10 s cuando falta Mongo (antes hacia `return` y no habia heartbeat).
"""
from __future__ import annotations

import asyncio
import os
import unittest
from pathlib import Path
from unittest import mock

try:  # apscheduler no esta instalado en todas las maquinas de desarrollo
    import main_v2
except ImportError:  # pragma: no cover
    main_v2 = None

MAIN = Path(__file__).resolve().parents[1] / "main_v2.py"


class TestInstrumentacionStartup(unittest.TestCase):
    def test_logs_de_arranque_y_error_presentes(self):
        codigo = MAIN.read_text(encoding="utf-8")
        self.assertIn('logger.info("=== INICIANDO APLICACIÓN ===")', codigo)
        self.assertIn('logger.exception("Error inicializando Outbox")', codigo)
        self.assertIn("Outbox: No se pudo conectar a Mongo", codigo)
        self.assertIn("if await _esperar(10.0):", codigo)


@unittest.skipIf(main_v2 is None, "main_v2 requiere apscheduler")
class TestLoopSinMongo(unittest.IsolatedAsyncioTestCase):
    async def test_falta_uri_no_cierra_el_loop(self):
        # Si MONGODB_URI falta, el loop debe quedarse en el bucle de reintento.
        # Parcheamos sleep para que la primera espera lance CancelledError: si
        # el codigo hiciera `return`, este test no veria la excepcion.
        with mock.patch.dict(os.environ, {"MONGODB_URI": ""}), \
             mock.patch.object(main_v2, "_outbox_stop_event", None), \
             mock.patch.object(main_v2.asyncio, "sleep",
                               new=mock.AsyncMock(side_effect=asyncio.CancelledError)):
            with self.assertRaises(asyncio.CancelledError):
                await main_v2._outbox_loop()


if __name__ == "__main__":
    unittest.main()
