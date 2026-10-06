import io, re, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
f = 'lib/screens/driver_home_screen.dart'
t = io.open(f, encoding='utf-8').read()

# 1. Estado del servicio de cancelaciones.
t = t.replace(
  "  final VehicleTypesService _tiposVehiculo = VehicleTypesService();",
  "  final VehicleTypesService _tiposVehiculo = VehicleTypesService();\n"
  "\n"
  "  /// Limite de cancelaciones del dia.\n"
  "  ///\n"
  "  /// Solo cuenta lo que el chofer cancela DESPUES de aceptar. Rechazar una\n"
  "  /// oferta no pasa por aqui, asi que se puede rechazar todas las veces que\n"
  "  /// haga falta.\n"
  "  final CancellationService _cancelacion = CancellationService();")

# 2. _completeTrip usa el camino comun de limpieza, sin repetir la logica.
viejo = re.compile(
    r"      _tripPoller\?\.cancel\(\);\n      _tripPoller = null;\n"
    r"      if \(!mounted\) return;\n"
    r"      setState\(\{\n        _activeTrip = null;\n        _loading = false;\n        _route = \[\];\n      \}\);\n"
    r"(.*?)_nav\.finalizar\(\);\n      NavCamera\.reset\(\);\n", re.S)
m = viejo.search(t)
print("bloque de _completeTrip encontrado:", bool(m))
if m:
    # Se deja el aviso a _alPerderElViaje: la completacion no necesita Snackbar.
    t = viejo.sub(
        "      // La limpieza la hace [_alPerderElViaje], el mismo camino que\n"
        "      // usa la cancelacion, para que no se le olvide a ninguno.\n"
        "      await _alPerderElViaje('', mostrarAviso: false);\n"
        "      if (!mounted) return;\n",
        t, count=1)

io.open(f, 'w', encoding='utf-8', newline='').write(t)
