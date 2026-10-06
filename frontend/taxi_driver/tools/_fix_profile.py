import io, re, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
f = 'lib/screens/driver_profile_screen.dart'
t = io.open(f, encoding='utf-8').read()
viejo = re.compile(r"  String _type\(String\? type\) \{.*?\n  \}\n", re.S)
assert viejo.search(t), "no se encontro _type"
t = viejo.sub(
  "  /// Etiqueta del tipo de vehiculo, desde la configuracion del backend.\n"
  "  ///\n"
  "  /// Antes era un `switch` con los tipos escritos a mano; si el\n"
  "  /// administrador anadia uno nuevo en `tariffs`, aqui no saldria.\n"
  "  String _type(String? type) => _tiposVehiculo.etiquetaDe(type);\n", t, count=1)
io.open(f, 'w', encoding='utf-8', newline='').write(t)
print("profile ok")
