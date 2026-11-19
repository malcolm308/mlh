"""Regresión del 403 en `/ws/chofer/{id}` (handshake WebSocket).

    python -m unittest tests.test_ws_chofer_auth -v

El 403 no venia de un JWT invalido por si solo: `close(1008)` antes de
`accept()` se traduce en HTTP 403. Estas pruebas fijan los motivos del
rechazo, la compatibilidad con tokens anteriores y la lectura del token
refrescado por el cliente Flutter.
"""
from __future__ import annotations

import unittest
from unittest import mock

from fastapi import WebSocketDisconnect
from bson import ObjectId

from routers import tiempo_real

UID = "507f1f77bcf86cd799439011"
EMAIL = "chofer@test.com"


class FakeWS:
    def __init__(self, headers=None):
        self.headers = headers or {}
        self.closed = None
        self.accepted = False
        self.enviados = []

    async def close(self, code=1000, reason=None):
        # El finally del router cierra con 1000 al terminar: solo nos interesa
        # el codigo si fue ANTES de accept() (ahi es cuando FastAPI da 403).
        if not self.accepted:
            self.closed = code

    async def accept(self):
        self.accepted = True

    async def send_text(self, texto):
        self.enviados.append(texto)

    async def receive_text(self):
        raise WebSocketDisconnect()


class FakePubSub:
    async def subscribe(self, *canales):
        self.canales = canales

    async def listen(self):
        if False:  # pragma: no cover - generador vacio a proposito
            yield None

    async def close(self):
        self.cerrado = True


class FakeUsers:
    def __init__(self, doc=None):
        self.doc = doc

    def find_one(self, filtro):
        return self.doc


def _payload(**extra):
    base = {"sub": EMAIL, "id": UID, "app": "driver"}
    base.update(extra)
    return base


class TestHandshakeChofer(unittest.IsolatedAsyncioTestCase):
    async def _conectar(self, token="jwt", *, user_id=UID, headers=None,
                        payload=None, doc=None, verificar=None):
        ws = FakeWS(headers)
        coleccion = FakeUsers(doc if doc is not None else {
            "_id": ObjectId(UID), "email": EMAIL})
        with mock.patch.object(tiempo_real, "verify_token_chofer",
                               return_value=payload if verificar is None else verificar), \
             mock.patch.object(tiempo_real, "chofer_db", {"users": coleccion}), \
             mock.patch.object(tiempo_real.aioredis.client, "PubSub",
                               return_value=FakePubSub()):
            await tiempo_real.ws_tiempo_real(ws, "chofer", user_id, token)
        return ws

    async def test_token_valido_acepta(self):
        ws = await self._conectar(payload=_payload())
        self.assertTrue(ws.accepted)
        self.assertIsNone(ws.closed)

    async def test_token_invalido_cierra_1008(self):
        ws = await self._conectar(verificar=None, payload=None)
        self.assertFalse(ws.accepted)
        self.assertEqual(ws.closed, 1008)

    async def test_token_de_otra_app_se_rechaza(self):
        ws = await self._conectar(payload=_payload(app="client"))
        self.assertFalse(ws.accepted)
        self.assertEqual(ws.closed, 1008)

    async def test_token_antiguo_sin_app_se_acepta(self):
        p = _payload()
        p.pop("app")
        ws = await self._conectar(payload=p)
        self.assertTrue(ws.accepted)

    async def test_id_invalido_no_lanza_excepcion(self):
        ws = await self._conectar(user_id="no-es-objectid", payload=_payload())
        self.assertFalse(ws.accepted)
        self.assertEqual(ws.closed, 1008)

    async def test_usuario_inexistente_se_rechaza(self):
        coleccion = FakeUsers(None)
        ws2 = FakeWS()
        with mock.patch.object(tiempo_real, "verify_token_chofer",
                               return_value=_payload()), \
             mock.patch.object(tiempo_real, "chofer_db", {"users": coleccion}):
            await tiempo_real.ws_tiempo_real(ws2, "chofer", UID, "jwt")
        self.assertFalse(ws2.accepted)
        self.assertEqual(ws2.closed, 1008)

    async def test_id_del_token_vale_aunque_cambie_el_email(self):
        ws = await self._conectar(payload=_payload(sub="otro@test.com"))
        self.assertTrue(ws.accepted)

    async def test_authorization_bearer_vale_sin_query(self):
        ws = await self._conectar(token="", headers={"authorization": "Bearer jwt"},
                                  payload=_payload())
        self.assertTrue(ws.accepted)

    async def test_rol_invalido_se_rechaza(self):
        ws = FakeWS()
        await tiempo_real.ws_tiempo_real(ws, "otro", UID, "jwt")
        self.assertEqual(ws.closed, 1008)
        self.assertFalse(ws.accepted)


if __name__ == "__main__":
    unittest.main()
