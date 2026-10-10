"""Dialogo para dar de alta una cuenta de administrador.

Pide solo lo que hace falta para entrar al panel y saber quien es: nombre,
email, telefono, rol y contrasena. El hash lo pone el backend; aqui la
contrasena viaja en claro por la llamada, que es lo unico que se puede hacer
sin montar TLS, pero nunca se escribe en disco ni se vuelve a mostrar.

Va en su propio archivo y no dentro de `main.py` porque el panel ya tiene
varias ventanas y este dialogo tiene su propio ciclo de vida.
"""
import threading
import tkinter as tk
from tkinter import ttk, messagebox

from api_client import ApiError

# Minima que exige el backend. Se repite aqui para avisar antes de dar al
# Enviar, y no volver al usuario con un error del servidor.
PASSWORD_MINIMA = 8

ROLES = ["admin", "soporte", "lectura"]


class VentanaAltaAdmin(tk.Toplevel):
    def __init__(self, master, api):
        super().__init__(master)
        self.api = api
        self.app = master
        self._hilo = None
        self._error = None
        self._creado = None

        self.title("Nuevo administrador")
        self.configure(bg="#1b2a3a")
        self.resizable(False, False)
        self._build()
        self._centrar(430, 520)
        self.protocol("WM_DELETE_WINDOW", self.destroy)
        self.after(120, lambda: self.ent_nombre.focus_set())

    # ---------------- interfaz ----------------

    def _build(self):
        marco = tk.Frame(self, bg="#1b2a3a", padx=26, pady=20)
        marco.pack(fill="both", expand=True)

        tk.Label(marco, text="NUEVO ADMINISTRADOR", bg="#1b2a3a", fg="#ffc107",
                 font=("Segoe UI", 14, "bold")).pack(pady=(0, 2))
        tk.Label(marco, text="La cuenta podra entrar al panel con estos datos",
                 bg="#1b2a3a", fg="#9fb3c8",
                 font=("Segoe UI", 9)).pack(pady=(0, 16))

        self.var_nombre = tk.StringVar()
        self.var_email = tk.StringVar()
        self.var_telefono = tk.StringVar()
        self.var_password = tk.StringVar()
        self.var_password2 = tk.StringVar()
        self.var_rol = tk.StringVar(value=ROLES[0])

        # Aviso de espera del servidor. Se vacia al terminar.
        self.var_estado = tk.StringVar(value="")

        f_nombre = tk.Frame(marco, bg="#1b2a3a")
        f_nombre.pack(fill="x", pady=5)
        tk.Label(f_nombre, text="Nombre", bg="#1b2a3a", fg="#cfd8e3", width=10,
                 anchor="w", font=("Segoe UI", 10)).pack(side="left")
        self.ent_nombre = tk.Entry(
            f_nombre, textvariable=self.var_nombre, width=28,
            font=("Segoe UI", 10), bg="#ffffff", fg="#1b2a3a",
            relief="flat", highlightthickness=1, highlightbackground="#3d5a73")
        self.ent_nombre.pack(side="left", ipady=3, ipadx=4)

        f_email = tk.Frame(marco, bg="#1b2a3a")
        f_email.pack(fill="x", pady=5)
        tk.Label(f_email, text="Email", bg="#1b2a3a", fg="#cfd8e3", width=10,
                 anchor="w", font=("Segoe UI", 10)).pack(side="left")
        self.ent_email = tk.Entry(
            f_email, textvariable=self.var_email, width=28,
            font=("Segoe UI", 10), bg="#ffffff", fg="#1b2a3a",
            relief="flat", highlightthickness=1, highlightbackground="#3d5a73")
        self.ent_email.pack(side="left", ipady=3, ipadx=4)

        f_tel = tk.Frame(marco, bg="#1b2a3a")
        f_tel.pack(fill="x", pady=5)
        tk.Label(f_tel, text="Telefono", bg="#1b2a3a", fg="#cfd8e3", width=10,
                 anchor="w", font=("Segoe UI", 10)).pack(side="left")
        self.ent_tel = tk.Entry(
            f_tel, textvariable=self.var_telefono, width=28,
            font=("Segoe UI", 10), bg="#ffffff", fg="#1b2a3a",
            relief="flat", highlightthickness=1, highlightbackground="#3d5a73")
        self.ent_tel.pack(side="left", ipady=3, ipadx=4)

        f_rol = tk.Frame(marco, bg="#1b2a3a")
        f_rol.pack(fill="x", pady=5)
        tk.Label(f_rol, text="Rol", bg="#1b2a3a", fg="#cfd8e3", width=10,
                 anchor="w", font=("Segoe UI", 10)).pack(side="left")
        self.cbo_rol = ttk.Combobox(f_rol, textvariable=self.var_rol,
                                    values=ROLES, state="readonly", width=25)
        self.cbo_rol.pack(side="left", padx=(2, 0))

        f_pass = tk.Frame(marco, bg="#1b2a3a")
        f_pass.pack(fill="x", pady=5)
        tk.Label(f_pass, text="Contrasena", bg="#1b2a3a", fg="#cfd8e3", width=10,
                 anchor="w", font=("Segoe UI", 10)).pack(side="left")
        self.ent_pass = tk.Entry(
            f_pass, textvariable=self.var_password, width=28, show="*",
            font=("Segoe UI", 10), bg="#ffffff", fg="#1b2a3a",
            relief="flat", highlightthickness=1, highlightbackground="#3d5a73")
        self.ent_pass.pack(side="left", ipady=3, ipadx=4)

        f_pass2 = tk.Frame(marco, bg="#1b2a3a")
        f_pass2.pack(fill="x", pady=5)
        tk.Label(f_pass2, text="Repetir", bg="#1b2a3a", fg="#cfd8e3", width=10,
                 anchor="w", font=("Segoe UI", 10)).pack(side="left")
        self.ent_pass2 = tk.Entry(
            f_pass2, textvariable=self.var_password2, width=28, show="*",
            font=("Segoe UI", 10), bg="#ffffff", fg="#1b2a3a",
            relief="flat", highlightthickness=1, highlightbackground="#3d5a73")
        self.ent_pass2.pack(side="left", ipady=3, ipadx=4)
        self.ent_pass2.bind("<Return>", lambda e: self._crear())

        self.lbl_error = tk.Label(marco, text="", bg="#1b2a3a", fg="#ff6b6b",
                                  font=("Segoe UI", 9), wraplength=370,
                                  justify="left")

        self.btn_crear = tk.Button(
            marco, text="Crear administrador", command=self._crear,
            bg="#2f80ed", fg="#ffffff", activebackground="#1f6fd0",
            activeforeground="#ffffff", font=("Segoe UI", 10, "bold"),
            relief="flat", cursor="hand2", pady=6)
        self.btn_crear.pack(fill="x", pady=(18, 6), ipady=2)

        tk.Button(
            marco, text="Cancelar", command=self.destroy, bg="#3d5a73",
            fg="#ffffff", activebackground="#2f4560", activeforeground="#ffffff",
            font=("Segoe UI", 9), relief="flat", cursor="hand2", pady=4
        ).pack(fill="x", ipady=1)

        self.lbl_estado = tk.Label(marco, text="", bg="#1b2a3a", fg="#ffc107",
                                   font=("Segoe UI", 8), wraplength=370,
                                   justify="left")
        self.lbl_estado.pack(pady=(10, 0))

    def _centrar(self, w, h):
        self.update_idletasks()
        x = (self.winfo_screenwidth() - w) // 2
        y = (self.winfo_screenheight() - h) // 2
        self.geometry("%dx%d+%d+%d" % (w, h, x, y))

    def _mostrar_error(self, msg):
        self.lbl_error.config(text=msg)

    # ---------------- validacion ----------------

    def _revisar(self):
        """Valida en local. Devuelve el cuerpo o None con el motivo."""
        nombre = self.var_nombre.get().strip()
        email = self.var_email.get().strip().lower()
        telefono = self.var_telefono.get().strip()
        password = self.var_password.get()
        password2 = self.var_password2.get()

        if not nombre:
            return None, "Escriba el nombre."
        if "@" not in email or "." not in email.split("@")[-1]:
            return None, "El email no tiene un formato valido."
        if not password:
            return None, "Escriba la contrasena."
        if len(password) < PASSWORD_MINIMA:
            return None, ("La contrasena debe tener al menos %d caracteres."
                          % PASSWORD_MINIMA)
        if password != password2:
            return None, "Las contrasenas no coinciden."

        return {
            "nombre": nombre,
            "email": email,
            "telefono": telefono,
            "password": password,
            "rol": self.var_rol.get() or "admin",
        }, None

    # ---------------- envio ----------------

    def _crear(self):
        if self._hilo is not None and self._hilo.is_alive():
            return
        self._mostrar_error("")

        cuerpo, problema = self._revisar()
        if cuerpo is None:
            self._mostrar_error(problema)
            return

        self.btn_crear.config(state="disabled", text="Creando...")
        self.var_estado.set("Guardando en el servidor...")
        self.update_idletasks()

        self._error = None
        self._creado = None
        self._hilo = threading.Thread(
            target=self._crear_hilo, args=(cuerpo,), daemon=True)
        self._hilo.start()
        self.after(150, self._vigilar)

    def _crear_hilo(self, cuerpo):
        try:
            self._creado = self.api.crear_administrador(**cuerpo)
        except ApiError as e:
            self._error = e
        except Exception as e:
            self._error = ApiError("Error inesperado: %s" % e)

    def _vigilar(self):
        """Mientras el hilo trabaja, avisa si el servidor esta despertando."""
        if not self._hilo.is_alive():
            self.btn_crear.config(state="normal", text="Crear administrador")
            if self._error is not None:
                self._mostrar_error(str(self._error.mensaje))
                self.var_estado.set("")
                return
            self._exito()
            return
        if self.api.desperando:
            self.var_estado.set(
                "El servidor esta despertando (plan gratuito de Render).\n"
                "Puede tardar 30-60 segundos...")
        self.after(200, self._vigilar)

    def _exito(self):
        creado = self._creado or {}
        nombre = creado.get("nombre", "")
        email = creado.get("email", "")
        # El `parent` es lo que ata el dialogo a esta ventana. Sin el, Windows
        # puede abrirlo detras de la ventana principal y parece que el boton no
        # hace nada: el usuario pulsa "Crear administrador", no ve nada y vuelve
        # a pulsar. Pasa siempre `self`.
        if messagebox.askokcancel(
                "Administrador creado",
                "Se creo la cuenta de %s (%s).\n\n"
                "Quiere cerrar esta ventana?" % (nombre, email),
                parent=self):
            self.destroy()
        else:
            # Dejar la ventana abierta para crear otra cuenta sin reentrar:
            # se limpian los campos y se foco el primero.
            for var in (self.var_nombre, self.var_email, self.var_telefono,
                        self.var_password, self.var_password2):
                var.set("")
            self.var_estado.set("")
            self._mostrar_error("")
            self.btn_crear.config(state="normal", text="Crear administrador")
            self.ent_nombre.focus_set()