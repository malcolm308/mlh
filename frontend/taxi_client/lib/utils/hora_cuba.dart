import 'package:intl/intl.dart';

/// Hora oficial de Cuba.
///
/// Cuba adelanto el reloj y en 2026 se mantiene en UTC-4 todo el ano. El
/// tzdata de Android puede seguir aplicando UTC-5 en invierno para
/// `America/Havana`, por eso NO se puede usar `toLocal()`: el telefono
/// mostraba una hora menos que el panel. Se aplica el mismo desfase fijo que
/// el backend y el panel (`CUBA_UTC_OFFSET = -4`).
const int cubaUtcOffsetHoras = -4;

/// Convierte un ISO 8601 en UTC a la hora oficial de Cuba.
///
/// Acepta fechas con zona (`...Z`, `...+00:00`) y tambien sin zona: Mongo y el
/// backend guardan UTC naive, asi que un ISO sin sufijo se interpreta como UTC
/// y nunca como hora local del telefono.
DateTime horaCubaDesdeIso(String iso) {
  final texto = iso.trim();
  var dt = DateTime.parse(texto);
  final tieneZona =
      RegExp(r'(Z|[+-]\d{2}:?\d{2})$', caseSensitive: false).hasMatch(texto);
  if (!tieneZona) {
    // Componentes tal cual vienen: son UTC naive.
    dt = DateTime.utc(dt.year, dt.month, dt.day, dt.hour, dt.minute,
        dt.second, dt.millisecond, dt.microsecond);
  }
  return dt.toUtc().add(const Duration(hours: cubaUtcOffsetHoras));
}

/// Formatea un ISO 8601 en hora de Cuba: `15/11/2026 07:17 AM`.
String formatearHoraCuba(String iso,
        {String patron = 'dd/MM/yyyy hh:mm a'}) =>
    DateFormat(patron).format(horaCubaDesdeIso(iso));
