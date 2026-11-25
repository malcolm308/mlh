import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/estado_red.dart';

/// Estado compartido de los widgets flotantes sobre el mapa.
///
/// Cada widget tiene su propia bandera de visibilidad:
///  * el saldo solo se ve cuando el chofer está disponible (sin viaje activo);
///  * la red solo se ve cuando NO está buena (sin señal o señal débil).
///
/// El saldo y la referencia de la última recarga se guardan aquí, no en la
/// pantalla, para que cualquier otro widget (menú, panel) pueda leerlos sin
/// duplicar llamadas al backend.
class EstadoFlotanteController extends ChangeNotifier {
  static const String _claveReferencia = 'estado_flotante_referencia_recarga';

  /// Referencia inicial si nunca se ha visto una recarga en este teléfono.
  /// El arco es orientativo; en cuanto el saldo sube se toma el nuevo valor
  /// como referencia real de la última recarga.
  static const double referenciaPorDefecto = 5.0;

  double? _saldo;
  double _referencia = referenciaPorDefecto;
  bool _enViaje = false;
  EstadoRed _red = EstadoRed.buena;
  bool _actualizandoSaldo = false;

  double? get saldo => _saldo;

  /// Monto de la última recarga conocida, en CUP.
  double get referenciaRecarga => _referencia;

  bool get enViaje => _enViaje;

  EstadoRed get red => _red;

  bool get actualizandoSaldo => _actualizandoSaldo;

  /// El saldo se oculta en cuanto hay un viaje activo.
  bool get saldoVisible => !_enViaje;

  /// La red solo ocupa espacio cuando hay un problema que contar.
  bool get redVisible => _red != EstadoRed.buena;

  /// Progreso del arco, de 0 a 1. Negativo o sin datos = 0.
  double get progresoSaldo {
    final s = _saldo ?? 0.0;
    if (s <= 0) return 0.0;
    final ref = _referencia <= 0 ? 1.0 : _referencia;
    return (s / ref).clamp(0.0, 1.0);
  }

  /// Carga la referencia persistida. No bloquea el primer frame.
  Future<void> cargar() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final guardada = prefs.getDouble(_claveReferencia);
      if (guardada != null && guardada > 0) {
        _referencia = guardada;
        notifyListeners();
      }
    } catch (_) {
      // Sin prefs se usa la referencia por defecto; no es crítico.
    }
  }

  /// La pantalla lo llama en cada build. No notifica: el `setState` que cambia
  /// de viaje ya reconstruye el overlay en el mismo frame.
  void sincronizarEnViaje(bool valor) {
    _enViaje = valor;
  }

  void actualizarRed(EstadoRed valor) {
    if (_red == valor) return;
    _red = valor;
    notifyListeners();
  }

  void marcarActualizandoSaldo(bool valor) {
    if (_actualizandoSaldo == valor) return;
    _actualizandoSaldo = valor;
    notifyListeners();
  }

  /// Actualiza el saldo y detecta una recarga.
  ///
  /// Si el monto sube respecto al valor anterior, se toma como nueva
  /// referencia: el arco vuelve a llenarse. Si baja, la referencia se conserva
  /// y el arco refleja lo que queda de aquella última recarga.
  void actualizarSaldo(double? nuevo) {
    if (nuevo == null) return;

    var referencia = _referencia;
    var guardar = false;
    final anterior = _saldo;

    if (anterior == null) {
      // Primer dato: si no hay referencia guardada, se usa una razonable.
      if (referencia <= 0) referencia = nuevo > 0 ? nuevo : 1.0;
    } else if (nuevo > anterior + 0.009) {
      // Recarga (o ajuste a favor): nueva base del arco.
      referencia = nuevo > 0 ? nuevo : 1.0;
      guardar = true;
    } else if (nuevo > referencia) {
      // El saldo supera la referencia sin haber visto la recarga: se corrige.
      referencia = nuevo;
      guardar = true;
    }

    final cambio = anterior != nuevo || referencia != _referencia;
    _saldo = nuevo;
    _referencia = referencia;
    if (guardar) unawaited(_guardarReferencia());
    if (cambio) notifyListeners();
  }

  Future<void> _guardarReferencia() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_claveReferencia, _referencia);
    } catch (_) {
      // Persistir es una mejora, no un requisito para pintar el saldo.
    }
  }
}
