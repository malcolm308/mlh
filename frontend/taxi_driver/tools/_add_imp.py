import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
for f, anchor in [
    ('lib/screens/driver_home_screen.dart', "import '../services/location_service.dart';"),
    ('lib/screens/driver_profile_screen.dart', "import '../services/"),
]:
    t = io.open(f, encoding='utf-8').read()
    if 'vehicle_types_service.dart' not in t:
        t = t.replace(anchor,
            "import '../services/vehicle_types_service.dart';\n" + anchor, 1)
        io.open(f, 'w', encoding='utf-8', newline='').write(t)
        print("import anadido en", f)
