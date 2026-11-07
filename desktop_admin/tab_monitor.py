"""Pestana Monitor de Viajes: control manual de emergencia.

Para cuando el chofer se queda sin conexion a mitad de un viaje: desde aqui el
administrador puede forzar el inicio o el fin del viaje sin depender del
telefono del chofer.

El precio NO se escribe a mano. "Forzar Fin" llama al mismo endpoint que usa el
chofer al completar (`complete_trip`), asi que distancia, tiempo, comisiones,
descuentos y bono se calculan igual. Lo unico que cambia es quien pulsa el
boton; el backend devuelve `precio_final` y el panel lo muestra para que el
administrador se lo comunique al chofer o al pasajero.
"""
import tkinter as tk
from tkinter import ttk, messagebox

from ui_common import Tabla, boton, money, consultar_en_hilo

# Cada cuanto se refresca sola la tabla mientras la pestana esta abierta.
REFRESCO_MS = 15000

ESTADOS = {
    "requested": ("Solicitado", "#ffc107"),
    "accepted": ("Aceptado", "#2f80ed"),
    "driver_arrived": ("Chofer llego", "#8e44ad"),
    "in_progress": ("En curso", "#27ae60"),
}


class TabMonitor(ttk.Frame):
    def __init__(self, master, app):
        super().__init__(master)
        self.app = app
        self.api = app.api
        # `consultar_en_hilo` escribe aqui para no lanzar dos consultas a la vez.
        self._consulta_en_curso = False
        self._viajes = {}
        self._auto = None
        self._build()
        # La carga inicial la dispara main.py al abrir la pestana (carga
        # perezosa); el refresco automatico sigue activo si "Auto" esta puesto.
        self._programar_refresco()

    # ---------------- construccion ----------------

    def _build(self):
        top = tk.Frame(self, bg="#243447")
        top.pack(fill="x", padx=10, pady=8)

        tk.Label(top, text="Monitor de viajes", bg="#243447", fg="#ffffff",
                 font=("Segoe UI", 12, "bold")).pack(side="left")

        tk.Label(top,
                 text="Control manual para emergencias: úsalo solo si el chofer "
                      "no puede actualizar el viaje desde su teléfono.",
                 bg="#243447", fg="#9fb3c8", font=("Segoe UI", 9)
                 ).pack(side="left", padx=(16, 0))

        boton(top, "Actualizar", self.cargar, ancho=10).pack(side="right")

        self.var_auto = tk.IntVar(value=1)
        tk.Checkbutton(top, text="Auto", variable=self.var_auto,
                       bg="#243447", fg="#cfd8e3",
                       activebackground="#243447", activeforeground="#ffffff",
                       selectcolor="#1b2a3a", font=("Segoe UI", 9),
                       command=self._programar_refresco).pack(side="right", padx=8)

        self.tabla = Tabla(
            self,
            columnas=("id", "cliente", "chofer", "estado", "origen", "destino",
                      "estimado", "hora"),
            titulos=("ID", "Cliente", "Chofer", "Estado", "Origen", "Destino",
                     "Estimado", "Solicitado"),
            anchos=(150, 150, 150, 100, 170, 170, 90, 70),
            stretch=(False, True, True, False, True, True, False, False),
            alto=16,
        )
        self.tabla.pack(fill="both", expand=True, padx=10, pady=(0, 6))
        self.tabla.tree.bind("<<TreeviewSelect>>", lambda _e: self._al_seleccionar())
        self.tabla.tree.tag_configure("in_progress", foreground="#27ae60")
        self.tabla.tree.tag_configure("requested", foreground="#b8860b")

        pie = tk.Frame(self, bg="#1b2a3a")
        pie.pack(fill="x", padx=10, pady=(0, 10))

        self.lbl_sel = tk.Label(pie, text="Selecciona un viaje de la tabla",
                                bg="#1b2a3a", fg="#9fb3c8", anchor="w",
                                font=("Segoe UI", 9))
        self.lbl_sel.pack(side="left", padx=10, pady=8)

        self.btn_fin = boton(pie, "Forzar Fin", self.forzar_fin, color="#e74c3c",
                             fg="#ffffff", ancho=14)
        self.btn_fin.pack(side="right", padx=(4, 10), pady=6)
        self.btn_inicio = boton(pie, "Forzar Inicio", self.forzar_inicio,
                                color="#27ae60", fg="#ffffff", ancho=14)
        self.btn_inicio.pack(side="right", padx=4, pady=6)

        self._al_seleccionar()

    # ---------------- datos ----------------

    def _programar_refresco(self):
        if self._auto is not None:
            try:
                self.after_cancel(self._auto)
            except Exception:
                pass
            self._auto = None
        if self.var_auto.get():
            self._auto = self.after(REFRESCO_MS, self._refresco_auto)

    def _refresco_auto(self):
        self._auto = None
        # Si hay una consulta en vuelo no se lanza otra; la tabla se repinta
        # cuando termine. `_pintar` conserva la fila seleccionada.
        if not self._consulta_en_curso and self.winfo_ismapped():
            self.cargar()
        self._programar_refresco()

    def cargar(self):
        if self._consulta_en_curso:
            return
        consultar_en_hilo(
            self,
            lambda api: api.viajes_activos(),
            self._pintar,
            self._fallo,
            "Consultando viajes activos...")

    def _fallo(self, e):
        self.app.status("Error: %s" % e.mensaje, error=True)
        messagebox.showerror("Monitor de viajes", str(e.mensaje))

    def _pintar(self, datos):
        viajes = (datos or {}).get("viajes", [])
        self._viajes = {v.get("trip_id"): v for v in viajes}
        seleccionado = self.tabla.seleccion()

        self.tabla.limpiar()
        for v in viajes:
            tid = v.get("trip_id")
            estado = v.get("status") or ""
            etiqueta = ESTADOS.get(estado, (estado, "#cfd8e3"))[0]
            estimado = v.get("precio_estimado")
            hora = (v.get("requested_at") or "")[11:16]
            self.tabla.agregar([
                tid,
                v.get("client_name") or (v.get("client_id") or "-")[:10],
                v.get("driver_name") or (v.get("driver_id") or "sin asignar"),
                etiqueta,
                (v.get("request_address") or "-")[:45],
                (v.get("dropoff_address") or "-")[:45],
                money(estimado) if estimado else "-",
                hora or "-",
            ], iid=tid, tags=(estado,) if estado in ESTADOS else ())

        if seleccionado and seleccionado in self._viajes:
            try:
                self.tabla.tree.selection_set(seleccionado)
            except Exception:
                pass

        self.app.status("%d viajes activos" % len(viajes))
        self._al_seleccionar()

    # ---------------- acciones ----------------

    def _al_seleccionar(self):
        tid = self.tabla.seleccion()
        viaje = self._viajes.get(tid) if tid else None
        if not viaje:
            self.lbl_sel.config(text="Selecciona un viaje de la tabla", fg="#9fb3c8")
            self.btn_inicio.config(state="disabled")
            self.btn_fin.config(state="disabled")
            return

        estado = viaje.get("status") or ""
        cliente = viaje.get("client_name") or viaje.get("client_id") or "-"
        self.lbl_sel.config(
            text="Viaje %s  |  %s  |  estado: %s"
                 % (tid, cliente, ESTADOS.get(estado, (estado, ""))[0]),
            fg="#cfd8e3")
        self.btn_inicio.config(
            state="normal" if estado in ("requested", "accepted", "driver_arrived") else "disabled")
        self.btn_fin.config(
            state="normal" if estado in ("requested", "accepted", "driver_arrived",
                                         "in_progress") else "disabled")

    def _viaje_para_accion(self, accion):
        tid = self.tabla.seleccion()
        viaje = self._viajes.get(tid) if tid else None
        if not viaje:
            messagebox.showinfo("Monitor de viajes",
                               "Primero selecciona un viaje de la tabla.")
            return None
        if not viaje.get("driver_id"):
            messagebox.showwarning(
                "Monitor de viajes",
                "Ese viaje todavía no tiene chofer asignado.\n"
                "Asignale un chofer antes de %s." % accion)
            return None
        return viaje

    def forzar_inicio(self):
        if self._consulta_en_curso:
            return
        viaje = self._viaje_para_accion("forzar el inicio")
        if not viaje:
            return
        tid = viaje["trip_id"]
        if not messagebox.askyesno(
                "Forzar inicio",
                "¿Marcar el viaje %s como EN CURSO?\n\n"
                "El chofer verá el cambio en su app la próxima vez que consulte."
                % tid):
            return

        self.app.status("Forzando inicio del viaje %s..." % tid)
        consultar_en_hilo(
            self,
            lambda api: api.forzar_inicio(tid),
            self._iniciado,
            self._fallo_accion,
            "Forzando inicio...")

    def _iniciado(self, datos):
        tid = (datos or {}).get("trip_id", "")
        self.app.status("Viaje %s en curso (forzado)" % tid)
        messagebox.showinfo(
            "Viaje iniciado",
            "El viaje %s quedó EN CURSO.\n\n%s"
            % (tid, (datos or {}).get("message", "")))
        self.cargar()

    def forzar_fin(self):
        if self._consulta_en_curso:
            return
        viaje = self._viaje_para_accion("forzar el fin")
        if not viaje:
            return
        tid = viaje["trip_id"]
        if not messagebox.askyesno(
                "Forzar fin",
                "¿Completar el viaje %s?\n\n"
                "El backend calculará el precio final con las tarifas vigentes, "
                "la distancia y el tiempo transcurrido. No se introduce ningún "
                "precio a mano." % tid):
            return

        self.app.status("Completando viaje %s..." % tid)
        consultar_en_hilo(
            self,
            lambda api: api.forzar_fin(tid),
            self._completado,
            self._fallo_accion,
            "Calculando precio final...")

    def _completado(self, datos):
        datos = datos or {}
        tid = datos.get("trip_id", "")
        precio = datos.get("precio_final")
        moneda = datos.get("moneda") or "CUP"
        km = datos.get("distancia_km")
        segs = datos.get("duracion_segundos")
        descuento = datos.get("descuento_cliente")

        detalle = ["Viaje: %s" % tid,
                   "Precio final calculado por el backend: %s %s"
                   % (money(precio), moneda)]
        if km is not None:
            detalle.append("Distancia: %s km" % km)
        if segs is not None:
            detalle.append("Duración: %d min" % (int(segs) // 60))
        if descuento:
            detalle.append("Descuento aplicado: %s" % money(descuento))

        self.lbl_sel.config(
            text="Viaje %s COMPLETADO  |  precio final: %s %s"
                 % (tid, money(precio), moneda),
            fg="#27ae60")
        self.app.status("Viaje %s completado: %s %s"
                        % (tid, money(precio), moneda))
        messagebox.showinfo("Viaje completado", "\n".join(detalle))
        self.cargar()

    def _fallo_accion(self, e):
        self.app.status("Error: %s" % e.mensaje, error=True)
        messagebox.showerror("Monitor de viajes", str(e.mensaje))
        self._al_seleccionar()
