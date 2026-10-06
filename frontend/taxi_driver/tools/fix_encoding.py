import glob
import io

# Mapa de correccion: (texto roto) -> (texto correcto).
#
# El problema de origen es doble codificacion: los bytes UTF-8 del caracter de
# reemplazo (EF BF BD) se leyeron como Latin-1 y se volvieron a guardar como
# UTF-8, con lo que un acento normal quedo como un unico U+FFFD en el fuente.
# La secuencia rota no dice cual era el acento original, asi que cada caso se
# corrige uno a uno.
#
# Los textos visibles al usuario llevan acentuacion completa. Los comentarios
# tambien: son la documentacion del modulo y se leen igual de seguido.
REGLAS = [
    # ---------------- Comentarios ----------------
    ("el chofer a\ufffdn va hacia",              "el chofer aún va hacia"),
    ("la ubicaci\ufffdn real de recog",          "la ubicación real de recog"),
    ("desde aqu\ufffd se cuentan",               "desde aquí se cuentan"),
    ("los kil\ufffdmetros",                       "los kilómetros"),
    ("COMUNICACI\ufffdn CON EL PASAJERO",        "COMUNICACIÓN CON EL PASAJERO"),
    ("la posici\ufffdn al backend",              "la posición al backend"),
    ("que la reenv\ufffda a Traccar",             "que la reenvía a Traccar"),
    ("el viaje est\ufffd activo",                "el viaje está activo"),
    ("en el pr\ufffdximo tick",                  "en el próximo tick"),
    ("DI\ufffdLOGOS",                            "DIÁLOGOS"),
    ("L\ufffdnea con la direcci\ufffdn",          "Línea con la dirección"),
    ("Direcci\ufffdn legible",                   "Dirección legible"),
    ("la direcci\ufffdn que envi\ufffd el",      "la dirección que envió el"),
    ("el viaje se cre\ufffd con un pin",         "el viaje se creó con un pin"),
    ("(sin direcci\ufffdn)",                     "(sin dirección)"),
    ("no hay direcci\ufffdn)",                   "no hay dirección)"),
    ("PUNTOS DE INTER\ufffdS",                   "PUNTOS DE INTERÉS"),

    # Casos con salto de linea en medio, que no casan con los patrones de arriba.
    ("COMUNICACI\ufffdn CON",                    "COMUNICACIÓN CON"),
    ("viaje se cre\ufffd con un pin",            "viaje se creó con un pin"),
    ("if (t.isEmpty) return 'Veh\ufffdculo'",    "if (t.isEmpty) return 'Vehículo'"),

    # ---------------- Textos visibles ----------------
    ("'No hay un n\ufffdmero de tel\ufffdfono",  "'No hay un número de teléfono"),
    ("'Duraci\ufffdn'",                          "'Duración'"),
    ("'Comisi\ufffdn 15%'",                      "'Comisión 15%'"),
    ("tooltip: 'Men\ufffd'",                     "tooltip: 'Menú'"),
    ("' \ufffd ${_toPickupMin",                  "' · ${_toPickupMin"),
    ("'Se borrar\ufffd en:",                     "'Se borrará en:"),
    ("pasajero(s) \ufffd Efectivo",              "pasajero(s) · Efectivo"),
    ("?? 'Veh\ufffdculo'",                       "?? 'Vehículo'"),
    ("'Mi veh\ufffdculo'",                       "'Mi vehículo'"),
    ("'No recibir\ufffds nuevas",                "'No recibirás nuevas"),
    ("esta opci\ufffdn se te mostrar\ufffdn",    "esta opción se te mostrarán"),
    ("return 'B\ufffdsico';",                    "return 'Básico';"),
    ("'Llegu\ufffd al punto de recogida'",       "'Llegué al punto de recogida'"),
    ("'Configuraci\ufffdn'",                     "'Configuración'"),
    ("'Cerrar sesi\ufffdn'",                     "'Cerrar sesión'"),
    # El mas visible: separador del titulo y estado sin traducir.
    ("'VIAJE EN CURSO \ufffd ${trip.status.toUpperCase()}'",
     "'VIAJE EN CURSO · ${estadoViaje(trip.status)}'"),
]

archivos = glob.glob("lib/**/*.dart", recursive=True) + glob.glob("test/*.dart")

for f in sorted(archivos):
    txt = io.open(f, encoding="utf-8").read()
    original = txt
    for roto, bien in REGLAS:
        txt = txt.replace(roto, bien)
    if txt != original:
        # utf-8 y sin BOM, que es lo que Dart espera.
        io.open(f, "w", encoding="utf-8", newline="").write(txt)
        restantes = txt.count("\ufffd")
        print("%-50s corregido%s" % (
            f, ", quedan %d" % restantes if restantes else ", limpio"))