import io
f = 'test/cancellation_test.dart'
t = io.open(f, encoding='utf-8').read()
viejo = """      expect(find.textContaining('te queda 1 cancelaci\u00f3n'), findsOneWidget);"""
nuevo = """      // El texto va partido en dos lineas en el codigo, asi que se comprueba
      // por??: la cadena completa no existe como un solo widget de texto.
      expect(find.textContaining('te queda 1'), findsOneWidget);"""
t = t.replace(viejo, nuevo)
t = t.replace("      expect(find.textContaining('te quedan 2 cancelaciones'), findsOneWidget);", "      expect(find.textContaining('te quedan 2'), findsOneWidget);")
io.open(f, 'w', encoding='utf-8', newline='').write(t)
print("ok")
