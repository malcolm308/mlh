"""Pestana Viajes: tabla con el numero de viajes por dia."""
import tkinter as tk
from datetime import date, timedelta
from tkinter import ttk, messagebox

from api_client import ApiError
from ui_common import Tabla, money, boton

DIAS_SEMANA = ["lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo"]


class TabViajes(ttk.Frame):
    def __init__(self, master, app):
        super().__init__(master)
        self.app = app
        self.api = app.api
        self._build()
        self.after(200, self.cargar)

    def _build(self):
        # --- barra superior ---
        top = tk.Frame(self, bg="#243447")
        top.pack(fill="x", padx=10, pady=8)

        tk.Label(top, text="Viajes por dia", bg="#243447", fg="#ffffff",
                 font=("Segoe UI", 12, "bold")).pack(side="left")

        tk.Label(top, text="Dias:", bg="#243447", fg="#cfd8e3",
                 font=("Segoe UI", 9)).pack(side="left", padx=(20, 4))
        self.var_dias = tk.IntVar(value=7)
        cb = ttk.Combobox(top, textvariable=self.var_dias, width=5, state="readonly",
                         values=[1, 3, 7, 14, 30, 90])
        cb.pack(side="left")
        cb.bind("<<ComboboxSelected>>", lambda e: self.cargar())

        boton(top, "Actualizar", self.cargar, color="#2f80ed", fg="#ffffff").pack(
            side="left", padx=10)
        boton(top, "Exportar CSV", self.exportar, color="#4a5b6c",
              fg="#ffffff").pack(side="left")

        # --- encabezado con totales del dia ---
        self.lbl_hoy = tk.Label(self, text="", bg="#1b2a3a", fg="#ffc107",
                                font=("Segoe UI", 10, "bold"), anchor="w",
                                padx=14, pady=8)
        self.lbl_hoy.pack(fill="x")

        # --- tabla diaria ---
        self.tabla = Tabla(
            self,
            ["dia", "total", "completados", "cancelados", "expirados",
             "solicitados", "facturado", "ticket", "km", "choferes"],
            ["Dia", "Viajes", "Complet.", "Cancel.", "Expir.", "Solicit.",
             "Facturado CUP", "Ticket prom.", "Km", "Choferes"],
            anchos=[110, 70, 85, 78, 70, 80, 120, 110, 90, 85],
            alto=14)
        self.tabla.pack(fill="both", expand=True, padx=10, pady=(0, 6))
        self.tabla.tree.tag_configure("vacio", background="#f2f4f7")
        self.tabla.tree.tag_configure("hoy", background="#fff4d6")
        self.tabla.tree.bind("<Double-1>", self._ver_dia)

        # --- detalle del dia ---
        frame_det = tk.LabelFrame(self, text="Detalle del dia (doble clic en una fila)",
                                  bg="#243447", fg="#ffc107",
                                  font=("Segoe UI", 9, "bold"), padx=8, pady=6)
        frame_det.pack(fill="both", expand=True, padx=10, pady=(0, 10))

        self.detalle = Tabla(
            frame_det,
            ["hora", "estado", "cliente", "chofer", "origen", "destino",
             "vehiculo", "km", "total"],
            ["Hora", "Estado", "Cliente", "Chofer", "Origen", "Destino",
             "Vehiculo", "Km", "Total CUP"],
            anchos=[80, 100, 150, 150, 200, 200, 80, 70, 95],
            alto=7)
        self.detalle.pack(fill="both", expand=True)
        self.detalle.tree.tag_configure("completed", background="#e8f5e9")
        self.detalle.tree.tag_configure("cancelled", background="#ffebee")
        self.detalle.tree.tag_configure("expired", background="#eceff1")

        self.var_estado_dia = tk.StringVar(value="")

    # ---------------- datos ----------------
    def cargar(self):
        self.api = self.app.api
        try:
            dias = int(self.var_dias.get())
        except (TypeError, ValueError):
            dias = 7

        self.app.status("Consultando viajes...")
        self.update_idletasks()
        try:
            datos = self.api.viajes_diarios(dias=dias)
        except ApiError as e:
            self.app.status("Error: %s" % e.mensaje, error=True)
            messagebox.showerror("Error", str(e.mensaje))
            return

        filas = datos.get("dias", [])
        totales = datos.get("totales", {})
        hoy = str(date.today())

        self.tabla.limpiar()
        for f in filas:
            dia = f["dia"]
            try:
                etiqueta = "%s %s" % (DIAS_SEMANA[date.fromisoformat(dia).weekday()][:3],
                                      dia[8:] + "/" + dia[5:7])
            except ValueError:
                etiqueta = dia
            tags = ("hoy",) if dia == hoy else (("vacio",) if f["total"] == 0 else ())
            self.tabla.agregar([
                etiqueta, f["total"], f["completados"], f["cancelados"],
                f["expirados"], f["solicitados"], money(f["facturado"]),
                money(f["ticket_promedio"]), ("%.1f" % f["km_recorridos"]), f["choferes"],
            ], iid=dia, tags=tags)

        prom = (totales.get("completados") or 0) and (
            (totales.get("facturado") or 0) / totales["completados"]) or 0
        self.lbl_hoy.config(
            text="  Ultimos %d dias (%s a %s):  %s viajes  |  %s completados  |  %s cancelados  |  "
                 "%s facturado  |  ticket promedio %s  |  %.1f km"
                 % (dias, datos.get("desde"), datos.get("hasta"),
                    totales.get("viajes", 0), totales.get("completados", 0),
                    totales.get("cancelados", 0), money(totales.get("facturado")),
                    money(prom), totales.get("km_recorridos") or 0))

        self.app.status("%d dias cargados (%s - %s)" % (
            len(filas), datos.get("desde"), datos.get("hasta")))
        if filas:
            self._ver_dia(hoy if any(f["dia"] == hoy for f in filas) else filas[-1]["dia"])

    def _ver_dia(self, dia):
        if not dia:
            return
        self.var_estado_dia.set(dia)
        self.app.status("Cargando viajes de %s..." % dia)
        self.update_idletasks()
        try:
            datos = self.api.viajes_del_dia(dia)
        except ApiError as e:
            self.app.status("Error: %s" % e.mensaje, error=True)
            return

        self.detalle.limpiar()
        for v in datos.get("viajes", []):
            hora = (v.get("requested_at") or "")[11:16]
            estado = v.get("status") or ""
            km = v.get("distance_km")
            self.detalle.agregar([
                hora, estado, v.get("client_id") or "-", v.get("driver_id") or "-",
                (v.get("request_address") or "-")[:60],
                (v.get("dropoff_address") or "-")[:60],
                v.get("vehicle_type") or "-",
                ("%.1f" % km) if km else "-",
                money(v.get("total_fare")) if v.get("total_fare") else "-",
            ], tags=(estado,) if estado in ("completed", "cancelled", "expired") else ())
        self.app.status("Dia %s: %d viajes" % (dia, datos.get("total", 0)))

    # ---------------- export ----------------
    def exportar(self):
        filas = self.tabla.tree.get_children()
        if not filas:
            messagebox.showinfo("Exportar", "No hay datos para exportar.")
            return
        from tkinter import filedialog
        destino = filedialog.asksaveasfilename(
            defaultextension=".csv", filetypes=[("CSV", "*.csv")],
            initialfile="viajes_%s.csv" % date.today())
        if not destino:
            return
        try:
            with open(destino, "w", encoding="utf-8-sig", newline="") as f:
                f.write("dia;viajes;completados;cancelados;expirados;solicitados;"
                        "facturado;ticket_promedio;km;choferes\n")
                for iid in filas:
                    v = self.tabla.tree.item(iid, "values")
                    f.write(";".join(str(x) for x in v) + "\n")
        except Exception as e:
            messagebox.showerror("Exportar", str(e))
            return
        self.app.status("Exportado a %s" % destino)
