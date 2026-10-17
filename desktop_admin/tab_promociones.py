"""Pestana Promociones y Comisiones: configuracion global de la plataforma.

Lo que se ajusta desde aqui son tres cosas que se aplican a todos los choferes
y a todos los viajes: la comision que cobra la plataforma, el bono diario del
chofer y el descuento que se le puede hacer al pasajero.

La regla que gobierna el formulario: con comision 0% el pasajero no puede
tener descuento. No porque se prohíba escribirlo, sino porque la plataforma no
tendria de donde pagarlo, asi que el campo se apaga solo y avisa de por que. Lo
mismo hace el backend, para que una llamada directa a la API no se lo salte.
"""
import tkinter as tk
from datetime import date
from tkinter import ttk, messagebox

from ui_common import boton, consultar_en_hilo, money, PanelDesplazable

# Topes. Son los mismos que impone el backend; se repiten aqui para avisar al
# administrador sin una ida y vuelta por la red, no para hacerlos autoritarios.
DESCUENTO_MAXIMO_PCT = 10.0


class TabPromociones(ttk.Frame):
    def __init__(self, master, app):
        super().__init__(master)
        self.app = app
        self.api = app.api
        self._consulta_en_curso = False
        self._build()
        self.after(200, self.cargar)

    # ---------------- construccion ----------------

    def _build(self):
        self.panel = PanelDesplazable(self, ancho=360)
        self.panel.pack(side="left", fill="y", padx=(10, 6), pady=8)
        izq = self.panel.cuerpo

        tk.Label(izq, text="Promociones y Comisiones", bg="#243447", fg="#ffffff",
                 font=("Segoe UI", 12, "bold")).pack(anchor="w", pady=(0, 4))
        tk.Label(izq,
                 text="Los porcentajes se escriben en puntos: 0.15 es el 15%.",
                 bg="#243447", fg="#9fb3c8",
                 font=("Segoe UI", 8)).pack(anchor="w", pady=(0, 10))

        # ---- comision ----
        self._titulo(izq, "Comisión de la plataforma")
        self.var_comision = tk.StringVar(value="0.15")
        self.ent_comision = self._campo(izq, "Comisión (0 a 1)",
                                        self.var_comision)
        # Se vigila en cada pulsacion: con 0 hay que apagar el descuento al
        # instante, no cuando el administrador pulse Guardar.
        self.ent_comision.bind("<KeyRelease>", lambda e: self._al_cambiar_comision())
        self.ent_comision.bind("<FocusOut>", lambda e: self._al_cambiar_comision())

        # ---- bono al chofer ----
        self._titulo(izq, "Bono diario al chofer")
        self.var_bono_activo = tk.IntVar(value=1)
        self.cb_bono = tk.Checkbutton(
            izq, text="Activar bono", variable=self.var_bono_activo,
            command=self._al_cambiar_bono, bg="#243447", fg="#cfd8e3",
            activebackground="#243447", activeforeground="#ffffff",
            selectcolor="#1b2a3a", font=("Segoe UI", 9), anchor="w")
        self.cb_bono.pack(fill="x", pady=(2, 2))

        self.var_bono_monto = tk.StringVar(value="1100")
        self.ent_bono_monto = self._campo(izq, "Monto del bono (CUP)",
                                          self.var_bono_monto)
        self.var_bono_viajes = tk.StringVar(value="10")
        self.ent_bono_viajes = self._campo(izq, "Viajes completados para pagarlo",
                                           self.var_bono_viajes)

        # ---- descuento al cliente ----
        self._titulo(izq, "Descuento al cliente")
        self.var_desc_activo = tk.IntVar(value=0)
        self.cb_descuento = tk.Checkbutton(
            izq, text="Activar descuento", variable=self.var_desc_activo,
            command=self._al_cambiar_descuento, bg="#243447", fg="#cfd8e3",
            activebackground="#243447", activeforeground="#ffffff",
            selectcolor="#1b2a3a", font=("Segoe UI", 9), anchor="w")
        self.cb_descuento.pack(fill="x", pady=(2, 2))

        self.var_desc_pct = tk.StringVar(value="0.10")
        self.ent_desc_pct = self._campo(
            izq, "Descuento (0 a 0.10, máximo %s%%)" % DESCUENTO_MAXIMO_PCT,
            self.var_desc_pct)

        # Aviso de por que el descuento no se puede tocar. Se muestra y se
        # esconde, no se borra: vaciarlo y reponerlo en cada cambio deja el
        # formulario dando saltos.
        self.lbl_aviso = tk.Label(
            izq, text="", bg="#243447", fg="#ffc107", wraplength=320,
            justify="left", font=("Segoe UI", 8))
        self.lbl_aviso.pack(anchor="w", pady=(4, 6))

        # ---- caducidad ----
        self._titulo(izq, "Caducidad")
        self.var_fecha = tk.StringVar(value=date.today().isoformat())
        self.ent_fecha = self._campo(izq, "Vence el (AAAA-MM-DD). Vacío = nunca",
                                     self.var_fecha)
        tk.Label(izq, text="Pasada esa fecha el backend ignora la promoción.",
                 bg="#243447", fg="#6b7d8f",
                 font=("Segoe UI", 8)).pack(anchor="w")

        self.lbl_estado = tk.Label(izq, text="", bg="#243447", fg="#9fb3c8",
                                   wraplength=320, justify="left",
                                   font=("Segoe UI", 8))
        self.lbl_estado.pack(anchor="w", pady=(8, 0))

        boton(izq, "Guardar Configuración", self.guardar,
              color="#2ecc71", fg="#ffffff").pack(fill="x", pady=(12, 0))
        boton(izq, "Recargar", self.cargar,
              color="#4a5b6c", fg="#ffffff").pack(fill="x", pady=(6, 0))

        # ---------------- derecha: como queda el reparto ----------------

        der = ttk.Frame(self)
        der.pack(side="left", fill="both", expand=True, padx=(6, 10), pady=8)

        tk.Label(der, text="Cómo se reparte un viaje de 10.00", bg="#1b2a3a",
                 fg="#ffc107", font=("Segoe UI", 12, "bold")).pack(anchor="w")
        tk.Label(der,
                 text="Con estos valores, así queda el dinero de un viaje de 10.00. "
                      "El descuento lo paga la plataforma: el chofer nunca pierde "
                      "por un descuento al pasajero.",
                 bg="#1b2a3a", fg="#9fb3c8", justify="left",
                 font=("Segoe UI", 9)).pack(anchor="w", pady=(4, 10))

        self.lbl_reparto = tk.Label(der, text="", bg="#1b2a3a", fg="#cfd8e3",
                                    justify="left", anchor="w",
                                    font=("Segoe UI", 10))
        self.lbl_reparto.pack(fill="both", expand=True, anchor="nw")

        self._al_cambiar_comision()

    # ---------------- helpers de construccion ----------------

    def _titulo(self, parent, texto):
        tk.Label(parent, text=texto, bg="#243447", fg="#ffc107",
                 font=("Segoe UI", 10, "bold")).pack(anchor="w", pady=(10, 2))

    def _campo(self, parent, etiqueta, variable):
        """Label encima + Entry, el mismo criterio que usa `tab_billetera._campo`."""
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

    # ---------------- reglas de negocio en el formulario ----------------

    def _comision_valida(self):
        try:
            valor = float(self.var_comision.get().replace(",", "."))
        except (TypeError, ValueError):
            return None
        return valor if 0.0 <= valor <= 1.0 else None

    def _al_cambiar_comision(self):
        """Con comision 0 el descuento no se puede aplicar. Se desactiva la
        casilla, se vacia el porcentaje y se explica por que."""
        comision = self._comision_valida()
        cero = comision == 0.0

        self.var_desc_activo.set(0 if cero else self.var_desc_activo.get())
        self.ent_desc_pct.config(
            state="normal" if comision is not None and not cero else "disabled")
        self.cb_descuento.config(
            state="normal" if comision is not None and not cero else "disabled")

        if cero:
            self.var_desc_pct.set("0")
            self.lbl_aviso.config(
                text="Con comisión 0%, no se pueden aplicar descuentos a clientes. "
                     "La plataforma no tiene de donde pagarlos.")
        else:
            self.lbl_aviso.config(text="")

        # Con la comision en un valor malo el formulario tiene que decirlo, no
        # adivinar.
        if comision is None:
            self.lbl_estado.config(
                text="La comisión debe ser un número entre 0 y 1. Ejemplo: 0.15",
                fg="#ff6b6b")
        self._pintar_reparto()

    def _al_cambiar_bono(self):
        activo = bool(self.var_bono_activo.get())
        estado = "normal" if activo else "disabled"
        self.ent_bono_monto.config(state=estado)
        self.ent_bono_viajes.config(state=estado)

    def _al_cambiar_descuento(self):
        """Al apagar la casilla se vuelve a los valores por defecto."""
        if not self.var_desc_activo.get():
            self.var_desc_pct.set("0")
        elif self._comision_valida() == 0.0:
            self.var_desc_activo.set(0)
            self.var_desc_pct.set("0")
        self._pintar_reparto()

    def _leer_porcentaje(self, variable, nombre):
        texto = (variable.get() or "").replace(",", ".").strip()
        if not texto:
            return None, "Escriba %s." % nombre
        try:
            valor = float(texto)
        except ValueError:
            return None, "%s debe ser un número." % nombre
        return valor, None

    # ---------------- validacion antes de enviar ----------------

    def _revisar(self):
        """Valida en local y devuelve el cuerpo, o (None, motivo)."""
        comision, error = self._leer_porcentaje(self.var_comision, "la comisión")
        if error:
            return None, error
        if not 0.0 <= comision <= 1.0:
            return None, "La comisión debe estar entre 0 y 1. Ejemplo: 0.15 es el 15%."

        descuento, error = self._leer_porcentaje(self.var_desc_pct,
                                                 "el descuento al cliente")
        if error:
            return None, error
        if descuento < 0 or descuento > DESCUENTO_MAXIMO_PCT / 100.0:
            return None, ("El descuento al cliente no puede pasar de %s%%."
                          % DESCUENTO_MAXIMO_PCT)

        descuento_activo = bool(self.var_desc_activo.get())
        if comision == 0.0:
            # No es un error: el formulario ya lo apagó. Se manda apagado.
            descuento_activo = False
            descuento = 0.0
        elif descuento_activo and descuento > comision:
            return None, ("El descuento (%s%%) no puede ser mayor que la comisión "
                          "(%s%%): la plataforma no puede perder dinero."
                          % (round(descuento * 100, 2), round(comision * 100, 2)))

        bono_monto, error = self._leer_porcentaje(self.var_bono_monto,
                                                  "el monto del bono")
        if error:
            return None, error
        if bono_monto < 0:
            return None, "El monto del bono no puede ser negativo."

        try:
            bono_viajes = int(float(self.var_bono_viajes.get().replace(",", ".")))
        except (TypeError, ValueError):
            return None, "Los viajes requeridos deben ser un número entero."
        if bono_viajes < 0:
            return None, "Los viajes requeridos no pueden ser negativos."

        fecha = (self.var_fecha.get() or "").strip()
        if fecha:
            try:
                from datetime import datetime as _dt
                _dt.strptime(fecha, "%Y-%m-%d")
            except ValueError:
                return None, "La fecha no es válida. Use el formato AAAA-MM-DD."

        return {
            "comision_porcentaje": comision,
            "bono_chofer_activo": bool(self.var_bono_activo.get()),
            "bono_chofer_monto": bono_monto,
            "bono_chofer_viajes_requeridos": bono_viajes,
            "descuento_cliente_activo": descuento_activo,
            "descuento_cliente_porcentaje": descuento,
            "fecha_expiracion": fecha or None,
        }, None

    # ---------------- reparto (lo que ve el administrador) ----------------

    def _pintar_reparto(self):
        """Ejemplo con un viaje de 10.00, que es el caso que esta en el
        enunciado. Se calcula aqui y no se copia de un texto fijo: si el
        administrador cambia la comision, el ejemplo cambia con ella."""
        comision = self._comision_valida()
        if comision is None:
            self.lbl_reparto.config(text="")
            return

        precio = 10.00
        try:
            descuento_pct = float((self.var_desc_pct.get() or "0").replace(",", "."))
        except (TypeError, ValueError):
            descuento_pct = 0.0

        descuento_activo = bool(self.var_desc_activo.get())
        if comision == 0.0 or not descuento_activo:
            descuento = 0.0
        else:
            descuento = round(precio * descuento_pct, 2)
            # El descuento nunca puede pasar de lo que gana la plataforma.
            if descuento > round(precio * comision, 2):
                descuento = round(precio * comision, 2)

        nominal = round(precio * comision, 2)
        cobrado = max(0.0, round(nominal - descuento, 2))
        paga = round(precio - descuento, 2)
        chofer = round(precio - nominal, 2)
        plataforma = round(paga - chofer, 2)

        lineas = [
            "Precio del viaje                %s CUP" % money(precio),
            "Comisión nominal (%.4g%%)      %s CUP" % (comision * 100, money(nominal)),
            "Descuento al cliente            -%s CUP" % money(descuento),
            "",
            "Paga el pasajero                %s CUP" % money(paga),
            "Comisión que sale del Fondo     -%s CUP" % money(cobrado),
            "",
            "Conserva el chofer              %s CUP" % money(chofer),
            "Se queda la plataforma          %s CUP" % money(plataforma),
            "",
            "El chofer conserva siempre %s CUP: el descuento lo absorbe la plataforma."
            % money(chofer),
        ]
        if comision == 0.0:
            lineas.append("")
            lineas.append("Con comisión 0% el chofer se lleva el viaje entero.")
        self.lbl_reparto.config(text="\n".join(lineas))

    # ---------------- datos ----------------

    def cargar(self):
        self.api = self.app.api
        consultar_en_hilo(self, lambda api: api.promocion(), self._pintar,
                          lambda e: self._fallo(e), "Cargando configuracion...")

    def _fallo(self, e):
        self.app.status("Error: %s" % e.mensaje, error=True)
        messagebox.showerror("Promociones", str(e.mensaje))

    def _pintar(self, datos):
        if not datos:
            return
        self.var_comision.set(("%.4g" % float(datos.get("comision_porcentaje", 0))))
        self.var_bono_activo.set(1 if datos.get("bono_chofer_activo") else 0)
        self.var_bono_monto.set(("%.2f" % float(datos.get("bono_chofer_monto", 0))))
        self.var_bono_viajes.set(str(datos.get("bono_chofer_viajes_requeridos", 0)))
        self.var_desc_activo.set(1 if datos.get("descuento_cliente_activo") else 0)
        self.var_desc_pct.set(("%.4g" % float(datos.get("descuento_cliente_porcentaje", 0))))
        self.var_fecha.set(datos.get("fecha_expiracion") or "")

        self._al_cambiar_bono()
        self._al_cambiar_comision()

        partes = ["Configuración cargada"]
        if datos.get("descuento_bloqueado_por_comision_cero"):
            partes.append("Comisión 0%: sin descuentos a clientes")
        if datos.get("descuento_aplicando"):
            partes.append("Descuento %s activo"
                          % datos.get("descuento_cliente_porcentaje_texto", ""))
        elif datos.get("descuento_cliente_porcentaje"):
            partes.append("Descuento %s cargado pero inactivo"
                          % datos.get("descuento_cliente_porcentaje_texto", ""))
        if datos.get("expirada"):
            partes.append("PROMOCIÓN EXPIRADA: el backend la está ignorando")
        if datos.get("actualizado_por"):
            partes.append("Último cambio: %s" % datos["actualizado_por"])

        self.lbl_estado.config(
            text="\n".join(partes),
            fg="#ff6b6b" if datos.get("expirada") else "#9fb3c8")
        self.app.status("Configuración cargada")

    def guardar(self):
        self.api = self.app.api
        cuerpo, problema = self._revisar()
        if cuerpo is None:
            self.lbl_estado.config(text=problema, fg="#ff6b6b")
            messagebox.showerror("Promociones", problema)
            return

        if not messagebox.askyesno(
                "Guardar configuración",
                "Se aplicara esto a todos los viajes y choferes:\n\n"
                "Comisión: %s%%\nBono: %s\nDescuento al cliente: %s\n\n¿Continuar?"
                % (round(cuerpo["comision_porcentaje"] * 100, 2),
                   ("activo, %s CUP por %d viajes"
                    % (money(cuerpo["bono_chofer_monto"]),
                       cuerpo["bono_chofer_viajes_requeridos"]))
                   if cuerpo["bono_chofer_activo"] else "desactivado",
                   ("activo, %s%%" % round(cuerpo["descuento_cliente_porcentaje"] * 100, 2))
                   if cuerpo["descuento_cliente_activo"] else "desactivado")):
            return

        self.app.status("Guardando configuración...")
        consultar_en_hilo(
            self, lambda api: api.guardar_promocion(**cuerpo),
            self._pintar, lambda e: self._fallo(e),
            "Guardando configuración...")