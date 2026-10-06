import io, re, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

# --- driver_home_screen: sustituir el switch por el servicio ---
f = 'lib/screens/driver_home_screen.dart'
t = io.open(f, encoding='utf-8').read()

viejo = re.compile(
    r"  String _vehicleTypeLabel\(String\? type\) \{.*?\n  \}\n", re.S)
assert viejo.search(t), "no se encontro _vehicleTypeLabel"

nuevo = '''  /// Etiqueta del tipo de vehiculo, desde la configuracion del backend.
  ///
  /// Antes era un `switch` con los cuatro tipos escritos a mano, repetido en
  /// varias pantallas. Si el administrador anadia un tipo nuevo en la tabla
  /// `tariffs` de PostgreSQL, aqui salia el identificador en crudo en vez de la
  /// etiqueta. Ahora delega en [VehicleTypesService], que es la unica fuente.
  String _vehicleTypeLabel(String? type) => _tiposVehiculo.etiquetaDe(type);
'''
t = viejo.sub(nuevo, t, count=1)

# Estado del servicio, compartido por la pantalla.
t = t.replace(
  "  final VehicleTypesService _vehiculos = VehicleTypesService();\n", "")

io.open(f, 'w', encoding='utf-8', newline='').write(t)
print("driver_home_screen ok")
