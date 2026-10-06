"""Panel de administracion TaxiRapid (escritorio).

Uso:  python main.py
"""
import os
import sys
import tkinter as tk
from datetime import datetime
from tkinter import ttk, messagebox

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from api_client import ApiClient, ApiError, API_URL   # noqa: E402
from login_window import LoginWindow                  # noqa: E402
from tab_viajes import TabViajes                      # noqa: E402
from tab_choferes import TabChoferes                  # noqa: E402
from tab_billetera import TabBilletera                # noqa: E402


class AppAdmin(tk.Tk):
    def __init__(self, api):
        super().__init__()
        self.api = api

        self.title("TaxiRapid - Panel de Administracion")
        self.geometry("1360x820")
        self.minsize(1150, 680)

        self._estilo()
        self._construir()

        self.protocol("WM_DELETE_WINDOW", self._salir)
        self.after(60000, self._tick_token)   # el token dura 30 min
        self.status("Sesion iniciada como %s" % api.admin_email)

    # ---------------- estilo ----------------
    def _estilo(self):
        self.configure(bg="#1b2a3a")
        estilo = ttk.Style(self)
        try:
            estilo.theme_use("clam")
        except tk.TclError:
            pass
        estilo.configure("TFrame", background="#1b2a3a")
        estilo.configure("TLabel", background="#1b2a3a", foreground="#cfd8e3")
        estilo.configure("TNotebook", background="#1b2a3a", borderwidth=0)
        estilo.configure("TNotebook.Tab", background="#243447", foreground="#cfd8e3",
                        padding=(22, 9), font=("Segoe UI", 10, "bold"))
        estilo.map("TNotebook.Tab",
                   background=[("selected", "#ffc107")],
                   foreground=[("selected", "#1b2a3a")])
        estilo.configure("Treeview", background="#ffffff", fieldbackground="#ffffff",
                        rowheight=24, font=("Segoe UI", 9),
                        borderwidth=0)
        estilo.configure("Treeview.Heading", background="#2f80ed",
                        foreground="#ffffff", font=("Segoe UI", 9, "bold"),
                        padding=(4, 5), relief="flat")
        estilo.map("Treeview.Heading", background=[("active", "#1f6fd0")])
        estilo.configure("TEntry", fieldbackground="#ffffff")
        estilo.configure("TCombobox", fieldbackground="#ffffff")
        estilo.configure("TCheckbutton", background="#243447", foreground="#cfd8e3")

    def _construir(self):
        # barra superior
        barra = tk.Frame(self, bg="#243447", height=42)
        barra.pack(fill="x")
        tk.Label(barra, text="TAXI RAPID  -  Administracion", bg="#243447",
                 fg="#ffc107", font=("Segoe UI", 13, "bold")).pack(
                     side="left", padx=14, pady=8)
        self.lbl_user = tk.Label(barra, text=self.api.admin_email, bg="#243447",
                                 fg="#9fb3c8", font=("Segoe UI", 9))
        self.lbl_user.pack(side="right", padx=14)

        # pestanas
        self.notebook = ttk.Notebook(self)
        self.notebook.pack(fill="both", expand=True, padx=8, pady=8)

        self.tab_viajes = TabViajes(self.notebook, self)
        self.tab_choferes = TabChoferes(self.notebook, self)
        self.tab_billetera = TabBilletera(self.notebook, self)

        self.notebook.add(self.tab_viajes, text="Viajes")
        self.notebook.add(self.tab_choferes, text="Choferes")
        self.notebook.add(self.tab_billetera, text="Billetera")

        # barra de estado
        self.lbl_status = tk.Label(self, text="Listo", bg="#243447", fg="#9fb3c8",
                                   font=("Segoe UI", 9), anchor="w", padx=12)
        self.lbl_status.pack(fill="x")

    # ---------------- utilidades ----------------
    def status(self, texto, error=False):
        self.lbl_status.config(text=texto, fg="#ff6b6b" if error else "#9fb3c8")

    def recargar_pestana(self):
        idx = self.notebook.index(self.notebook.select())
        self.notebook.select(idx)

    def _tick_token(self):
        """El token expira a los 30 min: se refresca con las credenciales."""
        try:
            self.api.ping()
            self.status("Sesion activa - %s" % datetime.now().strftime("%H:%M:%S"))
        except ApiError as e:
            if e.status in (401, 403):
                messagebox.showwarning("Sesion expirada",
                                       "La sesion expiro. Vuelva a entrar.\n\n%s" % e.mensaje)
                self._salir()
                return
            self.status("Sin conexion con el servidor", error=True)
        self.after(60000, self._tick_token)

    def _salir(self):
        if messagebox.askokcancel("Salir", "Cerrar el panel de administracion?"):
            self.api.logout()
            self.destroy()


def main():
    root = tk.Tk()
    root.withdraw()

    def al_entrar(api):
        root.destroy()
        app = AppAdmin(api)
        app.mainloop()

    ventana = LoginWindow(root, al_entrar)
    ventana.mainloop()


if __name__ == "__main__":
    main()
