"""Pestana Choferes: tabla de habilitacion (aprobar / rechazar)."""
import tkinter as tk
from tkinter import ttk, messagebox, simpledialog

from api_client import ApiError
from documentos_window import VentanaDocumentos
from ui_common import Tabla, money, boton, etiqueta_estado, consultar_en_hilo

FILTROS = [("pendiente", "Solo pendientes"), ("aprobado", "Solo aprobados"),
           ("rechazado", "Solo rechazados"), ("", "Todos")]


class TabChoferes(ttk.Frame):
    def __init__(self, master, app):
        super().__init__(master)
        self.app = app
        self.api = app.api
        # `ventana` que espera `ui_common.consultar_en_hilo`.
        self._consulta_en_curso = False
        self._build()
        self.after(200, self.cargar)

    def _build(self):
        top = tk.Frame(self, bg="#243447")
        top.pack(fill="x", padx=10, pady=8)

        tk.Label(top, text="Habilitacion de choferes", bg="#243447", fg="#ffffff",
                 font=("Segoe UI", 12, "bold")).pack(side="left")

        tk.Label(top, text="Mostrar:", bg="#243447", fg="#cfd8e3",
                 font=("Segoe UI", 9)).pack(side="left", padx=(20, 4))
        self.var_filtro = tk.StringVar(value="Solo pendientes")
        self.cb_filtro = ttk.Combobox(top, textvariable=self.var_filtro, width=17,
                                      state="readonly",
                                      values=[t for _, t in FILTROS])
        self.cb_filtro.pack(side="left")
        self.cb_filtro.bind("<<ComboboxSelected>>", lambda e: self.cargar())

        tk.Label(top, text="Buscar:", bg="#243447", fg="#cfd8e3",
                 font=("Segoe UI", 9)).pack(side="left", padx=(14, 4))
        self.var_buscar = tk.StringVar()
        self.ent_buscar = tk.Entry(top, textvariable=self.var_buscar, width=22,
                                   font=("Segoe UI", 9))
        self.ent_buscar.pack(side="left")
        self.ent_buscar.bind("<Return>", lambda e: self.cargar())

        boton(top, "Ver documentos", self.ver_documentos, color="#9b59b6",
              fg="#ffffff").pack(side="left", padx=4)
        boton(top, "Aprobar", self.aprobar, color="#2ecc71", fg="#1b2a3a").pack(
            side="left", padx=(16, 4))
        boton(top, "Rechazar", self.rechazar, color="#e74c3c",
              fg="#ffffff").pack(side="left", padx=4)
        boton(top, "Actualizar", self.cargar, color="#2f80ed",
              fg="#ffffff").pack(side="left", padx=4)

        self.lbl_resumen = tk.Label(self, text="", bg="#1b2a3a", fg="#ffc107",
                                    font=("Segoe UI", 10, "bold"), anchor="w",
                                    padx=14, pady=6)
        self.lbl_resumen.pack(fill="x")

        self.tabla = Tabla(
            self,
            ["nombre", "email", "telefono", "vehiculo", "matricula", "licencia",
             "documentos", "estado", "fondo", "revisado_por", "motivo"],
            ["Chofer", "Email", "Telefono", "Vehiculo", "Matricula", "Licencia",
             "Fotos", "Estado", "Fondo CUP", "Revisado por", "Motivo"],
            anchos=[160, 210, 120, 150, 90, 100, 60, 105, 100, 160, 200],
            alto=20)
        self.tabla.pack(fill="both", expand=True, padx=10, pady=(0, 10))
        self.tabla.tree.tag_configure("pendiente", background="#fff4d6")
        self.tabla.tree.tag_configure("rechazado", background="#ffebee")
        self.tabla.tree.tag_configure("aprobado", background="#e8f5e9")

    def _filtro_actual(self):
        for valor, texto in FILTROS:
            if texto == self.var_filtro.get():
                return valor
        return ""

    def cargar(self):
        self.api = self.app.api
        estado = self._filtro_actual() or None
        q = self.var_buscar.get().strip() or None
        consultar_en_hilo(
            self,
            lambda api: api.choferes(estado=estado, q=q),
            self._pintar,
            lambda e: self._fallo(e),
            "Consultando choferes...")

    def _fallo(self, e):
        self.app.status("Error: %s" % e.mensaje, error=True)
        messagebox.showerror("Error", str(e.mensaje))

    def _pintar(self, datos):
        self.tabla.limpiar()
        for c in datos.get("choferes", []):
            docs = c.get("documentos") or {}
            subidos = docs.get("subidos", 0)
            total = docs.get("total", 0)
            fotos = "%d/%d" % (subidos, total)
            completo = bool(docs.get("completo"))
            self.tabla.agregar([
                c.get("nombre") or "-", c.get("email") or "-",
                c.get("telefono") or "-", c.get("vehiculo") or "-",
                c.get("matricula") or "-", c.get("licencia") or "-",
                fotos, etiqueta_estado(c.get("estado")), money(c.get("fondo")),
                c.get("revisado_por") or "-", c.get("motivo") or "-",
            ], iid=c["driver_id"], tags=(c.get("estado") or "",))

        incompletos = sum(
            1 for c in datos.get("choferes", [])
            if not (c.get("documentos") or {}).get("completo", True))
        self.lbl_resumen.config(
            text="  Pendientes de aprobar: %d   |   Habilitados: %d   |   "
                 "Rechazados: %d   |   Mostrados: %d   |   Con fotos incompletas: %d"
                 % (datos.get("pendientes", 0), datos.get("aprobados", 0),
                    datos.get("rechazados", 0), datos.get("total", 0), incompletos))
        self.app.status("%d choferes" % datos.get("total", 0))

    def _seleccionado(self):
        iid = self.tabla.seleccion()
        if not iid:
            messagebox.showinfo("Selecciona un chofer", "Seleccione una fila de la tabla.")
            return None
        valores = self.tabla.tree.item(iid, "values")
        return {"driver_id": iid, "nombre": valores[0],
                "estado": valores[7], "fotos": valores[6]}

    def ver_documentos(self):
        """Abre el visor con las 10 fotos del chofer seleccionado."""
        iid = self.tabla.seleccion()
        if not iid:
            messagebox.showinfo("Selecciona un chofer",
                                "Seleccione una fila de la tabla.")
            return
        self.api = self.app.api
        self.app.status("Abriendo documentos...")
        self.update_idletasks()
        try:
            lista = self.api.choferes(estado=None)
            chofer = next((c for c in lista.get("choferes", [])
                           if c["driver_id"] == iid), None)
        except ApiError as e:
            self.app.status("Error: %s" % e.mensaje, error=True)
            messagebox.showerror("Error", str(e.mensaje))
            return
        if not chofer:
            messagebox.showinfo("Documentos", "No se encontro el chofer.")
            return
        self.app.status("Documentos de %s" % chofer.get("nombre"))
        VentanaDocumentos(self, self.api, chofer)

    def aprobar(self):
        ch = self._seleccionado()
        if not ch:
            return
        if ch["estado"] == "APROBADO":
            messagebox.showinfo("Ya aprobado", "%s ya esta habilitado." % ch["nombre"])
            return
        if not messagebox.askyesno("Aprobar chofer",
                                   "Habilitar a %s?\n\nPodra entrar a la app de chofer."
                                   % ch["nombre"]):
            return
        self._cambiar(ch, "aprobado", "Documentos verificados por el administrador")

    def rechazar(self):
        ch = self._seleccionado()
        if not ch:
            return
        if ch["estado"] == "RECHAZADO":
            messagebox.showinfo("Ya rechazado", "%s ya esta rechazado." % ch["nombre"])
            return
        motivo = simpledialog.askstring(
            "Rechazar chofer",
            "Motivo del rechazo de %s (lo vera el soporte):" % ch["nombre"],
            parent=self, show="error") or ""
        if not messagebox.askyesno("Rechazar chofer",
                                   "Rechazar a %s?\n\nNo podra entrar a la app."
                                   % ch["nombre"]):
            return
        self._cambiar(ch, "rechazado", motivo or "Rechazado por el administrador")

    def _cambiar(self, ch, estado, motivo):
        self.app.status("Actualizando %s..." % ch["nombre"])
        self.update_idletasks()
        try:
            r = self.api.cambiar_estado_chofer(ch["driver_id"], estado, motivo)
        except ApiError as e:
            self.app.status("Error: %s" % e.mensaje, error=True)
            messagebox.showerror("Error", str(e.mensaje))
            return
        self.app.status(r.get("message", "Listo"))
        self.cargar()
