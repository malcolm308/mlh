"""Visor de los 10 documentos de un chofer para el panel de administracion."""
import os
import subprocess
import tkinter as tk
from tkinter import messagebox

from api_client import ApiClient, ApiError
from ui_common import boton

try:
    # Pillow decodifica JPEG/WebP/HEIC y aplica la rotacion EXIF de las fotos
    # del telefono. tk.PhotoImage solo entiende PNG/GIF.
    from PIL import Image, ImageOps, ImageTk
    HAY_PILLOW = True
except ImportError:  # pragma: no cover - el panel sigue funcionando con PNG
    HAY_PILLOW = False

try:
    # Las fotos de iPhone vienen en HEIC y Pillow no las abre solo.
    import pillow_heif
    pillow_heif.register_heif_opener()
    HAY_HEIC = True
except Exception:  # pragma: no cover - opcional
    HAY_HEIC = False

# Tamano de la miniatura dentro de cada tarjeta
ANCHO_MINI, ALTO_MINI = 150, 130

# (clave, etiqueta) en el mismo orden que exige el backend
DOCUMENTOS = [
    ("rostro", "Foto frontal de la cara"),
    ("carnet_frente", "Carnet de identidad (delante)"),
    ("carnet_atras", "Carnet de identidad (atras)"),
    ("licencia_frente", "Licencia de conducir (delante)"),
    ("licencia_atras", "Licencia de conducir (atras)"),
    ("circulacion", "Circulacion del vehiculo"),
    ("vehiculo_interior_frente", "Vehiculo por dentro (alante)"),
    ("vehiculo_interior_atras", "Vehiculo por dentro (atras)"),
    ("vehiculo_exterior_frente", "Vehiculo por fuera (delante)"),
    ("vehiculo_exterior_atras", "Vehiculo por fuera (atras)"),
]

TMP_DIR = None


class VentanaDocumentos(tk.Toplevel):
    """Muestra en grilla las 10 fotos con su estado (subida / falta)."""

    def __init__(self, master, api: ApiClient, chofer):
        super().__init__(master)
        self.api = api
        self.chofer = chofer
        self.error_descarga = None
        self.title("Documentos - %s" % chofer.get("nombre", ""))
        self.configure(bg="#1b2a3a")
        self.geometry("1060x720")

        self._construir()
        self._centrar()
        self.after(100, self.cargar)
        self.bind("<Escape>", lambda e: self.destroy())

    def _centrar(self):
        self.update_idletasks()
        w, h = 1060, 720
        x = (self.winfo_screenwidth() - w) // 2
        y = (self.winfo_screenheight() - h) // 2
        self.geometry("%dx%d+%d+%d" % (w, h, max(x, 0), max(y, 0)))

    def _construir(self):
        cabecera = tk.Frame(self, bg="#243447", height=54)
        cabecera.pack(fill="x")
        self.lbl_titulo = tk.Label(
            cabecera,
            text="%s  -  %s" % (self.chofer.get("nombre") or "-",
                                self.chofer.get("email") or "-"),
            bg="#243447", fg="#ffffff", font=("Segoe UI", 12, "bold"))
        self.lbl_titulo.pack(side="left", padx=14)

        veh = self.chofer.get("vehiculo") or "?"
        chapa = self.chofer.get("matricula") or "?"
        tk.Label(cabecera,
                 text="Vehiculo: %s   Chapa: %s   Licencia: %s"
                      % (veh, chapa, self.chofer.get("licencia") or "-"),
                 bg="#243447", fg="#9fb3c8", font=("Segoe UI", 9)).pack(
                     side="left", padx=10)

        self.lbl_resumen = tk.Label(self, text="Cargando documentos...", bg="#1b2a3a",
                                    fg="#ffc107", font=("Segoe UI", 10, "bold"),
                                    anchor="w", padx=14, pady=8)
        self.lbl_resumen.pack(fill="x")

        # Lienzo desplazable con la grilla de 10 fotos
        self.canvas = tk.Canvas(self, bg="#1b2a3a", highlightthickness=0)
        vs = tk.Scrollbar(self, orient="vertical", command=self.canvas.yview)
        self.canvas.configure(yscrollcommand=vs.set)
        self.canvas.pack(side="left", fill="both", expand=True, padx=(10, 0), pady=(0, 10))
        vs.pack(side="right", fill="y", padx=(0, 10), pady=(0, 10))

        self.marco = tk.Frame(self.canvas, bg="#1b2a3a")
        self._ventana = self.canvas.create_window((0, 0), window=self.marco, anchor="nw")
        self.marco.bind("<Configure>",
                        lambda e: self.canvas.configure(scrollregion=self.canvas.bbox("all")))
        self.canvas.bind("<Configure>",
                         lambda e: self.canvas.itemconfigure(self._ventana, width=e.width))
        self.canvas.bind("<MouseWheel>",
                         lambda e: self.canvas.yview_scroll(int(-1 * (e.delta / 120)), "units"))

    # ---------------- carga ----------------
    def cargar(self):
        self.api.ping()
        try:
            datos = self.api.documentos(self.chofer["driver_id"])
        except ApiError as e:
            messagebox.showerror("Documentos", str(e.mensaje))
            self.destroy()
            return

        self.datos = datos
        detalle = datos.get("documentos", {})
        subidos = datos.get("subidos", 0)
        total = datos.get("total", len(DOCUMENTOS))
        faltan = datos.get("faltantes", [])

        color = "#2ecc71" if not faltan else "#e74c3c"
        self.lbl_resumen.config(
            text="  Documentos: %d de %d subidos   |   %s" % (
                subidos, total,
                "Todo completo, listo para aprobar" if not faltan
                else "Faltan: " + ", ".join(faltan)),
            fg=color)

        for w in self.marco.winfo_children():
            w.destroy()

        # 2 columnas x 5 filas
        for i, (clave, etiqueta) in enumerate(DOCUMENTOS):
            info = detalle.get(clave, {})
            fila, col = divmod(i, 2)
            self._tarjeta(fila, col, etiqueta, info)

    def _tarjeta(self, fila, col, etiqueta, info):
        tiene = bool(info.get("subido"))
        borde = "#2ecc71" if tiene else "#e74c3c"

        caja = tk.Frame(self.marco, bg="#243447", highlightbackground=borde,
                        highlightthickness=2, width=480, height=180)
        caja.grid(row=fila, column=col, padx=8, pady=8, sticky="nsew")
        caja.grid_propagate(False)

        # imagen o placeholder
        marco_img = tk.Frame(caja, bg="#243447")
        marco_img.pack(side="left", padx=8, pady=8)
        ruta = None
        if tiene:
            ruta = self._descargar(info.get("archivo"))
            if ruta:
                img = self._miniatura(ruta)
                if img is not None:
                    lbl = tk.Label(marco_img, image=img, bg="#243447")
                    lbl.image = img          # evita que el GC la destruya
                    lbl.pack()
                    lbl.bind("<Double-Button-1>", lambda e, r=ruta, t=etiqueta: self._abrir(r, t))
                    lbl.bind("<Button-3>", lambda e, r=ruta: self._abrir_carpeta(r))
                    lbl.config(cursor="hand2")
                else:
                    self._no_visible(marco_img, ruta)
            else:
                motivo = self.error_descarga or "no se pudo descargar"
                self.error_descarga = None
                tk.Label(marco_img, text="(imagen no\ndisponible)\n%s" % motivo,
                         bg="#243447", fg="#ff6b6b",
                         font=("Segoe UI", 7), justify="center").pack()
        else:
            marco_img.configure(bg="#3b2a2a", width=150, height=130)
            marco_img.pack_propagate(False)
            tk.Label(marco_img, text="FALTA", bg="#3b2a2a", fg="#ff6b6b",
                     font=("Segoe UI", 13, "bold")).pack(expand=True)

        # texto
        der = tk.Frame(caja, bg="#243447")
        der.pack(side="left", fill="both", expand=True, padx=(0, 8), pady=8)
        tk.Label(der, text=etiqueta, bg="#243447", fg="#ffffff", wraplength=270,
                 justify="left", anchor="w", font=("Segoe UI", 10, "bold")
                 ).pack(anchor="w", fill="x")
        estado_txt = "Subida" if tiene else "No subida"
        tk.Label(der, text=estado_txt, bg="#243447",
                 fg="#2ecc71" if tiene else "#ff6b6b",
                 font=("Segoe UI", 9, "bold")).pack(anchor="w", pady=(6, 0))
        if tiene and info.get("subido_at"):
            tk.Label(der, text=str(info["subido_at"])[:16].replace("T", " "),
                     bg="#243447", fg="#6b7d8f", font=("Segoe UI", 8)
                     ).pack(anchor="w", pady=(4, 0))
        if tiene:
            boton(der, "Ver a pantalla completa", lambda: self._abrir(ruta, etiqueta),
                  color="#4a5b6c", fg="#ffffff").pack(anchor="w", pady=(8, 0))

    def _miniatura(self, ruta):
        """Carga cualquier formato de imagen como miniatura de 150x130 aprox."""
        if HAY_PILLOW:
            try:
                with Image.open(ruta) as original:
                    # Las fotos del telefono vienen rotadas solo en el EXIF
                    img = ImageOps.exif_transpose(original)
                    if img.mode not in ("RGB", "RGBA"):
                        img = img.convert("RGB")
                    img.thumbnail((ANCHO_MINI, ALTO_MINI), Image.LANCZOS)
                    return ImageTk.PhotoImage(img)
            except Exception:
                return None
        # Sin Pillow solo se pueden mostrar PNG y GIF
        try:
            img = tk.PhotoImage(file=ruta)
            w, h = img.width(), img.height()
            if w > ANCHO_MINI or h > ALTO_MINI:
                f = min(ANCHO_MINI / w, ALTO_MINI / h)
                img = img.subsample(max(1, round(1 / f)))
            return img
        except Exception:
            return None

    def _no_visible(self, marco_img, ruta):
        """La imagen existe pero este PC no sabe decodificarla (HEIC sin
        soporte, por ejemplo). Se explica y se ofrece el visor del sistema."""
        ext = (os.path.splitext(ruta)[1].lstrip(".") or "?").upper()
        marco_img.configure(bg="#3b2a2a", width=ANCHO_MINI, height=ALTO_MINI)
        marco_img.pack_propagate(False)
        tk.Label(marco_img, text="Formato %s\nno visible aqui" % ext, bg="#3b2a2a",
                 fg="#ffc107", font=("Segoe UI", 9, "bold")).pack(expand=True)
        boton(marco_img, "Abrir igual", lambda: self._abrir_sistema(ruta),
              color="#4a5b6c", fg="#ffffff").pack(pady=4)
        if not HAY_PILLOW:
            tk.Label(marco_img, text="falta Pillow", bg="#3b2a2a", fg="#6b7d8f",
                     font=("Segoe UI", 7)).pack()
        elif ext == "HEIC" and not HAY_HEIC:
            tk.Label(marco_img, text="pip install pillow-heif", bg="#3b2a2a",
                     fg="#6b7d8f", font=("Segoe UI", 7)).pack()

    def _descargar(self, archivo):
        """Descarga la foto y la deja en la carpeta temporal. Cache por nombre."""
        if not archivo:
            return None
        import tempfile
        destino = os.path.join(tempfile.gettempdir(), archivo)
        if os.path.isfile(destino) and os.path.getsize(destino) > 0:
            return destino
        try:
            datos = self.api.descargar_documento(archivo)
        except ApiError as e:
            self.error_descarga = e.mensaje
            return None
        except Exception as e:
            self.error_descarga = str(e)
            return None
        try:
            with open(destino, "wb") as f:
                f.write(datos)
        except OSError as e:
            self.error_descarga = str(e)
            return None
        return destino

    def _abrir(self, ruta, etiqueta):
        if not ruta:
            messagebox.showerror("Imagen", "No se pudo cargar la imagen.")
            return
        if not os.path.isfile(ruta):
            messagebox.showerror("Imagen", "El archivo ya no esta en disco:\n%s" % ruta)
            return
        VentanaImagen(self, ruta, etiqueta)

    def _abrir_sistema(self, ruta):
        if not ruta or not os.path.isfile(ruta):
            messagebox.showerror("Imagen", "El archivo no esta disponible.")
            return
        try:
            if os.name == "nt":
                os.startfile(ruta)          # noqa: S606 - abre el visor del sistema
            else:
                subprocess.Popen(["xdg-open", ruta])
        except Exception as e:
            messagebox.showerror("Imagen", str(e))

    def _abrir_carpeta(self, ruta):
        carpeta = os.path.dirname(ruta) if ruta else ""
        if carpeta and os.path.isdir(carpeta):
            try:
                if os.name == "nt":
                    os.startfile(carpeta)   # noqa: S606
                else:
                    subprocess.Popen(["xdg-open", carpeta])
            except Exception:
                pass


class VentanaImagen(tk.Toplevel):
    """Vista ampliada de un documento, con zoom y salida al visor del sistema."""

    def __init__(self, master, ruta, etiqueta=""):
        super().__init__(master)
        self.ruta = ruta
        self.title("%s  -  %s" % (etiqueta or "Documento",
                                  os.path.basename(ruta)))
        self.configure(bg="#1b2a3a")
        self.geometry("900x700")
        self.img = None
        self.original = None

        tk.Label(self, text=etiqueta or "", bg="#243447", fg="#ffffff",
                 font=("Segoe UI", 11, "bold"), anchor="w",
                 padx=12, pady=8).pack(fill="x")

        self.lbl = tk.Label(self, bg="#1b2a3a", text="Cargando...")
        self.lbl.pack(fill="both", expand=True)

        self.info = tk.Label(self, bg="#1b2a3a", fg="#6b7d8f",
                             font=("Segoe UI", 8), anchor="w", padx=12, pady=6)
        self.info.pack(fill="x")

        barra = tk.Frame(self, bg="#243447")
        barra.pack(fill="x", side="bottom", pady=(0, 10))
        for txt, cmd, col in (("Abrir con el visor del sistema",
                               lambda: master._abrir_sistema(ruta), "#4a5b6c"),
                              ("Mostrar carpeta", lambda: master._abrir_carpeta(ruta),
                               "#4a5b6c"),
                              ("Cerrar", self.destroy, "#c0392b")):
            boton(barra, txt, cmd, color=col, fg="#ffffff").pack(side="left", padx=8)

        self.bind("<Escape>", lambda e: self.destroy())
        self.bind("<Configure>", self._al_redimensionar)
        self.after(50, self._cargar)

    def _cargar(self):
        if HAY_PILLOW:
            try:
                with Image.open(self.ruta) as f:
                    self.original = ImageOps.exif_transpose(f)
                    if self.original.mode not in ("RGB", "RGBA"):
                        self.original = self.original.convert("RGB")
            except Exception as e:
                self.lbl.config(text="No se pudo abrir:\n%s" % e, fg="#ff6b6b")
                return
            self._pintar(self.original.width, self.original.height)
        else:
            self.lbl.config(text="Instala Pillow para ver JPEG/WebP/HEIC:\n"
                                 "pip install Pillow", fg="#ffc107")

    def _pintar(self, w, h):
        ancho = max(self.winfo_width(), 400) - 30
        alto = max(self.winfo_height(), 300) - 140
        f = min(ancho / w, alto / h, 1.0)
        if f < 1.0:
            w, h = max(1, int(w * f)), max(1, int(h * f))
        if HAY_PILLOW:
            copia = self.original.copy()
            if (copia.width, copia.height) != (w, h):
                copia = copia.resize((w, h), Image.LANCZOS)
            self.img = ImageTk.PhotoImage(copia)
        else:
            self.img = tk.PhotoImage(file=self.ruta)
        self.lbl.config(image=self.img, text="")
        kb = os.path.getsize(self.ruta) / 1024.0
        self.info.config(text="%dx%d px   |   %.0f KB   |   %s"
                         % (self.original.width, self.original.height, kb,
                            os.path.basename(self.ruta)))

    def _al_redimensionar(self, e):
        if self.original is not None:
            self._pintar(self.original.width, self.original.height)
