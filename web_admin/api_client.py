"""Cliente HTTP del panel web.

Todo pasa por `requests` y por la API de FastAPI. El panel NO importa
`pymongo`, `psycopg2` ni ningun modulo del backend: si el dia de manana se
mueve la base de datos, el panel sigue funcionando igual.

Incluye refresco transparente de sesion: el access token dura 2 h y el refresh
30 dias. Cuando una peticion devuelve 401 se pide un access nuevo a
`/auth/refresh` y se reintenta UNA vez. Si el refresh falla, se limpia la
sesion y la app vuelve al login.
"""

from __future__ import annotations

import logging
from typing import Any, Optional
from urllib.parse import quote

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

from config import CONNECT_TIMEOUT, READ_TIMEOUT

logger = logging.getLogger(__name__)


class ApiError(Exception):
    """Error legible para mostrar en la interfaz."""

    def __init__(self, mensaje: str, status: Optional[int] = None,
                 payload: Any = None):
        super().__init__(mensaje)
        self.mensaje = mensaje
        self.status = status
        self.payload = payload


class SesionExpirada(ApiError):
    """El refresh token ya no sirve: hay que volver a entrar."""


def _detalle(resp: requests.Response) -> str:
    """Saca el mensaje mas util de una respuesta de error de FastAPI."""
    crudo = resp.text or ""
    try:
        cuerpo = resp.json()
    except Exception:
        return crudo.strip()[:500] or f"HTTP {resp.status_code}"

    if isinstance(cuerpo, dict):
        detalle = cuerpo.get("detail", cuerpo)
        if isinstance(detalle, dict):
            return str(detalle.get("detail") or detalle.get("message") or detalle)
        if isinstance(detalle, list):
            partes = []
            for item in detalle:
                if isinstance(item, dict):
                    campo = ".".join(str(x) for x in item.get("loc", [])[1:])
                    partes.append(("%s: %s" % (campo, item.get("msg", ""))).strip(": "))
                else:
                    partes.append(str(item))
            return "; ".join(partes) or "Datos inválidos"
        if detalle is not None:
            return str(detalle)
        return str(cuerpo)
    return str(cuerpo)


def _app_de_token(token: Optional[str]) -> Optional[str]:
    """Lee el claim `app` del JWT SIN verificar firma (la firma la verifica
    el backend). Sirve para atrapar en el panel una sesion guardada cuyo
    token pertenece a otra app (p.ej. app=driver de un login viejo)."""
    try:
        payload = token.split(".")[1]
        datos = json.loads(
            base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)).decode())
        return (datos.get("app") or "").strip().lower() or None
    except Exception:
        return None


class ApiClient:
    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")
        self.access_token: Optional[str] = None
        self.refresh_token: Optional[str] = None
        self.admin_email: Optional[str] = None
        self.session = requests.Session()
        # Un 502/503/504 en Render suele ser la instancia despertando. Reintentar
        # solo GET es seguro: las escrituras no se repiten a ciegas.
        reintentos = Retry(
            total=1,
            connect=1,
            read=0,
            status=1,
            backoff_factor=1.5,
            status_forcelist=(502, 503, 504),
            allowed_methods=frozenset(["GET"]),
            raise_on_status=False,
        )
        self.session.mount("https://", HTTPAdapter(max_retries=reintentos))
        self.session.mount("http://", HTTPAdapter(max_retries=reintentos))

    # ---------------- sesion ----------------

    @property
    def autenticado(self) -> bool:
        return bool(self.access_token)

    def login(self, email: str, password: str) -> None:
        """Entra y comprueba que la cuenta sea realmente de administrador.

        `/login` es compartido por pasajeros, choferes y administradores. Si no
        se comprobara aqui, un chofer podria entrar al panel y solo veria 403 en
        cada pestaña; es mejor decirlo en la puerta.
        """
        data = self._json(
            "POST", "/admin/login",
            json={"email": email.strip(), "password": password},
            auth=False, retry_auth=False,
        )
        access = (data or {}).get("access_token")
        if not access:
            raise ApiError("El servidor no devolvió un token de acceso.")
        # `/admin/login` solo mira la base de administradores y devuelve
        # SIEMPRE un token app=admin: no hace falta comprobar el claim aqui.
        # (La comprobacion real la hace el backend con cada endpoint.)
        self.access_token = access
        self.refresh_token = (data or {}).get("refresh_token")
        self.admin_email = email.strip().lower()
        try:
            self.ping()
        except ApiError as exc:
            self.logout()
            if exc.status in (401, 403):
                raise ApiError(
                    "Esa cuenta no es de administrador o está deshabilitada.",
                    status=exc.status)
            raise

    def restaurar(self, refresh_token: str, email: str = "") -> None:
        """Recupera la sesion a partir del refresh token guardado en cookie.

        Lo usa el panel al recargar la pagina para no pedir la contrasena otra
        vez mientras el refresh (30 dias) siga vigente. Si el refresh ya no
        sirve lanza `SesionExpirada`.
        """
        self.refresh_token = (refresh_token or "").strip() or None
        self.admin_email = (email or "").strip().lower() or None
        self._refresh()
        if _app_de_token(self.access_token) != "admin":
            # La cookie guardo una sesion de otra app (el mismo correo podria
            # estar en la app de chofer/cliente). No sirve para el panel:
            # pide login limpio en lugar de morir a mitad de las pestañas.
            self.logout()
            raise SesionExpirada(
                "Tu sesión guardada no es de administrador. Inicia sesión "
                "con tu correo de administrador.", status=401)
        try:
            self.ping()
        except ApiError as exc:
            self.logout()
            if exc.status in (401, 403):
                raise SesionExpirada(
                    "Tu sesión expiró. Vuelve a iniciar sesión.",
                    status=exc.status)
            raise

    def logout(self) -> None:
        self.access_token = None
        self.refresh_token = None
        self.admin_email = None

    def ping(self) -> dict:
        """Peticion barata que valida el token contra el backend."""
        return self.resumen_viajes()

    def resumen_viajes(self, fecha: Optional[str] = None) -> dict:
        """Totales del dia: viajes, completados, activos y facturado."""
        return self._json("GET", "/admin/trips/resumen",
                          params={"fecha": fecha} if fecha else None)

    def choferes_top(self, fecha: Optional[str] = None,
                     limite: int = 10) -> dict:
        params = {"limite": limite}
        if fecha:
            params["fecha"] = fecha
        return self._json("GET", "/admin/choferes/top", params=params)

    # ---------------- perfil y gestion de admins ----------------

    def perfil_admin(self) -> dict:
        """Email + rol del admin en sesion (define las pestanas visibles)."""
        return self._json("GET", "/admin/perfil")

    def listar_administradores(self) -> dict:
        return self._json("GET", "/admin/administradores")

    def crear_administrador(self, email: str, rol: str,
                            nombre: str = "", telefono: str = "",
                            password: Optional[str] = None) -> dict:
        cuerpo: dict = {"email": email.strip(), "rol": rol}
        if nombre.strip():
            cuerpo["nombre"] = nombre.strip()
        if telefono.strip():
            cuerpo["telefono"] = telefono.strip()
        if password:
            cuerpo["password"] = password
        return self._json("POST", "/admin/administradores", json=cuerpo)

    def despedir_administrador(self, admin_id: str) -> dict:
        return self._json("DELETE", "/admin/users/%s" % admin_id)

    def asignar_password_admin(self, admin_id: str) -> dict:
        """Sin pasarla por el panel: el backend genera y la devuelve UNA VEZ."""
        return self._json("PUT", "/admin/users/%s/password" % admin_id,
                          json={})

    def cambiar_mi_password(self, actual: str, nueva: str) -> dict:
        return self._json("PUT", "/admin/mi-password",
                          json={"actual": actual, "nueva": nueva})

    def buscar_clientes(self, q: str) -> dict:
        return self._json("GET", "/users/admin/buscar", params={"q": q})

    def borrar_cliente(self, cliente_id: str) -> dict:
        return self._json("POST", "/users/admin/eliminar/%s" % cliente_id)

    def _refresh(self) -> None:
        if not self.refresh_token:
            self.logout()
            raise SesionExpirada(
                "Tu sesión expiró. Vuelve a iniciar sesión.", status=401)
        try:
            data = self._json(
                "POST", "/auth/refresh",
                json={"refresh_token": self.refresh_token},
                auth=False, retry_auth=False,
            )
        except ApiError:
            self.logout()
            raise SesionExpirada(
                "Tu sesión expiró. Vuelve a iniciar sesión.", status=401)

        access = (data or {}).get("access_token")
        if not access:
            self.logout()
            raise SesionExpirada(
                "El servidor no renovó la sesión. Vuelve a iniciar sesión.",
                status=401)
        self.access_token = access

    # ---------------- HTTP base ----------------

    def _request(self, method: str, path: str, *, params=None, json=None,
                 auth: bool = True, retry_auth: bool = True,
                 accept: str = "application/json") -> requests.Response:
        url = self.base_url + path
        headers = {"Accept": accept}
        if json is not None:
            headers["Content-Type"] = "application/json"
        if auth and self.access_token:
            headers["Authorization"] = "Bearer " + self.access_token

        try:
            resp = self.session.request(
                method, url, params=params, json=json, headers=headers,
                timeout=(CONNECT_TIMEOUT, READ_TIMEOUT),
            )
        except requests.Timeout:
            raise ApiError(
                "El servidor tardó más de %d s en responder.\n\n"
                "En el plan gratuito de Render la instancia se duerme a los "
                "15 min sin uso y la primera petición del día tarda 30-60 s "
                "en despertarla. Inténtalo otra vez." % READ_TIMEOUT)
        except requests.ConnectionError as exc:
            raise ApiError(
                "No se pudo conectar con el servidor.\n\n%s\n\n"
                "Revisa la conexión a internet y la variable API_BASE_URL."
                % exc)
        except requests.RequestException as exc:
            raise ApiError("Error inesperado de red: %s" % exc)

        if resp.status_code == 401 and auth and retry_auth and self.refresh_token:
            # El access caduco. Se renueva y se repite la peticion original una
            # sola vez; si el refresh tambien falla, `_refresh` lanza
            # SesionExpirada y la app vuelve al login.
            self._refresh()
            return self._request(
                method, path, params=params, json=json, auth=auth,
                retry_auth=False, accept=accept)

        if not resp.ok:
            raise ApiError(_detalle(resp), status=resp.status_code,
                           payload=_payload_seguro(resp))
        return resp

    def _json(self, method: str, path: str, **kwargs) -> Any:
        resp = self._request(method, path, **kwargs)
        if not resp.content:
            return {}
        try:
            return resp.json()
        except ValueError:
            raise ApiError("El servidor devolvió una respuesta que no es JSON.")

    # ---------------- viajes ----------------

    def viajes_criticos(self) -> dict:
        """Viajes en cola sin chofer (`GET /admin/alerts/pending`)."""
        return self._json("GET", "/admin/alerts/pending")

    def viajes_activos(self) -> dict:
        return self._json("GET", "/admin/trips/active")

    def asignar_viaje(self, trip_id: str, telefono: str) -> dict:
        return self._json(
            "POST", "/admin/trips/%s/force-assign" % quote(trip_id, safe=""),
            json={"driver_phone": telefono.strip()})

    def forzar_inicio(self, trip_id: str) -> dict:
        return self._json(
            "POST", "/admin/trips/%s/force-start" % quote(trip_id, safe=""))

    def forzar_fin(self, trip_id: str, tip: float = 0.0) -> dict:
        return self._json(
            "POST", "/admin/trips/%s/force-complete" % quote(trip_id, safe=""),
            json={"tip": tip})

    def viajes_diarios(self, dias: int = 7,
                       hasta: Optional[str] = None) -> dict:
        params = {"dias": dias}
        if hasta:
            params["hasta"] = hasta
        return self._json("GET", "/admin/trips/diarios", params=params)

    def viajes_del_dia(self, fecha: str) -> dict:
        return self._json("GET", "/admin/trips/dia", params={"fecha": fecha})

    # ---------------- vehiculos ----------------

    def vehiculos(self, estado: Optional[str] = None) -> dict:
        params = {"estado": estado} if estado else None
        return self._json("GET", "/admin/vehicles", params=params)

    def decidir_vehiculo(self, vehiculo_id: str, decision: str,
                         motivo: str = "") -> dict:
        # El motivo solo se manda al rechazar. Al aprobar se omite el campo
        # (antes se enviaba `null`, que el backend rechazaba con un 422 y el
        # boton "Aprobar" parecia no hacer nada).
        payload = {"decision": decision}
        if decision == "rechazado" and motivo.strip():
            payload["motivo"] = motivo.strip()
        return self._json(
            "PUT", "/admin/vehicles/%s/approve" % quote(vehiculo_id, safe=""),
            json=payload)

    def revisar_foto_vehiculo(self, vehiculo_id: str, campo: str,
                              decision: str, motivo: str = "") -> dict:
        payload = {"decision": decision}
        if decision == "rechazado" and motivo.strip():
            payload["motivo"] = motivo.strip()
        return self._json(
            "PUT", "/admin/vehicles/%s/fotos/%s/revisar"
            % (quote(vehiculo_id, safe=""), quote(campo, safe="")),
            json=payload)

    def descargar_imagen(self, archivo: str) -> bytes:
        """Foto de vehiculo/documento. Exige token de administrador."""
        if not archivo:
            raise ApiError("La imagen no indica archivo.")
        if archivo.startswith("/"):
            path = archivo
        else:
            path = "/garaje/imagen/" + quote(archivo, safe="")
        resp = self._request("GET", path, accept="image/*")
        return resp.content

    # ---------------- choferes ----------------

    def choferes(self, estado: Optional[str] = None,
                 q: Optional[str] = None) -> dict:
        params = {}
        if estado:
            params["estado"] = estado
        if q:
            params["q"] = q
        return self._json("GET", "/admin/choferes", params=params or None)

    def cambiar_estado_chofer(self, driver_id: str, estado: str,
                              motivo: str = "") -> dict:
        return self._json(
            "POST", "/admin/choferes/%s/estado" % quote(driver_id, safe=""),
            json={"estado": estado, "motivo": motivo.strip() or None})

    # ---------------- configuracion ----------------

    def configuracion(self) -> dict:
        """Promociones + tarifas. Tolera un backend sin el endpoint agregado."""
        try:
            return self._json("GET", "/admin/configuracion")
        except ApiError as exc:
            if exc.status not in (404, 405):
                raise
        promo = self._json("GET", "/admin/promociones")
        tarifas = self._json("GET", "/admin/promociones/tarifas-espera")
        return {**promo, **tarifas}

    def guardar_configuracion(self, payload: dict) -> dict:
        try:
            return self._json("PUT", "/admin/configuracion", json=payload)
        except ApiError as exc:
            if exc.status not in (404, 405):
                raise
        # Compatibilidad con un backend anterior al endpoint agregado.
        return self._json("POST", "/admin/promociones", json=payload)

    # ---------------- billetera ----------------

    def billetera_choferes(self, q: Optional[str] = None) -> list:
        return self._json("GET", "/billetera/choferes",
                          params={"q": q} if q else None)

    def billetera_saldo(self, driver_id: str) -> dict:
        return self._json(
            "GET", "/billetera/saldo/%s" % quote(driver_id, safe=""))

    def billetera_recarga(self, driver_id: str, monto: float,
                          metodo: str = "efectivo", referencia: str = "",
                          nota: str = "") -> dict:
        return self._json("POST", "/billetera/recarga", json={
            "driver_id": driver_id,
            "monto": monto,
            "metodo": metodo,
            "referencia": referencia.strip() or None,
            "nota": nota.strip() or None,
        })

    def billetera_descargo(self, driver_id: str, monto: float,
                           metodo: str = "ajuste", nota: str = "") -> dict:
        return self._json("POST", "/billetera/descargo", json={
            "driver_id": driver_id,
            "monto": monto,
            "metodo": metodo,
            "nota": nota.strip() or None,
        })

    def billetera_movimientos(self, driver_id: Optional[str] = None,
                              limit: int = 100) -> list:
        params = {"limit": limit}
        if driver_id:
            params["driver_id"] = driver_id
        return self._json("GET", "/billetera/movimientos", params=params)

    def billetera_resumen(self) -> dict:
        return self._json("GET", "/billetera/resumen")


def _payload_seguro(resp: requests.Response) -> Any:
    try:
        return resp.json()
    except Exception:
        return resp.text[:1000]


def explicar_error(exc: ApiError) -> str:
    """Mensaje listo para `st.error`, sin tracebacks."""
    if isinstance(exc, SesionExpirada):
        return exc.mensaje
    if exc.payload and isinstance(exc.payload, dict):
        detalle = exc.payload.get("detail")
        if isinstance(detalle, dict) and detalle.get("detail"):
            return str(detalle["detail"])
    return exc.mensaje
