import io, re, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
f = 'lib/screens/register_screen.dart'
t = io.open(f, encoding='utf-8').read()

# 1. Los dos campos del formulario: circulacion y licencia de conducir.
#    Se van porque ya se validan con los documentos que se suben debajo.
patron = re.compile(
    r"\n\s*TextFormField\(\s*\n\s*controller: _circulation,.*?"
    r"\n\s*\),(?=\n\s*const SizedBox\(height: 22\))",
    re.S)
nuevo, n = patron.subn("", t)
print("bloques de campo eliminados:", n)
t = nuevo

# 2. Los controladores.
t = t.replace("  final _circulation = TextEditingController();\n", "")
t = t.replace("  final _license = TextEditingController();\n", "")

# 3. La lista de dispose.
t = t.replace("_chapa, _circulation, _color, _servicio,", "_chapa, _color, _servicio,")
t = t.replace("_maxPassengers, _license,", "_maxPassengers,")

# 4. El envio: ya no se mandan esos campos.
t = re.sub(r"\n\s*circulation: _circulation\.text\.trim\(\),", "", t)
t = re.sub(r"\n\s*licenseNumber: _license\.text\.trim\(\),", "", t)

io.open(f, 'w', encoding='utf-8', newline='').write(t)
print("restantes:", t.count('_circulation'), t.count('_license'))
