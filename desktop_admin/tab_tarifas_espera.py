"""Pestana Tarifas y Espera: coeficientes por distancia y cortesia de espera.

Dos cosas se ajustan aqui, y viven juntas porque las dos tocan el precio que ve
el pasajero antes de pedir el viaje:

  1. Un coeficiente por tramo de distancia que multiplica SOLO al kilometraje.
     La tarifa base y el tiempo no se tocan, asi que un viaje corto sale mas
     barato por el kilometraje pero la base sigue siendo la misma.
  2. Los minutos de espera que se regalan. El chofere marca "He llegado" y
     cuando el pasajero se sube marca "Iniciar viaje". Lo que pasa entre medias
     es espera; de los primeros N minutos no se cobra nada y el resto se le paga
     al chofer como si fuera tiempo de trayecto.

El formulario NO reenvia la comision, el bono ni el descuento al cliente. Eso no
es descuido: son cosas de otra pantalla y esta tiene su propio endpoint. Si
compartieran guardado, cada vez que un administrador tocara un coeficiente se
mandaria tambien el resto del formulario, y una promocion caducada podria
volver a la vida.
"""
import tkinter as tk
from tkinter import ttk, messagebox

from ui_common import boton, consultar_en_hilo, money, PanelDesplazable


class TabTarifasEspera(ttk.Frame):
    def __init__(self, master, app):
        super().__init__(master)
        self.app = app
        self.api = app.api
        self._build()
        self.after(200, self.cargar)

    # ---------------- construccion ----------------

    def _build(self):
        self.panel = PanelDesplazable(self, ancho=380)
        self.panel.pack(side="left", fill="y", padx=(10, 6), pady=8)
        izq = self.panel.cuerpo

        tk.Label(izq, text="Tarifas y Espera", bg="#243447", fg="#ffffff",
                 font=("Segoe UI", 12, "bold")).pack(anchor="w", pady=(0, 4))
        tk.Label(izq,
                 text="El coeficiente multiplica solo al kilometraje. "
                      "La base y el tiempo se cobran enteros.",
                 bg="#243447", fg="#9fb3c8", justify="left",
                 font=("Segoe UI", 8)).pack(anchor="w", pady=(0, 10))

        # ---- tramos de distancia ----
        self._titulo(izq, "Coeficiente por distancia")

        self.var_corto_km = tk.StringVar(value="3")
        self.ent_corto_km = self._campo(izq, "Hasta (km) - carrera corta",
                                        self.var_corto_km)
        self.var_corto = tk.StringVar(value="0.5")
        self.ent_corto = self._campo(izq, "Coeficiente de las cortas",
                                     self.var_corto)

        self.var_medio_km = tk.StringVar(value="10")
        self.ent_medio_km = self._campo(izq, "Hasta (km) - carrera media",
                                        self.var_medio_km)
        self.var_medio = tk.StringVar(value="0.6")
        self.ent_medio = self._campo(izq, "Coeficiente de las medias",
                                     self.var_medio)

        self.var_largo = tk.StringVar(value="1.0")
        self.ent_largo = self._campo(izq, "Coeficiente de las largas (sin tope)",
                                     self.var_largo)

        tk.Label(izq,
                 text="Los topes van incluidos: con 3 km, una carrera de 3 km "
                      "entra en el tramo corto.",
                 bg="#243447", fg="#6b7d8f", justify="left",
                 font=("Segoe UI", 8)).pack(anchor="w", pady=(2, 0))

        # ---- espera ----
        self._titulo(izq, "Espera de cortesía")
        self.var_cortesia = tk.StringVar(value="4")
        self.ent_cortesia = self._campo(izq, "Minutos gratis de espera",
                                        self.var_cortesia)
        tk.Label(izq,
                 text="El chófer marca 'He llegado' y luego 'Iniciar viaje'. "
                      "Entre medias el pasajero está esperando.",
                 bg="#243447", fg="#6b7d8f", justify="left",
                 font=("Segoe UI", 8)).pack(anchor="w", pady=(2, 0))

        self.lbl_estado = tk.Label(izq, text="", bg="#243447", fg="#9fb3c8",
                                   wraplength=340, justify="left",
                                   font=("Segoe UI", 8))
        self.lbl_estado.pack(anchor="w", pady=(8, 0))

        boton(izq, "Guardar Configuración", self.guardar,
              color="#2ecc71", fg="#ffffff").pack(fill="x", pady=(12, 0))
        boton(izq, "Recargar", self.cargar,
              color="#4a5b6c", fg="#ffffff").pack(fill="x", pady=(6, 0))

        # ---------------- derecha: como queda el precio ----------------

        der = ttk.Frame(self)
        der.pack(side="left", fill="both", expand=True, padx=(6, 10), pady=8)

        tk.Label(der, text="Cómo queda el precio", bg="#1b2a3a",
                 fg="#ffc107", font=("Segoe UI", 12, "bold")).pack(anchor="w")
        tk.Label(der,
                 text="Con estos valores, así se cobra un viaje. La base y el "
                      "tiempo van enteros: el coeficiente solo toca el kilometraje.",
                 bg="#1b2a3a", fg="#9fb3c8", justify="left",
                 font=("Segoe UI", 9)).pack(anchor="w", pady=(4, 10))

        self.lbl_precio = tk.Label(der, text="", bg="#1b2a3a", fg="#cfd8e3",
                                   justify="left", anchor="w",
                                   font=("Segoe UI", 10))
        self.lbl_precio.pack(fill="both", expand=True, anchor="nw")

        self.lbl_espera = tk.Label(der, text="", bg="#1b2a3a", fg="#9fb3c8",
                                   justify="left", anchor="w",
                                   font=("Segoe UI", 9))
        self.lbl_espera.pack(fill="x", anchor="nw")

        for variable in (self.var_corto_km, self.var_corto, self.var_medio_km,
                         self.var_medio, self.var_largo, self.var_cortesia):
            variable.trace_add("write", lambda *a: self._pintar_ejemplo())

    # ---------------- helpers de construccion ----------------

    def _titulo(self, parent, texto):
        tk.Label(parent, text=texto, bg="#243447", fg="#ffc107",
                 font=("Segoe UI", 10, "bold")).pack(anchor="w", pady=(10, 2))

    def _campo(self, parent, etiqueta, variable):
        marco = tk.Frame(parent, bg="#243447")
        marco.pack(fill="x", pady=(2, 0))
        tk.Label(marco, text=etiqueta, bg="#243447", fg="#cfd8e3",
                 font=("Segoe UI", 8)).pack(anchor="w")
        entrada = tk.Entry(marco, textvariable=variable, font=("Segoe UI", 10),
                           bg="#1b2a3a", fg="#ffffff", insertbackground="#ffffff",
                           relief="flat", highlightthickness=1,
                           highlightbackground="#3d5a73")
        entrada.pack(fill="x", ipady=2)
        return entrada

    # ---------------- validacion en local ----------------

    def _leer(self, variable, nombre):
        texto = (variable.get() or "").replace(",", ".").strip()
        if not texto:
            return None, "Escriba %s." % nombre
        try:
            return float(texto), None
        except ValueError:
            return None, "%s debe ser un número." % nombre

    def _revisar(self):
        """Valida en local y devuelve el cuerpo, o (None, motivo).

        Se valida aqui y no solo en el backend para que el administrador no
        descubra el error cuando pulse Guardar, y para poder señalar la casilla
        que esta mal.
        """
        cuerpo, errores = {}, []

        corto_km, error = self._leer(self.var_corto_km, "el límite de las cortas")
        if error:
            errores.append(error)
        medio_km, error = self._leer(self.var_medio_km, "el límite de las medias")
        if error:
            errores.append(error)

        if not errores:
            if corto_km <= 0 or medio_km <= 0:
                errores.append("Los límites en kilómetros deben ser mayores que cero.")
            elif corto_km >= medio_km:
                errores.append("El límite de las cortas (%s km) tiene que ser menor "
                               "que el de las medias (%s km)."
                               % (corto_km, medio_km))
            else:
                cuerpo["coef_corto_km"] = corto_km
                cuerpo["coef_medio_km"] = medio_km

        for variable, nombre, clave in (
                (self.var_corto, "el coeficiente de las cortas", "coef_corto_valor"),
                (self.var_medio, "el coeficiente de las medias", "coef_medio_valor"),
                (self.var_largo, "el coeficiente de las largas", "coef_largo_valor")):
            valor, error = self._leer(variable, nombre)
            if error:
                errores.append(error)
            elif valor <= 0:
                errores.append("%s debe ser mayor que cero: con cero, las carreras "
                               "de ese tramo no costarían nada." % nombre)
            else:
                cuerpo[clave] = valor

        cortesia, error = self._leer(self.var_cortesia, "la espera de cortesía")
        if error:
            errores.append(error)
        elif cortesia < 0:
            errores.append("La espera de cortesía no puede ser negativa.")
        else:
            cuerpo["tiempo_espera_cortesia_minutos"] = cortesia

        if errores:
            return None, "\n".join(errores)
        return cuerpo, None

    # ---------------- el ejemplo de la derecha ----------------

    def _pintar_ejemplo(self):
        """Ejemplo con la tarifa real de la plataforma.

        Se calcula con los mismos numeros con los que cobra el backend (base,
        precio por km y precio por minuto) para que el administrador vea el
        efecto de un coeficiente y no una formula abstracta.
        """
        cuerpo, problema = self._revisar()
        if cuerpo is None:
            self.lbl_precio.config(text="")
            self.lbl_espera.config(text=problema, fg="#ff6b6b")
            return

        base, precio_km, precio_min = 1500.0, 700.0, 5.0
        corto_km = cuerpo["coef_corto_km"]
        medio_km = cuerpo["coef_medio_km"]

        lineas = []
        for km in (2, 5, 12, 25):
            if km <= corto_km:
                coef, tramo = cuerpo["coef_corto_valor"], "corta"
            elif km <= medio_km:
                coef, tramo = cuerpo["coef_medio_valor"], "media"
            else:
                coef, tramo = cuerpo["coef_largo_valor"], "larga"
            # El tiempo del viaje: a 30 km/h de media, un km son 2 minutos.
            minutos = (km / 30.0) * 60.0
            precio = base + (km * precio_km * coef) + (minutos * precio_min)
            linea = "Viaje de %2d km (%-5s, x%s)   %s CUP" % (
                km, tramo, ("%.2f" % coef).rstrip("0").rstrip("."), money(precio))
            lineas.append(linea)

        lineas.append("")
        lineas.append("Con un coeficiente de 1.0 el precio es el de siempre: "
                      "por encima de %s km ya se cobra entero." % medio_km)

        self.lbl_precio.config(text="\n".join(lineas))

        minutos_cortesia = cuerpo["tiempo_espera_cortesia_minutos"]
        if minutos_cortesia == 0:
            texto_espera = ("Sin cortesía: se cobra todo el tiempo que el pasajero "
                            "tarde en subir.")
        else:
            texto_espera = ("Cortesía: %s min gratis. Si el pasajero tarda 12 min en "
                            "subir, se cobran %s min de espera (8 de cortesía y 4 de "
                            "exceso)." % (minutos_cortesia,
                                          12 - minutos_cortesia
                                          if 12 > minutos_cortesia else 0))
        self.lbl_espera.config(text=texto_espera, fg="#9fb3c8")

    # ---------------- datos ----------------

    def cargar(self):
        self.api = self.app.api
        consultar_en_hilo(self, lambda api: api.tarifas_espera(), self._pintar,
                          lambda e: self._fallo(e), "Cargando tarifas...")

    def _fallo(self, e):
        self.app.status("Error: %s" % e.mensaje, error=True)
        messagebox.showerror("Tarifas y Espera", str(e.mensaje))

    def _pintar(self, datos):
        if not datos:
            return
        self.var_corto_km.set(("%.4g" % float(datos.get("coef_corto_km", 3))))
        self.var_corto.set(("%.4g" % float(datos.get("coef_corto_valor", 0.5))))
        self.var_medio_km.set(("%.4g" % float(datos.get("coef_medio_km", 10))))
        self.var_medio.set(("%.4g" % float(datos.get("coef_medio_valor", 0.6))))
        self.var_largo.set(("%.4g" % float(datos.get("coef_largo_valor", 1.0))))
        self.var_cortesia.set(("%.4g" % float(
            datos.get("tiempo_espera_cortesia_minutos", 4))))

        self._pintar_ejemplo()
        self.lbl_estado.config(text="Configuración cargada", fg="#9fb3c8")
        self.app.status("Tarifas cargadas")

    def guardar(self):
        self.api = self.app.api
        cuerpo, problema = self._revisar()
        if cuerpo is None:
            self.lbl_estado.config(text=problema, fg="#ff6b6b")
            messagebox.showerror("Tarifas y Espera", problema)
            return

        if not messagebox.askyesno(
                "Guardar tarifas",
                "Se aplicara esto a todos los viajes:\n\n"
                "Corta: hasta %s km, x%s\n"
                "Media: hasta %s km, x%s\n"
                "Larga: mas de %s km, x%s\n"
                "Espera de cortesía: %s min\n\n¿Continuar?"
                % (cuerpo["coef_corto_km"], cuerpo["coef_corto_valor"],
                   cuerpo["coef_medio_km"], cuerpo["coef_medio_valor"],
                   cuerpo["coef_medio_km"], cuerpo["coef_largo_valor"],
                   cuerpo["tiempo_espera_cortesia_minutos"])):
            return

        self.app.status("Guardando tarifas...")
        consultar_en_hilo(
            self, lambda api: api.guardar_tarifas_espera(**cuerpo),
            self._tras_guardar, lambda e: self._fallo(e),
            "Guardando tarifas...")

    def _tras_guardar(self, datos):
        self._pintar(datos)
        self.lbl_estado.config(text="Tarifas guardadas", fg="#2ecc71")
        self.app.status("Tarifas guardadas")
        messagebox.showinfo("Tarifas y Espera", "Tarifas y espera guardadas.")
