import io, re, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
f = 'lib/services/api_service.dart'
t = io.open(f, encoding='utf-8').read()

# `circulation` y `licenseNumber` pasan a opcionales y dejan de enviarse: ya se
# validan con los documentos, no con un campo de texto libre.
t = t.replace("    required String circulation,\n", "")
t = t.replace("    required String licenseNumber,\n", "")
t = t.replace("      'license_number': licenseNumber,\n", "")
t = t.replace("        'circulation': circulation,\n", "")

io.open(f, 'w', encoding='utf-8', newline='').write(t)
print("quedan referencias:", t.count('circulation'), t.count('licenseNumber'))
