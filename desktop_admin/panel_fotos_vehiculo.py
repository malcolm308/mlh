"""Visor y revision de las 5 fotos de un vehiculo del garaje.

Replica `documentos_window.py`: grilla con miniatura (Pillow si esta
instalado), estado por foto y botones Aprobar / Rechazar que llaman al
backend (`PUT /admin/vehicles/{id}/fotos/{campo}/revisar`). Cuando todas las
obligatorias quedan aprobadas el backend aprueba el vehiculo solo.
"""
import os
import subprocess
import tempfile
import tkinter as tk
from tkinter import messagebox

from api_client import ApiClient, ApiError

try:
    from PIL import Image, ImageOps, ImageTk
    HAY_PILLOW = True
except ImportError:  # pragma: no cover
    HAY_PILLOW = False

try:
    import pillow_heif
    pillow_heif.register_heif_opener()
    HAY_HEIC = True
except Exception:  # pragma: no cover
    HAY_HEIC = False

ANCHO_MINI, ALTO_MINI = 150, 130

# Mismos (campo, etiqueta) que el backend define en FOTOS_VEHICULO
FOTOS_VEHICULO = [
    ("vehiculo_exterior_frente", "Vehiculo por fuera (delante)"),
    ("vehiculo_exterior_atras", "Vehiculo por fuera (atras)"),
    ("vehiculo_interior_frente", "Vehiculo por dentro (delante)"),
    ("vehiculo_interior_atras", "Vehiculo por dentro (atras)"),
    ("circulacion", "Circulacion del vehiculo"),
]


class VentanaFotosVehiculo(tk.Toplevel):
    def __init__(self, master, api: ApiClient, vehiculo: dict):
        super().__init__(master)
        self.api = api
        self.vehiculo = vehiculo
        self.rutas = {}
        self.title("Fotos del vehiculo - %s" % (vehiculo.get("chofer") or "-"))
        self.configure(bg="#1b2a3a")
        self.geometry("1060x720")

        cabecera = tk.Frame(self, bg="#243447", height=54)
        cabecera.pack(fill="x")
        tk.Label(
            cabecera,
            text="%s %s   |   Chapa: %s   |   Estado: %s" % (
                vehiculo.get("marca") or "-", vehiculo.get("modelo") or "-",
                vehiculo.get("matricula") or "-",
                vehiculo.get("estado") or "-"),
            bg="#243447", fg="#ffffff", font=("Segoe UI", 12, "bold")).pack(
                side="left", padx=14)

        self.lbl_resumen = tk.Label(self, text="Cargando fotos...",
                                    bg="#1b2a3a", fg="#ffc107",
                                    font=("Segoe UI", 10, "bold"),
                                    anchor="w", padx=14, pady=8)
        self.lbl_resumen.pack(fill="x")

        self.canvas = tk.Canvas(self, bg="#1b2a3a", highlightthickness=0)
        vs = tk.Scrollbar(self, orient="vertical", command=self.canvas.yview)
        self.canvas.configure(yscrollcommand=vs.set)
        self.canvas.pack(side="left", fill="both", expand=True,
                         padx=(10, 0), pady=(0, 10))
        vs.pack(side="right", fill="y", padx=(0, 10), pady=(0, 10))
        self.marco = tk.Frame(self.canvas, bg="#1b2a3a")
        self._ventana = self.canvas.create_window((0, 0), window=self.marco,
                                                  anchor="nw")
        self.marco.bind("<Configure>",
                        lambda e: self.canvas.configure(
                            scrollregion=self.canvas.bbox("all")))
        self.canvas.bind("<Configure>",
                         lambda e: self.canvas.itemconfigure(
                             self._ventana, width=e.width))
        self.canvas.bind("<MouseWheel>",
                         lambda e: self.canvas.yview_scroll(
                             int(-1 * (e.delta / 120)), "units"))

        self.after(100, self.cargar)
        self.bind("<Escape>", lambda e: self.destroy())

    def cargar(self):
        fotos = self.vehiculo.get("fotos") or {}
        faltan = self.vehiculo.get("fotos_faltantes") or []
        pendientes = [c for c, i in fotos.items()
                      if (i.get("estado") or "pendiente") == "pendiente"]
        rechazadas = [c for c, i in fotos.items()
                      if i.get("estado") == "rechazado"]
        if faltan:
            color, txt = "#e74c3c", "Faltan: " + ", ".join(
                dict(FOTOS_VEHICULO).get(c, c) for c in faltan)
        elif pendientes:
            color, txt = "#ffc107", "En revision: %d foto(s)" % len(pendientes)
        elif rechazadas:
            color, txt = "#e74c3c", "Rechazadas: %d" % len(rechazadas)
        else:
            color, txt = "#2ecc71", "Todas las fotos aprobadas"
        self.lbl_resumen.config(text="  " + txt, fg=color)

        for w in self.marco.winfo_children():
            w.destroy()
        for i, (campo, etiqueta) in enumerate(FOTOS_VEHICULO):
            fila, col = divmod(i, 2)
            self._tarjeta(fila, col, campo, etiqueta,
                          fotos.get(campo) or {})

    def _tarjeta(self, fila, col, campo, etiqueta, info):
        archivo = info.get("archivo") or ""
        estado = (info.get("estado") or ("pendiente" if archivo else "falta"))
        borde = {"aprobado": "#2ecc71", "rechazado": "#e74c3c"}.get(
            estado, "#ffc107" if archivo else "#e74c3c")
        caja = tk.Frame(self.marco, bg="#243447",
                        highlightbackground=borde, highlightthickness=2,
                        width=480, height=190)
        caja.grid(row=fila, column=col, padx=8, pady=8, sticky="nsew")
        caja.grid_propagate(False)

        marco_img = tk.Frame(caja, bg="#243447")
        marco_img.pack(side="left", padx=8, pady=8)
        ruta = None
        if archivo:
            ruta = self._descargar(archivo)
            if ruta:
                img = self._miniatura(ruta)
                if img is not None:
                    lbl = tk.Label(marco_img, image=img, bg="#243447")
                    lbl.image = img
                    lbl.pack()
                    lbl.bind("<Double-Button-1>",
                             lambda e, r=ruta, t=etiqueta: self._abrir(r, t))
                    lbl.config(cursor="hand2")
                else:
                    tk.Label(marco_img, text="(no disponible)",
                             bg="#243447", fg="#ff6b6b").pack()
        else:
            marco_img.configure(bg="#3b2a2a", width=150, height=130)
            marco_img.pack_propagate(False)
            tk.Label(marco_img, text="FALTA", bg="#3b2a2a", fg="#ff6b6b",
                     font=("Segoe UI", 13, "bold")).pack(expand=True)

        der = tk.Frame(caja, bg="#243447")
        der.pack(side="left", fill="both", expand=True, padx=(0, 8), pady=8)
        tk.Label(der, text=etiqueta, bg="#243447", fg="#ffffff",
                 wraplength=270, anchor="w",
                 font=("Segoe UI", 10, "bold")).pack(anchor="w", fill="x")

        color_estado = {"aprobado": "#2ecc71", "rechazado": "#ff6b6b"}.get(
            estado, "#ffc107" if archivo else "#ff6b6b")
        tk.Label(der, text=estado.capitalize()
                 if archivo else "No subida",
                 bg="#243447", fg=color_estado,
                 font=("Segoe UI", 9, "bold")).pack(anchor="w", pady=(6, 0))
        if info.get("motivo"):
            tk.Label(der, text="Motivo: %s" % info["motivo"], bg="#243447",
                     fg="#ff6b6b", wraplength=250, anchor="w",
                     font=("Segoe UI", 8), justify="left").pack(
                         anchor="w", fill="x")

        if archivo:
            fila_btn = tk.Frame(der, bg="#243447")
            fila_btn.pack(anchor="w", pady=(6, 0))
            tk.Button(fila_btn, text="Aprobar", bg="#2ecc71", fg="#1b2a3a",
                      bd=0, padx=8,
                      command=lambda: self._revisar(campo, "aprobado", "")).\
                pack(side="left", padx=(0, 4))
            tk.Button(fila_btn, text="Rechazar", bg="#e74c3c", fg="#ffffff",
                      bd=0, padx=8,
                      command=lambda: self._rechazar(campo, etiqueta)).\
                pack(side="left")

    def _rechazar(self, campo, etiqueta):
        from tkinter import simpledialog
        motivo = simpledialog.askstring(
            "Rechazar foto", "Motivo del rechazo de %s (lo vera el chofer):"
            % etiqueta, parent=self, show="error")
        self._revisar(campo, "rechazado", motivo or "")

    def _revisar(self, campo, decision, motivo):
        vid = self.vehiculo.get("id")
        try:
            r = self.api.revisar_foto_vehiculo(vid, campo, decision, motivo)
        except ApiError as e:
            messagebox.showerror("Revision de foto", str(e.mensaje))
            return
        mensaje = r.get("message") if isinstance(r, dict) else None
        self.lbl_resumen.config(text="  " + (mensaje or "Listo"), fg="#2ecc71")
        # El backend devuelve el vehiculo actualizado: se refresca el visor.
        if isinstance(r, dict) and r.get("fotos") is not None:
            self.vehiculo = r
        self.cargar()

    def _descargar(self, archivo):
        try:
            data = self.api.descargar_foto_vehiculo(archivo)
        except ApiError as e:
            self.mensaje_error = str(e.mensaje)
            return None
        d = os.path.join(tempfile.gettempdir(), "taxirapid_garaje")
        os.makedirs(d, exist_ok=True)
        ext = os.path.splitext(archivo)[1] or ".jpg"
        ruta = os.path.join(d, archivo)
        with open(ruta, "wb") as f:
            f.write(data)
        return ruta

    def _miniatura(self, ruta):
        if HAY_PILLOW:
            try:
                with Image.open(ruta) as original:
                    img = ImageOps.exif_transpose(original)
                    if img.mode not in ("RGB", "RGBA"):
                        img = img.convert("RGB")
                    img.thumbnail((ANCHO_MINI, ALTO_MINI), Image.LANCZOS)
                    return ImageTk.PhotoImage(img)
            except Exception:
                pass
        return None

    def _abrir(self, ruta, etiqueta):
        try:
            if os.name == "nt":
                os.startfile(ruta)  # noqa
            else:
                subprocess.Popen(["xdg-open", ruta])
        except Exception:
            messagebox.showinfo("Imagen", etiqueta)
