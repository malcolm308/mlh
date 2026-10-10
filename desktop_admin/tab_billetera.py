"""Pestana Billetera: recarga de saldo a los choferes."""
import tkinter as tk
from datetime import datetime
from tkinter import ttk, messagebox, simpledialog

from api_client import ApiError
from ui_common import Tabla, money, boton, PanelDesplazable, consultar_en_hilo

METODOS = ["efectivo", "transferencia", "pasarela", "promocion", "ajuste"]


class TabBilletera(ttk.Frame):
    def __init__(self, master, app):
        super().__init__(master)
        self.app = app
        self.api = app.api
        self.seleccionado = None
        # `ventana` que espera `ui_common.consultar_en_hilo`.
        self._consulta_en_curso = False
        self._build()
        self.after(200, self.cargar_movimientos)

    def _build(self):
        # ---------------- izquierda: buscador + recarga ----------------
        # Panel con scroll: si la ventana es baja, el boton de recarga sigue
        # siendo accesible en lugar de quedar cortado fuera de pantalla.
        self.panel = PanelDesplazable(self, ancho=330)
        self.panel.pack(side="left", fill="y", padx=(10, 6), pady=8)
        izq = self.panel.cuerpo

        tk.Label(izq, text="Billetera del chofer", bg="#243447", fg="#ffffff",
                 font=("Segoe UI", 12, "bold")).pack(anchor="w", pady=(0, 10))

        f_bus = tk.Frame(izq, bg="#243447")
        f_bus.pack(fill="x")
        tk.Label(f_bus, text="Buscar chofer", bg="#243447", fg="#cfd8e3",
                 font=("Segoe UI", 9)).pack(anchor="w")
        self.var_buscar = tk.StringVar()
        self.ent_buscar = tk.Entry(f_bus, textvariable=self.var_buscar,
                                   font=("Segoe UI", 10))
        self.ent_buscar.pack(fill="x", ipady=3)
        self.ent_buscar.bind("<Return>", lambda e: self.buscar())

        boton(izq, "Buscar", self.buscar, color="#2f80ed", fg="#ffffff").pack(
            fill="x", pady=(6, 10))

        # resultados
        self.tree_bus = ttk.Treeview(izq, columns=("nombre", "saldo"),
                                     show="headings", height=5, selectmode="browse")
        self.tree_bus.heading("nombre", text="Chofer")
        self.tree_bus.heading("saldo", text="Fondo")
        self.tree_bus.column("nombre", width=180)
        self.tree_bus.column("saldo", width=80, anchor="e")
        self.tree_bus.pack(fill="x")
        self.tree_bus.bind("<<TreeviewSelect>>", self._elegir_busqueda)

        # datos del chofer elegido
        f_info = tk.LabelFrame(izq, text="Chofer seleccionado", bg="#243447",
                               fg="#ffc107", font=("Segoe UI", 9, "bold"),
                               padx=8, pady=6)
        f_info.pack(fill="x", pady=10)
        self.lbl_info = tk.Label(f_info, text="Seleccione un chofer de la lista",
                                 bg="#243447", fg="#cfd8e3", font=("Segoe UI", 9),
                                 justify="left", anchor="w")
        self.lbl_info.pack(fill="x")

        # formulario de recarga
        f_form = tk.LabelFrame(izq, text="Recargar saldo", bg="#243447",
                               fg="#2ecc71", font=("Segoe UI", 9, "bold"),
                               padx=8, pady=8)
        f_form.pack(fill="x", pady=(0, 4))

        self.var_monto = tk.StringVar(value="1000")
        self.var_metodo = tk.StringVar(value=METODOS[0])
        self.var_ref = tk.StringVar()
        self.var_nota = tk.StringVar()

        self._campo(f_form, "Monto (CUP)", self.var_monto)
        tk.Label(f_form, text="Metodo", bg="#243447", fg="#cfd8e3",
                 font=("Segoe UI", 9)).pack(anchor="w")
        cb = ttk.Combobox(f_form, textvariable=self.var_metodo, state="readonly",
                          values=METODOS)
        cb.pack(fill="x", ipady=2)
        self._campo(f_form, "Referencia", self.var_ref)
        self._campo(f_form, "Nota", self.var_nota)

        boton(f_form, "RECARGAR", self.recargar, color="#2ecc71").pack(
            fill="x", pady=(10, 4), ipady=3)
        boton(f_form, "Descontar (debito)", self.descontar,
              color="#4a5b6c", fg="#ffffff").pack(fill="x", pady=(0, 4), ipady=2)

        # ---------------- derecha: movimientos ----------------
        der = tk.Frame(self, bg="#243447")
        der.pack(side="left", fill="both", expand=True, padx=(0, 10), pady=8)

        barra = tk.Frame(der, bg="#243447")
        barra.pack(fill="x", pady=(0, 6))
        tk.Label(barra, text="Movimientos", bg="#243447", fg="#ffffff",
                 font=("Segoe UI", 12, "bold")).pack(side="left")
        self.var_todos = tk.IntVar(value=0)
        chk = tk.Checkbutton(barra, text="ver todos los choferes",
                             variable=self.var_todos, command=self.cargar_movimientos,
                             bg="#243447", fg="#cfd8e3", activebackground="#243447",
                             activeforeground="#ffffff", selectcolor="#243447",
                             font=("Segoe UI", 9))
        chk.pack(side="left", padx=12)
        boton(barra, "Actualizar", self.cargar_movimientos, color="#2f80ed",
              fg="#ffffff").pack(side="right")

        self.lbl_resumen = tk.Label(der, text="", bg="#1b2a3a", fg="#ffc107",
                                    font=("Segoe UI", 10, "bold"), anchor="w",
                                    padx=12, pady=6)
        self.lbl_resumen.pack(fill="x", pady=(0, 6))

        self.tabla = Tabla(
            der,
            ["fecha", "chofer", "tipo", "monto", "anterior", "nuevo",
             "metodo", "referencia", "admin", "nota"],
            ["Fecha", "Chofer", "Tipo", "Monto", "Saldo anterior", "Saldo nuevo",
             "Metodo", "Referencia", "Hecho por", "Nota"],
            anchos=[135, 150, 85, 95, 115, 105, 100, 100, 160, 180],
            alto=20)
        self.tabla.pack(fill="both", expand=True)
        self.tabla.tree.tag_configure("recarga", background="#e8f5e9")
        self.tabla.tree.tag_configure("debito", background="#ffebee")

    def _campo(self, parent, etiqueta, variable):
        tk.Label(parent, text=etiqueta, bg="#243447", fg="#cfd8e3",
                 font=("Segoe UI", 8)).pack(anchor="w", pady=(4, 0))
        tk.Entry(parent, textvariable=variable, font=("Segoe UI", 10),
                 bg="#1b2a3a", fg="#ffffff", insertbackground="#ffffff",
                 relief="flat").pack(fill="x", ipady=2)

    # ---------------- datos ----------------
    def buscar(self):
        self.api = self.app.api
        q = self.var_buscar.get().strip() or None
        consultar_en_hilo(
            self,
            lambda api: api.choferes_busqueda(q),
            self._pintar_busqueda,
            lambda e: self._fallo_busqueda(e),
            "Buscando choferes...")

    def _fallo_busqueda(self, e):
        self.app.status("Error: %s" % e.mensaje, error=True)
        messagebox.showerror("Error", str(e.mensaje))

    def _pintar_busqueda(self, res):
        self.tree_bus.delete(*self.tree_bus.get_children())
        for c in res:
            self.tree_bus.insert("", "end", iid=c["driver_id"],
                                 values=(c.get("nombre") or c.get("email"),
                                         money(c.get("saldo"))))
        if not res:
            self.lbl_info.config(text="Sin resultados para '%s'" % self.var_buscar.get())
        self.app.status("%d resultados" % len(res))
        if res:
            self.tree_bus.selection_set(res[0]["driver_id"])
            self.tree_bus.focus(res[0]["driver_id"])
            self._elegir_busqueda()

    def _elegir_busqueda(self, _event=None):
        sel = self.tree_bus.selection()
        if not sel:
            return
        driver_id = sel[0]
        self.api = self.app.api
        try:
            info = self.api.saldo(driver_id)
        except ApiError as e:
            messagebox.showerror("Error", str(e.mensaje))
            return
        self.seleccionado = info
        self.lbl_info.config(
            text="Nombre: %s\nEmail: %s\nChofer ID: %s\nFondo actual: %s CUP"
                 % (info.get("nombre") or "-", info.get("email") or "-",
                    info["driver_id"], money(info.get("saldo"))))
        if not self.var_todos.get():
            self.cargar_movimientos()

    def cargar_movimientos(self):
        self.api = self.app.api
        todos = self.var_todos.get()
        driver_id = None if todos else (self.seleccionado or {}).get("driver_id")

        def consulta(api):
            # Son dos peticiones encadenadas a proposito, en el mismo hilo
            # auxiliar: separarlas duplicaria la espera si el backend esta
            # despertando, que es justo lo que se quiere evitar.
            return (api.movimientos(driver_id=driver_id, limit=200),
                    api.resumen_billetera())

        consultar_en_hilo(
            self, consulta, self._pintar, lambda e: self._fallo(e),
            "Cargando movimientos...")

    def _fallo(self, e):
        self.app.status("Error: %s" % e.mensaje, error=True)

    def _pintar(self, datos):
        movs, resumen = datos
        nombres = {}
        driver_id = (self.seleccionado or {}).get("driver_id")
        if not self.var_todos.get() and driver_id:
            nombres[driver_id] = (self.seleccionado or {}).get("nombre") or driver_id

        self.tabla.limpiar()
        for m in movs:
            fecha = m.get("created_at") or ""
            self.tabla.agregar([
                fecha[:16].replace("T", " "),
                nombres.get(m.get("driver_id"), m.get("driver_id") or "-"),
                m.get("tipo"), money(m.get("monto")),
                money(m.get("saldo_anterior")), money(m.get("saldo_nuevo")),
                m.get("metodo") or "-", m.get("referencia") or "-",
                m.get("admin_email") or "-", m.get("nota") or "-",
            ], tags=(m.get("tipo") or "",))

        self.lbl_resumen.config(
            text="  Hoy: %s CUP recargados (%d recargas)  |  %s CUP descontados (%d debitos)"
                 % (money(resumen.get("recargado")), resumen.get("num_recargas", 0),
                    money(resumen.get("descontado")), resumen.get("num_debitos", 0)))
        self.app.status("%d movimientos" % len(movs))

    # ---------------- acciones ----------------
    def _pedir_monto(self, titulo):
        valor = simpledialog.askstring(titulo, "Monto en CUP:", parent=self)
        if valor is None:
            return None
        try:
            monto = float(valor.replace(",", "").replace(" ", ""))
        except ValueError:
            messagebox.showerror("Monto", "El monto debe ser un numero.")
            return None
        if monto <= 0:
            messagebox.showerror("Monto", "El monto debe ser mayor que cero.")
            return None
        return round(monto, 2)

    def recargar(self):
        if not self.seleccionado:
            messagebox.showinfo("Billetera", "Primero seleccione un chofer.")
            return
        try:
            monto = float(self.var_monto.get().replace(",", "").replace(" ", ""))
        except ValueError:
            messagebox.showerror("Monto", "El monto debe ser un numero.")
            return
        if monto <= 0:
            messagebox.showerror("Monto", "El monto debe ser mayor que cero.")
            return

        ch = self.seleccionado
        if not messagebox.askyesno(
                "Confirmar recarga",
                "Recargar %s CUP a:\n\n%s (%s)\n\nSaldo actual: %s CUP"
                % (money(monto), ch.get("nombre"), ch.get("email"),
                   money(ch.get("saldo")))):
            return

        self.app.status("Registrando recarga...")
        self.update_idletasks()
        try:
            r = self.api.recarga(driver_id=ch["driver_id"], monto=monto,
                                 metodo=self.var_metodo.get(),
                                 referencia=self.var_ref.get().strip() or None,
                                 nota=self.var_nota.get().strip() or None)
        except ApiError as e:
            self.app.status("Error: %s" % e.mensaje, error=True)
            messagebox.showerror("Error", str(e.mensaje))
            return

        self.var_ref.set("")
        self.var_nota.set("")
        messagebox.showinfo("Recarga hecha",
                            "%s\n\nNuevo fondo: %s CUP"
                            % (r.get("message"), money(r.get("saldo_nuevo"))))
        self._elegir_busqueda()
        self.cargar_movimientos()
        self.app.status("Recarga registrada")

    def descontar(self):
        if not self.seleccionado:
            messagebox.showinfo("Billetera", "Primero seleccione un chofer.")
            return
        ch = self.seleccionado
        monto = self._pedir_monto("Descontar saldo")
        if monto is None:
            return
        nota = simpledialog.askstring("Descontar saldo", "Motivo:", parent=self) or ""
        if not messagebox.askyesno("Confirmar debito",
                                   "Descontar %s CUP a %s?\n\nSaldo actual: %s CUP"
                                   % (money(monto), ch.get("nombre"),
                                      money(ch.get("saldo")))):
            return
        self.app.status("Registrando debito...")
        self.update_idletasks()
        try:
            r = self.api.descargo(driver_id=ch["driver_id"], monto=monto,
                                  nota=nota or "Ajuste del administrador")
        except ApiError as e:
            self.app.status("Error: %s" % e.mensaje, error=True)
            messagebox.showerror("Error", str(e.mensaje))
            return
        messagebox.showinfo("Debito hecho",
                            "%s\n\nNuevo fondo: %s CUP"
                            % (r.get("message"), money(r.get("saldo_nuevo"))))
        self._elegir_busqueda()
        self.cargar_movimientos()
        self.app.status("Debito registrado")
