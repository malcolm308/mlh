import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
f = 'lib/screens/driver_home_screen.dart'
t = io.open(f, encoding='utf-8').read()

t = t.replace(
  "    _loadTodayEarnings();\n    _initGps();\n    _loadPois();",
  "    // Tipos de vehiculo: se piden una vez para poder pintar las etiquetas de\n"
  "    // las ofertas y del viaje. Si falla, el servicio usa la lista de respaldo.\n"
  "    _tiposVehiculo.cargar();\n"
  "\n"
  "    _loadTodayEarnings();\n    _initGps();\n    _loadPois();")

t = t.replace(
  "    _nav.dispose();\n    _subRecalc?.cancel();",
  "    _nav.dispose();\n    _tiposVehiculo.dispose();\n    _subRecalc?.cancel();")

io.open(f, 'w', encoding='utf-8', newline='').write(t)
print("ok")
