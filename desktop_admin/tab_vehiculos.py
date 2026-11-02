"""Pestana Aprobacion de Vehiculos: columna "Mi Garaje" de cada chofer.

Cada chofer puede registrar varios vehiculos (uno nuevo entra `pendiente`).
Aqui se revisan: Aprobar o Rechazar marca el estado en la base y el chofer
solo puede poner "En linea" un vehiculo aprobado.

La estructura replica `tab_choferes.py`: tabla + filtro + botones, con las
consultas HTTP en un hilo aparte para no congelar Tkinter.
"""
import tkinter as tk
from tkinter import ttk, messagebox, simpledialog

from api_client import ApiError
from ui_common import Tabla, etiqueta_estado, boton, consultar_en_hilo

FILTROS = [("pendiente", "Solo pendientes"), ("aprobado", "Solo aprobados"),
           ("rechazado", "Solo rechazados"), ("", "Todos")]


class TabVehiculos(ttk.Frame):
    def __init__(self, master, app):
        super().__init__(master)
        self.app = app
        self.api = app.api
        self._consulta_en_curso = False
        self._build()
        self.after(200, self.cargar)

    def _build(self):
        top = tk.Frame(self, bg="#243447")
        top.pack(fill="x", padx=10, pady=8)

        tk.Label(top, text="Aprobacion de vehiculos (Mi Garaje)",
                 bg="#243447", fg="#ffffff",
                 font=("Segoe UI", 12, "bold")).pack(side="left")

        tk.Label(top, text="Mostrar:", bg="#243447", fg="#cfd8e3",
                 font=("Segoe UI", 9)).pack(side="left", padx=(20, 4))
        self.var_filtro = tk.StringVar(value="Solo pendientes")
        self.cb_filtro = ttk.Combobox(top, textvariable=self.var_filtro,
                                      width=17, state="readonly",
                                      values=[t for _, t in FILTROS])
        self.cb_filtro.pack(side="left")
        self.cb_filtro.bind("<<ComboboxSelected>>", lambda e: self.cargar())

        boton(top, "Aprobar", self.aprobar, color="#2ecc71",
              fg="#1b2a3a").pack(side="left", padx=(16, 4))
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
            ["chofer", "email", "telefono", "tipo", "marca", "modelo",
             "matricula", "estado", "creado", "motivo", "id"],
            ["Chofer", "Email", "Telefono", "Tipo", "Marca", "Modelo",
             "Matricula", "Estado", "Enviado", "Motivo", "ID"],
            anchos=[150, 190, 110, 90, 100, 100, 95, 95, 115, 180, 240],
            alto=20)
        self.tabla.pack(fill="both", expand=True, padx=10, pady=(0, 10))
        self.tabla.tree.tag_configure("pendiente", background="#fff4d6")
        self.tabla.tree.tag_configure("rechazado", background="#ffebee")
        self.tabla.tree.tag_configure("aprobado", background="#e8f5e9")
        # La columna ID es util para copiarla al soporte, no para leerla: va
        # al final y en gris via el tag del propio Treeview.
        self.tabla.tree.column("id", stretch=False)
        self.tabla.tree.column("motivo", stretch=True)

    def _filtro_actual(self):
        for valor, texto in FILTROS:
            if texto == self.var_filtro.get():
                return valor
        return ""

    def cargar(self):
        self.api = self.app.api
        estado = self._filtro_actual() or None
        consultar_en_hilo(
            self,
            lambda api: api.vehiculos(estado=estado),
            self._pintar,
            self._fallo,
            "Consultando vehiculos...")

    def _fallo(self, e):
        self.app.status("Error: %s" % e.mensaje, error=True)
        messagebox.showerror("Error", str(e.mensaje))

    def _pintar(self, datos):
        self.tabla.limpiar()
        for v in datos.get("vehiculos", []):
            self.tabla.agregar([
                v.get("chofer") or "-", v.get("email") or "-",
                v.get("telefono") or "-",
                (v.get("tipo_vehiculo") or "-"),
                v.get("marca") or "-", v.get("modelo") or "-",
                v.get("matricula") or "-",
                etiqueta_estado(v.get("estado")),
                (v.get("creado") or "-")[:16].replace("T", " "),
                v.get("motivo") or "-", v.get("id") or "-",
            ], iid=v["id"], tags=(v.get("estado") or "",))

        pendientes = sum(1 for v in datos.get("vehiculos", [])
                         if v.get("estado") == "pendiente")
        aprobados = sum(1 for v in datos.get("vehiculos", [])
                        if v.get("estado") == "aprobado")
        rechazados = sum(1 for v in datos.get("vehiculos", [])
                         if v.get("estado") == "rechazado")
        self.lbl_resumen.config(
            text="  Pendientes: %d   |   Aprobados: %d   |   Rechazados: %d   "
                 "|   Mostrados: %d"
                 % (pendientes, aprobados, rechazados, datos.get("total", 0)))
        self.app.status("%d vehiculos" % datos.get("total", 0))

    def _seleccionado(self):
        iid = self.tabla.seleccion()
        if not iid:
            messagebox.showinfo("Selecciona un vehiculo",
                                "Seleccione una fila de la tabla.")
            return None
        valores = self.tabla.tree.item(iid, "values")
        if not valores or len(valores) < 8:
            return None
        return {
            "id": iid,
            "chofer": valores[0],
            "estado": valores[7],
        }

    def aprobar(self):
        v = self._seleccionado()
        if not v:
            return
        if v["estado"] == "APROBADO" or v["estado"] == "Aprobado":
            messagebox.showinfo("Ya aprobado",
                                "Ese vehiculo ya esta aprobado.")
            return
        if not messagebox.askyesno(
                "Aprobar vehiculo",
                "Aprobar el vehiculo de %s?\n\nEl chofer podra ponerlo "
                "'En linea' y recibir los viajes de su tipo." % v["chofer"]):
            return
        self._cambiar(v, "aprobado", "")

    def rechazar(self):
        v = self._seleccionado()
        if not v:
            return
        if v["estado"] in ("RECHAZADO", "Rechazado"):
            messagebox.showinfo("Ya rechazado", "Ese vehiculo ya fue rechazado.")
            return
        motivo = simpledialog.askstring(
            "Rechazar vehiculo",
            "Motivo del rechazo (lo vera el chofer):",
            parent=self, show="error") or ""
        if not messagebox.askyesno(
                "Rechazar vehiculo",
                "Rechazar el vehiculo de %s?" % v["chofer"]):
            return
        self._cambiar(v, "rechazado", motivo)

    def _cambiar(self, v, decision, motivo):
        self.app.status("Actualizando vehiculo de %s..." % v["chofer"])
        self.update_idletasks()
        try:
            r = self.api.cambiar_estado_vehiculo(v["id"], decision, motivo)
        except ApiError as e:
            self.app.status("Error: %s" % e.mensaje, error=True)
            messagebox.showerror("Error", str(e.mensaje))
            return
        mensaje = r.get("message") if isinstance(r, dict) else None
        self.app.status(mensaje or "Listo")
        self.cargar()
