"""
Pruebas del buzon de eventos que alimenta las notificaciones del panel.

El punto delicado es el puntero (`desde`): abrir el panel o pulsar F5 no debe
disparar avisos de eventos viejos, y dos consultas seguidas no deben perder
eventos ni repetirlos. Se usa una coleccion falsa para no depender de Mongo.

    python -m unittest tests.test_eventos_admin -v
"""
import unittest
from types import SimpleNamespace

from bson import ObjectId

from services import eventos_admin


class FakeCursor:
    def __init__(self, docs):
        self.docs = docs

    def sort(self, campo, orden):
        self.docs.sort(key=lambda d: d[campo], reverse=orden < 0)
        return self

    def limit(self, numero):
        self.docs = self.docs[:numero]
        return self

    def __iter__(self):
        return iter(self.docs)


class FakeColeccion:
    """Lo minimo que usa `eventos_admin`, con la misma semantica de Mongo."""

    def __init__(self):
        self.docs = []
        self.falla = False

    def create_index(self, *args, **kwargs):
        if self.falla:
            raise RuntimeError("Mongo caido")
        return "creado"

    def insert_one(self, doc):
        if self.falla:
            raise RuntimeError("Mongo caido")
        doc["_id"] = ObjectId()
        self.docs.append(dict(doc))
        return SimpleNamespace(inserted_id=doc["_id"])

    def find(self, filtro):
        if self.falla:
            raise RuntimeError("Mongo caido")
        salida = []
        for doc in self.docs:
            if "roles" in filtro and filtro["roles"] not in doc.get("roles", []):
                continue
            condicion = filtro.get("_id")
            if isinstance(condicion, dict) and "$gt" in condicion:
                if not doc["_id"] > condicion["$gt"]:
                    continue
            salida.append(doc)
        return FakeCursor(salida)


class BaseEventos(unittest.TestCase):

    def setUp(self):
        self.fake = FakeColeccion()
        self._original = eventos_admin.coleccion
        self._indice_original = eventos_admin._indice_listo
        eventos_admin.coleccion = self.fake
        eventos_admin._indice_listo = True
        with eventos_admin._lock:
            eventos_admin._memoria.clear()

        # Puntero anterior a los dos eventos de prueba: roles que no deben
        # verlos (wallet_operator) para que el puntero inicial sea estable.
        eventos_admin.publicar(
            "prueba", "Semilla", "no visible para trip/user",
            roles=["wallet_operator"])
        self.inicio = eventos_admin.listar("")["ultimo"]

        self.trip = eventos_admin.publicar(
            "viaje_huerfano", "Viaje sin chofer",
            "Calle A → Calle B · 500.00 CUP",
            datos={"trip_id": "T1"}, roles=["trip_operator"])
        self.user = eventos_admin.publicar(
            "registro_chofer", "Nuevo chófer registrado",
            "Ana Pérez · Kia Rio (B123)",
            datos={"driver_id": "D1"}, roles=["user_operator"])

    def tearDown(self):
        eventos_admin.coleccion = self._original
        eventos_admin._indice_listo = self._indice_original
        with eventos_admin._lock:
            eventos_admin._memoria.clear()


class TestPuntero(BaseEventos):

    def test_sin_desde_no_devuelve_eventos(self):
        salida = eventos_admin.listar("", rol="super_admin")
        self.assertEqual(salida["eventos"], [])
        self.assertEqual(salida["ultimo"], self.user["id"])

    def test_devuelve_solo_los_posteriores(self):
        eventos_admin.publicar(
            "viaje_huerfano", "Otro viaje sin chofer", "Calle C → Calle D",
            roles=["trip_operator"])
        salida = eventos_admin.listar(self.trip["id"], rol="super_admin")
        self.assertEqual([e["tipo"] for e in salida["eventos"]],
                         ["registro_chofer", "viaje_huerfano"])
        self.assertEqual(salida["ultimo"], salida["eventos"][-1]["id"])

    def test_sin_eventos_nuevos_el_puntero_no_avanza(self):
        salida = eventos_admin.listar(self.user["id"], rol="super_admin")
        self.assertEqual(salida["eventos"], [])
        self.assertEqual(salida["ultimo"], self.user["id"])

    def test_desde_invalido_se_trata_como_primera_consulta(self):
        salida = eventos_admin.listar("no-es-un-object-id", rol="super_admin")
        self.assertEqual(salida["eventos"], [])
        self.assertEqual(salida["ultimo"], self.user["id"])

    def test_pide_como_mucho_lo_que_permite_el_limite(self):
        salida = eventos_admin.listar(
            self.trip["id"], rol="super_admin", limite=999)
        self.assertLessEqual(len(salida["eventos"]),
                             eventos_admin.LIMITE_MAXIMO)


class TestRoles(BaseEventos):

    def test_trip_operator_solo_ve_viajes(self):
        salida = eventos_admin.listar(self.inicio, rol="trip_operator")
        self.assertEqual([e["tipo"] for e in salida["eventos"]],
                         ["viaje_huerfano"])

    def test_user_operator_solo_ve_registros(self):
        salida = eventos_admin.listar(self.inicio, rol="user_operator")
        self.assertEqual([e["tipo"] for e in salida["eventos"]],
                         ["registro_chofer"])

    def test_super_admin_ve_todo(self):
        salida = eventos_admin.listar(self.inicio, rol="super_admin")
        self.assertEqual([e["tipo"] for e in salida["eventos"]],
                         ["viaje_huerfano", "registro_chofer"])

    def test_rol_sin_eventos_recibe_puntero_sin_filtrar(self):
        """El puntero inicial no puede ser el de otro rol o se perderian avisos."""
        eventos_admin.publicar(
            "registro_chofer", "Otro chófer", "Luis · Lada (X1)",
            roles=["user_operator"])
        salida = eventos_admin.listar("", rol="trip_operator")
        self.assertEqual(salida["eventos"], [])
        self.assertIsNotNone(salida["ultimo"])


class TestSinMongo(BaseEventos):

    def test_publicar_no_lanza_y_cae_a_memoria(self):
        self.fake.falla = True
        evento = eventos_admin.publicar(
            "viaje_huerfano", "Sin Mongo", "Calle X → Calle Y",
            roles=["trip_operator"])
        self.assertIsNotNone(evento)
        self.assertTrue(evento["id"])
        salida = eventos_admin.listar(evento["id"], rol="super_admin")
        self.assertEqual(salida["eventos"], [])

    def test_listar_usa_la_memoria_si_mongo_falla(self):
        self.fake.falla = True
        uno = eventos_admin.publicar(
            "prueba", "Aviso uno", "texto", roles=["trip_operator"])
        dos = eventos_admin.publicar(
            "prueba", "Aviso dos", "texto", roles=["trip_operator"])
        salida = eventos_admin.listar(uno["id"], rol="super_admin")
        self.assertEqual([e["id"] for e in salida["eventos"]], [dos["id"]])


class TestSerializacion(BaseEventos):

    def test_campos_que_consume_el_navegador(self):
        evento = eventos_admin.listar(
            self.inicio, rol="super_admin")["eventos"][0]
        for campo in ("id", "tipo", "titulo", "mensaje", "datos", "creado",
                      "ts"):
            self.assertIn(campo, evento)
        self.assertEqual(evento["datos"]["trip_id"], "T1")
        self.assertIsInstance(evento["ts"], int)
        self.assertGreater(evento["ts"], 0)


if __name__ == "__main__":
    unittest.main()
