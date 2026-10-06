import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
f = 'lib/screens/driver_profile_screen.dart'
t = io.open(f, encoding='utf-8').read()
viejo = """            _info(Icons.badge_outlined, 'Licencia',
                p.licenseNumber ?? 'No registrada'),"""
nuevo = """            // La licencia ya no se pide en el registro: se valida con el
            // documento. Aqui solo se muestra si el chofer ya la tenia puesta.
            if ((p.licenseNumber ?? '').isNotEmpty)
              _info(Icons.badge_outlined, 'Licencia', p.licenseNumber!),"""
assert viejo in t, "bloque del perfil no encontrado"
t = t.replace(viejo, nuevo)
io.open(f, 'w', encoding='utf-8', newline='').write(t)
print("perfil ok")
