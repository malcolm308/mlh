"""Panel de administracion TaxiRapid (escritorio).

Uso:  python main.py
"""
import os
import sys
import threading
import tkinter as tk
from datetime import datetime
from tkinter import ttk, messagebox

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from api_client import ApiClient, ApiError, API_URL   # noqa: E402
from config import PING_CADA_SEGUNDOS                 # noqa: E402
from login_window import LoginWindow                  # noqa: E402
from tab_viajes import TabViajes                      # noqa: E402
from tab_choferes import TabChoferes                  # noqa: E402
from tab_billetera import TabBilletera                # noqa: E402


class AppAdmin(tk.Tk):
    def __init__(self, api):
        super().__init__()
        self.api = api
        # Estado del ping en curso. Vive en la ventana porque es el hilo de
        # Tkinter quien lo lee y quien decide cuando reintentar.
        self._ping_en_curso = False
        self._ping_error = None

        self.title("TaxiRapid - Panel de Administracion")
        self.geometry("1360x820")
        self.minsize(1150, 680)

        self._estilo()
        self._construir()

        self.protocol("WM_DELETE_WINDOW", self._salir)
        self.after(1000, self._tick_token)   # el token dura 30 min
        self.after(100, self._revisar_ping)
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
        """Comprueba en segundo plano que el token siga vivo.

        Va en un hilo aparte a proposito: el backend duerme tras 15 min sin
        trafico y la peticion que lo despierta tarda 30-60 s. Si esto corriera
        en el hilo de Tkinter, la ventana entera quedaria congelada ese rato
        cada vez que el servidor estuviera dormido. El hilo solo deja el
        resultado en atributos y el hilo de Tkinter lo lee.
        """
        self._ping_en_curso = True
        self._ping_error = None
        threading.Thread(target=self._ping_hilo, daemon=True).start()

    def _ping_hilo(self):
        try:
            self.api.ping()
        except ApiError as e:
            self._ping_error = e
        except Exception as e:
            self._ping_error = ApiError("Error inesperado: %s" % e)
        finally:
            self._ping_en_curso = False

    def _revisar_ping(self):
        """Recoge el resultado del ping y programa el siguiente.

        Mientras el hilo sigue trabajando se vuelve a mirar cada medio segundo
        para poder actualizar el estado. Cuando termina, se programala proxima
        comprobacion y deja de mirarlo: sin ese `return` el bucle se
        reprogramaria a si mismo sin descanso.
        """
        if self._ping_en_curso:
            if self.api.desperando:
                self.status("El servidor esta despertando, espere...")
            self.after(500, self._revisar_ping)
            return

        err = self._ping_error
        if err is None:
            self.status("Sesion activa - %s" % datetime.now().strftime("%H:%M:%S"))
        elif err.status in (401, 403):
            messagebox.showwarning(
                "Sesion expirada",
                "La sesion expiro. Vuelva a entrar.\n\n%s" % err.mensaje)
            self.destroy()
            return
        else:
            self.status("Sin conexion con el servidor", error=True)

        self.after(PING_CADA_SEGUNDOS * 1000, self._tick_token)

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
