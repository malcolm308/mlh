"""Ventana de inicio de sesion del administrador."""
import tkinter as tk
from tkinter import ttk, messagebox

from api_client import ApiClient, ApiError

API_URL = "http://127.0.0.1:18000"


class LoginWindow(tk.Toplevel):
    def __init__(self, master, on_ok):
        super().__init__(master)
        self.on_ok = on_ok
        self.api = ApiClient(API_URL)
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
        self.lbl_error.config(text=msg)
        self.lbl_error.pack(pady=(10, 0), before=self.ent_email.master.master)

    def _entrar(self):
        email = self.var_email.get().strip()
        password = self.var_pass.get()
        if not email or not password:
            self._error("Escriba el email y la contrasena.")
            return
        self.btn_entrar.config(state="disabled", text="Entrando...")
        self.update()
        try:
            self.api.login(email, password)
        except ApiError as e:
            self.btn_entrar.config(state="normal", text="Entrar")
            self._error(str(e.mensaje))
            return
        self.on_ok(self.api)

    def _cancelar(self):
        self.master.destroy()
