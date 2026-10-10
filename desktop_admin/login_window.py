"""Ventana de inicio de sesion del administrador."""
import threading
import tkinter as tk
from tkinter import ttk, messagebox

from api_client import ApiClient, ApiError, API_URL


class LoginWindow(tk.Toplevel):
    def __init__(self, master, on_ok):
        super().__init__(master)
        self.on_ok = on_ok
        self.api = ApiClient(API_URL)
        self._hilo = None
        self._error_entrando = None
        self.var_estado = tk.StringVar(value="")
        self._build()
        self._centrar(400, 300)
        self.protocol("WM_DELETE_WINDOW", self._cancelar)

    def _build(self):
        self.title("TaxiRapid - Administracion")
        self.resizable(False, False)
        self.configure(bg="#1b2a3a")

        marco = tk.Frame(self, bg="#1b2a3a", padx=30, pady=24)
        marco.pack(fill="both", expand=True)

        tk.Label(marco, text="TAXI RAPID", bg="#1b2a3a", fg="#ffc107",
                 font=("Segoe UI", 20, "bold")).pack(pady=(0, 2))
        tk.Label(marco, text="Panel de administracion", bg="#1b2a3a", fg="#9fb3c8",
                 font=("Segoe UI", 10)).pack(pady=(0, 20))

        self.lbl_error = tk.Label(marco, text="", bg="#1b2a3a", fg="#ff6b6b",
                                  font=("Segoe UI", 9), wraplength=330, justify="left")

        f_email = tk.Frame(marco, bg="#1b2a3a")
        f_email.pack(fill="x", pady=6)
        tk.Label(f_email, text="Email", bg="#1b2a3a", fg="#cfd8e3", width=9,
                 anchor="w", font=("Segoe UI", 10)).pack(side="left")
        self.var_email = tk.StringVar(value="admin@taxirapid.cu")
        self.ent_email = tk.Entry(f_email, textvariable=self.var_email, width=28,
                                  font=("Segoe UI", 10))

        f_pass = tk.Frame(marco, bg="#1b2a3a")
        f_pass.pack(fill="x", pady=6)
        tk.Label(f_pass, text="Contrasena", bg="#1b2a3a", fg="#cfd8e3", width=9,
                 anchor="w", font=("Segoe UI", 10)).pack(side="left")
        self.var_pass = tk.StringVar()
        self.ent_pass = tk.Entry(f_pass, textvariable=self.var_pass, show="*", width=28,
                                 font=("Segoe UI", 10))

        self.btn_entrar = tk.Button(marco, text="Entrar", command=self._entrar,
                                    bg="#ffc107", fg="#1b2a3a", activebackground="#e0a800",
                                    font=("Segoe UI", 11, "bold"), cursor="hand2",
                                    relief="flat", pady=6)
        self.btn_entrar.pack(fill="x", pady=(14, 6), ipady=2)

        self.lbl_estado = tk.Label(marco, textvariable=self.var_estado, bg="#1b2a3a",
                                fg="#ffc107", font=("Segoe UI", 8),
                                wraplength=330, justify="left")
        self.lbl_estado.pack(pady=(12, 0))

        tk.Label(marco, text="Servidor: %s" % API_URL, bg="#1b2a3a", fg="#6b7d8f",
                 font=("Segoe UI", 8)).pack(pady=(10, 0))

        self.lbl_error.pack_forget()
        self.ent_email.pack(side="left", ipady=3)
        self.ent_pass.pack(side="left", ipady=3)
        self.ent_pass.bind("<Return>", lambda e: self._entrar())
        self.after(100, lambda: self.ent_pass.focus_set())

    def _centrar(self, w, h):
        self.update_idletasks()
        x = (self.winfo_screenwidth() - w) // 2
        y = (self.winfo_screenheight() - h) // 2
        self.geometry("%dx%d+%d+%d" % (w, h, x, y))

    def _error(self, msg):
        """Muestra el error debajo del boton.

        Se empaqueta de nuevo antes de cada llamada: al inicio se ocultaba con
        `pack_forget`, y si solo se actualizara el texto sin volver a
        empaquetar, el mensaje apareceria en un sitio u otro segun cuantas
        veces se hubiera escrito. `before` apunta al marco de los campos, que
        es el mismo padre de esta etiqueta, asi que la coloca encima.
        """
        self.lbl_error.config(text=msg)
        self.lbl_error.pack(pady=(10, 0), before=self.lbl_estado)

    def _entrar(self):
        email = self.var_email.get().strip()
        password = self.var_pass.get()
        if not email or not password:
            self._error("Escriba el email y la contrasena.")
            return

        # La llamada va en un hilo aparte. Tkinter solo admite toques de su
        # hilo principal, asi que este hilo no toca la ventana: solo avisa
        # cuando `despertando` se activa y el resultado se recoge despues.
        self.btn_entrar.config(state="disabled", text="Entrando...")
        self.var_estado.set("Conectando con el servidor...")
        self._hilo = threading.Thread(target=self._entrar_hilo,
                                      args=(email, password), daemon=True)
        self._hilo.start()
        self._vigilar_entrada()

    def _vigilar_entrada(self):
        """Mientras el hilo trabaja, avisa si la instancia esta despertando.

        Se llama cada 200 ms desde el hilo de Tkinter. Cuando la peticion lleva
        mas del tiempo de aviso sin responder, el texto cambia para que el
        administrador sepa que hay que esperar y no que el panel se cuelgo.
        """
        if not self._hilo.is_alive():
            self.btn_entrar.config(state="normal", text="Entrar")
            if self._error_entrando is not None:
                self._error(str(self._error_entrando))
                self._error_entrando = None
            return
        if self.api.desperando:
            self.var_estado.set(
                "El servidor esta despertando (plan gratuito de Render).\n"
                "Puede tardar 30-60 segundos...")
        self.after(200, self._vigilar_entrada)

    def _entrar_hilo(self, email, password):
        try:
            self.api.login(email, password)
            self._error_entrando = None
        except ApiError as e:
            self._error_entrando = e
        except Exception as e:
            self._error_entrando = ApiError("Error inesperado: %s" % e)

    def _cancelar(self):
        self.master.destroy()
