import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
f = 'lib/screens/driver_home_screen.dart'
t = io.open(f, encoding='utf-8').read()

# Cargar el contador al aceptar un viaje, que es cuando empieza a contar.
t = t.replace(
  "      _startTripPoller();\n      _refreshRoutes();\n    } catch (e) {\n      if (!mounted) return;\n      setState(() => _loading = false);\n      _showError('$e');\n      await _tick();",
  "      _startTripPoller();\n"
  "      // El limite de cancelaciones se consulta al empezar un viaje: es\n"
  "      // cuando empieza a contar, y asi el boton llega con el numero correcto\n"
  "      // desde el primer segundo.\n"
  "      _cancelacion.cargar(driverId: widget.driverId);\n"
  "      _refreshRoutes();\n"
  "    } catch (e) {\n      if (!mounted) return;\n      setState(() => _loading = false);\n      _showError('$e');\n      await _tick();")

io.open(f, 'w', encoding='utf-8', newline='').write(t)
print("ok")
