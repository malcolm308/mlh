import io, re, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
f = 'lib/screens/register_screen.dart'
t = io.open(f, encoding='utf-8').read()

# 1. Estado: el tipo elegido y el servicio de tipos.
t = t.replace(
  "  final _servicio = TextEditingController();\n",
  "  /// Tipo de servicio elegido. Va en `String?` porque todavia no se ha\n"
  "  /// escogido; el valor es el identificador de la tabla `tariffs`.\n"
  "  String? _tipo;\n"
  "\n"
  "  /// Tipos que publica el backend, cacheados para la pantalla.\n"
  "  final VehicleTypesService _vehiculos = VehicleTypesService();\n")

# 2. Quitar el controller de la lista de dispose.
t = t.replace("_chapa, _color, _servicio,", "_chapa, _color,")

# 3. El envio usa el tipo elegido, no un texto libre.
t = t.replace("      servicio: _servicio.text.trim(),", "      servicio: _tipo ?? 'basico',")
t = t.replace("typeVehicle: 'basico',", "typeVehicle: _tipo ?? 'basico',")

# 4. Import del servicio.
if 'vehicle_types_service.dart' not in t:
    t = t.replace("import '../services/", "import '../services/vehicle_types_service.dart';\nimport '../services/", 1)

io.open(f, 'w', encoding='utf-8', newline='').write(t)
print("_servicio restante:", t.count('_servicio'))
