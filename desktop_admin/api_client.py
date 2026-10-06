"""Cliente HTTP del backend para la app de administracion.

Solo usa la libreria estandar (urllib), sin dependencias externas.
"""
import json
import urllib.error
import urllib.parse
import urllib.request

API_URL = "http://127.0.0.1:18000"
TIMEOUT = 30


class ApiError(Exception):
    def __init__(self, mensaje, status=None):
        super().__init__(mensaje)
        self.mensaje = mensaje
        self.status = status


class ApiClient:
    def __init__(self, base_url=API_URL, timeout=TIMEOUT):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.token = None
        self.admin_email = None

    # ---------- internals ----------
    def _request(self, method, path, params=None, body=None):
        url = self.base_url + path
        if params:
            limpio = {k: v for k, v in params.items() if v not in (None, "")}
            if limpio:
                url += "?" + urllib.parse.urlencode(limpio)

        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Accept", "application/json")
        if data:
            req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("Authorization", "Bearer " + self.token)

        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                crudo = r.read().decode("utf-8")
                return json.loads(crudo) if crudo else {}
        except urllib.error.HTTPError as e:
            crudo = e.read().decode("utf-8", "replace")
            detalle = crudo
            try:
                cuerpo = json.loads(crudo)
                if isinstance(cuerpo, dict) and "detail" in cuerpo:
                    detalle = cuerpo["detail"]
                elif isinstance(cuerpo, list) and cuerpo:
                    primero = cuerpo[0]
                    if isinstance(primero, dict) and "msg" in primero:
                        campo = ".".join(primero.get("loc", [])[1:]) or "dato"
                        detalle = "%s: %s" % (campo, primero["msg"])
            except Exception:
                pass
            raise ApiError(str(detalle), status=e.code)
        except urllib.error.URLError as e:
            raise ApiError("No se pudo conectar con el servidor (%s).\n"
                           "Verifica que el backend este corriendo." % e.reason)
        except Exception as e:
            raise ApiError("Error inesperado: %s" % e)

    def get(self, path, params=None):
        return self._request("GET", path, params=params)

    def post(self, path, body=None, params=None):
        return self._request("POST", path, params=params, body=body)

    # ---------- sesion ----------
    def login(self, email, password):
        r = self.post("/login", {"email": email, "password": password})
        self.token = r["access_token"]
        self.admin_email = email
        return r

    def logout(self):
        self.token = None
        self.admin_email = None

    def ping(self):
        """Comprueba que el token siga vivo."""
        return self.get("/admin/trips/resumen")

    # ---------- viajes ----------
    def viajes_diarios(self, dias=7, hasta=None):
        return self.get("/admin/trips/diarios", {"dias": dias, "hasta": hasta})

    def viajes_del_dia(self, fecha=None):
        return self.get("/admin/trips/dia", {"fecha": fecha})

    def resumen_dia(self, fecha=None):
        return self.get("/admin/trips/resumen", {"fecha": fecha})

    def choferes_top(self, fecha=None, limite=10):
        return self.get("/admin/choferes/top", {"fecha": fecha, "limite": limite})

    # ---------- choferes ----------
    def choferes(self, estado=None, q=None):
        return self.get("/admin/choferes", {"estado": estado, "q": q})

    def cambiar_estado_chofer(self, driver_id, estado, motivo=None):
        return self.post("/admin/choferes/%s/estado" % driver_id,
                         {"estado": estado, "motivo": motivo})

    def documentos(self, driver_id):
        return self.get("/documentos/chofer/%s/estado" % driver_id)

    def url_documento(self, archivo):
        return "%s/documentos/imagen/%s" % (self.base_url, archivo)

    def descargar_documento(self, archivo):
        """Descarga los bytes de una foto de documento.

        /documentos/imagen solo acepta token de administrador, asi que no
        sirve un urlopen pelado: hay que mandar la cabecera de autorizacion.
        """
        if not archivo:
            raise ApiError("El documento no indica archivo.")
        req = urllib.request.Request(
            self.url_documento(archivo), method="GET")
        req.add_header("Accept", "image/*")
        if self.token:
            req.add_header("Authorization", "Bearer " + self.token)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                raise ApiError("La sesion expiro. Vuelve a entrar al panel.", status=e.code)
            raise ApiError("No se pudo descargar la imagen (HTTP %s)." % e.code,
                           status=e.code)
        except urllib.error.URLError as e:
            raise ApiError("No se pudo conectar con el servidor (%s)." % e.reason)

    # ---------- billetera ----------
    def choferes_busqueda(self, q=None):
        return self.get("/billetera/choferes", {"q": q})

    def saldo(self, driver_id):
        return self.get("/billetera/saldo/%s" % driver_id)

    def recarga(self, **kwargs):
        return self.post("/billetera/recarga", kwargs)

    def descargo(self, **kwargs):
        return self.post("/billetera/descargo", kwargs)

    def movimientos(self, driver_id=None, limit=100):
        return self.get("/billetera/movimientos",
                        {"driver_id": driver_id, "limit": limit})

    def resumen_billetera(self):
        return self.get("/billetera/resumen")
