import 'package:intl/intl.dart';

/// Hora oficial de Cuba.
///
/// Cuba adelanto el reloj y en 2026 se mantiene en UTC-4 todo el ano. El
/// tzdata de Android puede seguir aplicando UTC-5 en invierno para
/// `America/Havana`, por eso NO se puede usar `toLocal()`: el telefono
/// mostraba una hora menos que el panel. Se aplica el mismo desfase fijo que
/// el backend y el panel (`CUBA_UTC_OFFSET = -4`).
const int cubaUtcOffsetHoras = -4;

/// Convierte un ISO 8601 en UTC (con o sin `Z`) a la hora oficial de Cuba.
DateTime horaCubaDesdeIso(String iso) => DateTime.parse(iso)
    .toUtc()
    .add(const Duration(hours: cubaUtcOffsetHoras));

/// Formatea un ISO 8601 en hora de Cuba: `15/11/2026 07:17 AM`.
String formatearHoraCuba(String iso,
        {String patron = 'dd/MM/yyyy hh:mm a'}) =>
    DateFormat(patron).format(horaCubaDesdeIso(iso));
