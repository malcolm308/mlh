"""Widgets compartidos por las pestanas del panel."""
import tkinter as tk
from tkinter import ttk


def money(v):
    try:
        v = float(v or 0)
    except (TypeError, ValueError):
        return "-"
    if v == int(v):
        return "{:,}".format(int(v))
    return "{:,.2f}".format(v)


class Tabla(ttk.Frame):
    """Treeview con scroll vertical y metodo para llenarla."""

    def __init__(self, master, columnas, titulos, anchos=None, stretch=None, alto=12):
        super().__init__(master)
        self.columnas = columnas

        self.tree = ttk.Treeview(self, columns=columnas, show="headings",
                                 selectmode="browse", height=alto)
        for i, col in enumerate(columnas):
            ancho = (anchos[i] if anchos and i < len(anchos) else 110)
            estira = (stretch[i] if stretch and i < len(stretch) else False)
            self.tree.heading(col, text=titulos[i])
            self.tree.column(col, width=ancho, anchor="w", stretch=estira,
                             minwidth=60)

        vs = ttk.Scrollbar(self, orient="vertical", command=self.tree.yview)
        hs = ttk.Scrollbar(self, orient="horizontal", command=self.tree.xview)
        self.tree.configure(yscrollcommand=vs.set, xscrollcommand=hs.set)

        self.tree.grid(row=0, column=0, sticky="nsew")
        vs.grid(row=0, column=1, sticky="ns")
        hs.grid(row=1, column=0, sticky="ew")
        self.rowconfigure(0, weight=1)
        self.columnconfigure(0, weight=1)

    def limpiar(self):
        self.tree.delete(*self.tree.get_children())

    def agregar(self, valores, iid=None, tags=None):
        self.tree.insert("", "end", iid=iid, values=valores, tags=tags or ())

    def seleccion(self):
        sel = self.tree.selection()
        return sel[0] if sel else None


def etiqueta_estado(estado):
    return {"pendiente": "PENDIENTE", "aprobado": "APROBADO",
            "rechazado": "RECHAZADO"}.get(estado, (estado or "").upper())


def boton(parent, texto, comando, color="#ffc107", fg="#1b2a3a", ancho=None):
    return tk.Button(parent, text=texto, command=comando, bg=color, fg=fg,
                     activebackground=color, activeforeground=fg,
                     font=("Segoe UI", 9, "bold"), relief="flat",
                     cursor="hand2", padx=12, pady=4, width=ancho)


class PanelDesplazable(ttk.Frame):
    """Columna vertical con scroll.

    Tkinter descarta los widgets que no caben en la ventana cuando se usa
    pack(); esto garantiza que siempre se vean, sin importar el tamano.
    """

    def __init__(self, master, bg="#243447", ancho=330, scroll_h=16):
        super().__init__(master)
        self.pack_propagate(False)
        self.configure(width=ancho + scroll_h)

        self.canvas = tk.Canvas(self, width=ancho, bg=bg, highlightthickness=0,
                                bd=0)
        self.scroll = ttk.Scrollbar(self, orient="vertical", command=self.canvas.yview)
        self.canvas.configure(yscrollcommand=self.scroll.set)

        self.canvas.pack(side="left", fill="both", expand=True)
        self.scroll.pack(side="right", fill="y")

        self.cuerpo = tk.Frame(self.canvas, bg=bg)
        self._ventana = self.canvas.create_window((0, 0), window=self.cuerpo, anchor="nw")

        self.cuerpo.bind("<Configure>", self._on_config)
        self.canvas.bind("<Configure>", self._on_canvas)
        for w in (self.canvas, self.cuerpo):
            w.bind("<MouseWheel>", self._on_wheel)

    def _on_config(self, _event=None):
        self.canvas.configure(scrollregion=self.canvas.bbox("all"))

    def _on_canvas(self, event):
        self.canvas.itemconfigure(self._ventana, width=event.width)

    def _on_wheel(self, event):
        self.canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")

    def ir_arriba(self):
        self.canvas.yview_moveto(0)
