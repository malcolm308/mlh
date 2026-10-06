import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
f = 'lib/services/api_service.dart'
t = io.open(f, encoding='utf-8').read()
# El registro con documentos: circulacion y licencia ya no se envian.
t = t.replace("      ..fields['circulation'] = circulation\n", "")
t = t.replace("      ..fields['license_number'] = licenseNumber\n", "")
io.open(f, 'w', encoding='utf-8', newline='').write(t)
print("restantes:", t.count('circulation'), t.count('licenseNumber'))
