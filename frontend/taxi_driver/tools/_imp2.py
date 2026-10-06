import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
f = 'lib/screens/driver_home_screen.dart'
t = io.open(f, encoding='utf-8').read()

# El modelo que devuelve `getTrip` es `TripOffer`, no `Trip`.
t = t.replace("Widget _buildBotonCancelar(Trip t) {", "Widget _buildBotonCancelar(TripOffer t) {")
t = t.replace("Future<void> _cancelarViaje(Trip t) async {", "Future<void> _cancelarViaje(TripOffer t) async {")

# Imports que faltan.
if 'cancellation_service.dart' not in t:
    t = t.replace("import '../services/api_service.dart';",
                  "import '../services/api_service.dart';\nimport '../services/cancellation_service.dart';", 1)
for w in ('cancel_trip_dialog.dart', 'cancel_reason_dialog.dart'):
    if w not in t:
        t = t.replace("import '../widgets/navigation_map_view.dart';",
                      "import '../widgets/navigation_map_view.dart';\nimport '../widgets/%s';" % w, 1)

io.open(f, 'w', encoding='utf-8', newline='').write(t)
print("ok")
