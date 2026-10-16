"""
Arregla la ortografia de los mensajes de error del backend que llegan LITERALES
a la pantalla del movil.

Por que un script y no edicion a mano: son decenas de cadenas repetidas por nueve
routers, y la app hace `j['detail']` y lo pinta tal cual. Arreglarlas a mano es
facil olvidar una.

Por que solo cadenas completas: se reemplaza el literal ENTERO, con sus comillas,
nunca un fragmento. Un reemplazo por palabra es peligroso de verdad: `telefono`
es subcadena de `numero_de_telefono`, asi que cambiar `telefono` por `telefono`
con tilde habria renombrado el campo de la base en todo el backend. Aqui no
puede pasar eso: si el literal no esta completo, no se toca nada.

    python -X utf8 tools/arreglar_ortografia_backend.py --simular
    python -X utf8 tools/arreglar_ortografia_backend.py
"""
import io
import os
import sys

# Literal completo tal como esta -> literal completo como debe estar.
# Solo entradas donde el texto viejo y el nuevo son distintos.
SUSTITUCIONES = [
    # --- errores de login y cuentas ---
    ("Email o contrasena incorrectos", "Correo o contraseña incorrectos"),
    ("Email ya registrado", "Correo ya registrado"),
    ("Tu cuenta esta pendiente de aprobacion por el administrador",
     "Tu cuenta está pendiente de aprobación por el administrador"),
    ("Tu cuenta esta deshabilitada", "Tu cuenta está deshabilitada"),

    # --- tokens y permisos ---
    ("Token invalido", "Token inválido"),
    ("Token de administrador invalido", "Token de administrador inválido"),
    ("Necesitas iniciar sesion como administrador",
     "Necesitas iniciar sesión como administrador"),
    ("Necesitas iniciar sesion", "Necesitas iniciar sesión"),

    # --- identificadores y estados ---
    ("Id de chofer invalido", "Id de chofer inválido"),
    ("Estado invalido", "Estado inválido"),
    ("Fecha invalida", "Fecha inválida"),
    ("Metodo invalido", "Método inválido"),
    ("id invalido", "id inválido"),
    ("categoria debe ser una de", "categoría debe ser una de"),

    # --- viajes ---
    ("El conductor no esta disponible", "El conductor no está disponible"),
    ("El viaje no esta disponible", "El viaje no está disponible"),
    ("El viaje no esta en curso", "El viaje no está en curso"),

    # --- documentos ---
    ("El archivo %s esta vacio", "El archivo %s está vacío"),
    ("El archivo %s no es una imagen valida", "El archivo %s no es una imagen válida"),
    ("No se recibio ninguna imagen", "No se recibió ninguna imagen"),
    ("Numero de circulacion", "Número de circulación"),
    ("Sin articulacion", "Sin articulación"),
    ("La articulacion es obligatoria", "La articulación es obligatoria"),

    # --- sesión y búsquedas ---
    ("Tu sesion expiro. Vuelve a iniciar sesion",
     "Tu sesión expiró. Vuelve a iniciar sesión"),
    ("La busqueda no arrojo resultados", "La búsqueda no arrojó resultados"),
    ("La busqueda requiere al menos 2 caracteres",
     "La búsqueda requiere al menos 2 caracteres"),

    # --- billeteras ---
    ("Saldo insuficiente para el debito", "Saldo insuficiente para el débito"),
    ("El monto debe ser mayor que 0", "El monto debe ser mayor que 0"),
    ("Metodo no permitido", "Método no permitido"),

    # --- panel ---
    ("La contrasena debe tener al menos", "La contraseña debe tener al menos"),
    ("La contrasena no puede ir vacia", "La contraseña no puede ir vacía"),
    ("Ya existe un administrador con ese email", "Ya existe un administrador con ese correo"),
    ("El email no tiene un formato valido", "El correo no tiene un formato válido"),
    ("Debe indicar un email", "Debe indicar un correo"),
    ("El correo debe ser valido", "El correo debe ser válido"),
]

ARCHIVOS = [
    os.path.join("routers", nombre)
    for nombre in ("CRUD_MONGODB.py", "documentos.py", "Solicitud_de_viajes_v4.py",
                   "admin_panel.py", "billetera.py", "pois.py", "vehiculos.py",
                   "geo.py", "telegram_webhook.py", "routing.py",
                   "chofer_cancelaciones.py", "tariffs.py")
]


def aplicar(texto: str):
    """Devuelve (texto nuevo, numero de literales cambiados)."""
    total = 0
    for viejo, nuevo in SUSTITUCIONES:
        if viejo == nuevo:
            continue
        for comilla in ('"', "'"):
            antes = comilla + viejo + comilla
            despues = comilla + nuevo + comilla
            apariciones = texto.count(antes)
            if apariciones:
                texto = texto.replace(antes, despues)
                total += apariciones
    return texto, total


def main():
    simular = "--simular" in sys.argv
    archivos_tocados = 0
    cambios = 0

    for ruta in ARCHIVOS:
        if not os.path.isfile(ruta):
            continue
        original = io.open(ruta, encoding="utf-8").read()
        texto, n = aplicar(original)
        if not n:
            continue

        archivos_tocados += 1
        cambios += n
        print("%-42s %2d" % (ruta, n))
        if not simular:
            io.open(ruta, "w", encoding="utf-8", newline="").write(texto)

    print("---")
    verb = "se aplicarian" if simular else "se aplicaron"
    print("%s %d cambio(s) en %d archivo(s)." % (verb.capitalize(), cambios,
                                                   archivos_tocados))
    if simular:
        print("Quita --simular para escribirlos.")


if __name__ == "__main__":
    main()