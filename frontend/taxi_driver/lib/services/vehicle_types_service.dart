import 'package:flutter/foundation.dart';

import '../api_config.dart';
import 'api_client.dart';

/// Un tipo de vehiculo con lo que el administrador ha configurado.
///
/// Los campos vienen de la tabla `tariffs` de PostgreSQL: tarifa base, precio
/// por kilometro y por minuto, y cuantos pasajeros caben. No se hardcodean en
/// el movil para que anadir un tipo nuevo en el panel de administracion lo haga
/// aparecer en las apps sin tocar el codigo.
@immutable
class TipoVehiculo {
  /// Identificador tal cual esta en la base: `basico`, `comfort`...
  ///
  /// Es la clave con la que el backend busca la tarifa al calcular un viaje, asi
  /// que no se traduce ni se normaliza.
  final String tipo;

  /// Como se muestra en pantalla.
  final String etiqueta;

  final double tarifaBase;
  final double precioPorKm;
  final double precioPorMinuto;

  /// Pasajeros que caben, o `null` si la tarifa no lo define.
  final int? maxPasajeros;

  const TipoVehiculo({
    required this.tipo,
    required this.etiqueta,
    this.tarifaBase = 0,
    this.precioPorKm = 0,
    this.precioPorMinuto = 0,
    this.maxPasajeros,
  });

  /// Lee un tipo desde el JSON del backend.
  ///
  /// Tolera los dos nombres de cada campo (`tipo`/`vehicle_type`) porque el
  /// endpoint devuelve el primero pero los viajes ya existentes traen el
  /// segundo. Asi un mismo modelo sirve para ambos casos.
  factory TipoVehiculo.desdeJson(Map<String, dynamic> j) {
    final t = (j['tipo'] ?? j['vehicle_type'] ?? '').toString();
    final etiquetaCruda = (j['etiqueta'] ?? '').toString();

    return TipoVehiculo(
      tipo: t,
      // Si el backend no manda etiqueta, se capitaliza el identificador.
      etiqueta: etiquetaCruda.isNotEmpty
          ? etiquetaCruda
          : (t.isEmpty ? '' : t[0].toUpperCase() + t.substring(1)),
      tarifaBase: _aNumero(j['tarifa_base'] ?? j['base_fare']),
      precioPorKm: _aNumero(j['precio_por_km'] ?? j['price_per_km']),
      precioPorMinuto: _aNumero(j['precio_por_minuto'] ?? j['price_per_minute']),
      maxPasajeros: (j['max_pasajeros'] ?? j['max_passengers']) as int?,
    );
  }

  static double _aNumero(dynamic v) =>
      v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
}

/// Cachea los tipos de vehiculo que publica el backend.
///
/// Se cargan una vez al abrir la pantalla y se quedan: son cuatro filas de
/// configuracion que no cambian mientras el chofer esta rellenando el registro.
/// Volver a pedirlos en cada `build` seria hacer red sin motivo.
class VehicleTypesService extends ChangeNotifier {
  VehicleTypesService({
    Future<List<Map<String, dynamic>>> Function(String ruta)? httpGet,
  }) : _get = httpGet ?? _getPorDefecto;

  final Future<List<Map<String, dynamic>>> Function(String ruta) _get;

  List<TipoVehiculo> _tipos = const [];
  bool _cargando = false;
  bool _fallo = false;

  /// Tipos disponibles, en el orden que los manda el backend (por tarifa base
  /// ascendente: primero los baratos).
  List<TipoVehiculo> get tipos => _tipos;

  /// `true` mientras se esta pidiendo la lista.
  bool get cargando => _cargando;

  /// `true` si la ultima consulta fallo.
  ///
  /// La app no bloquea el registro por esto: si no hay red se usa la lista de
  /// respaldo y el chofer puede enviar igualmente.
  bool get fallo => _fallo;

  /// Si el backend no responde, se ofrecen estos.
  ///
  /// Es un respaldo para no dejar el formulario vacio sin conexion, no una
  /// fuente de verdad: los precios SIEMPRE los pone el backend. Si un dia se
  /// anade un tipo y la app va sin red, no se podra elegir; es el trade-off de
  /// poder registrar sin internet.
  static const List<TipoVehiculo> respaldo = [
    TipoVehiculo(tipo: 'moto', etiqueta: 'Moto', maxPasajeros: 1),
    TipoVehiculo(tipo: 'triciclo', etiqueta: 'Triciclo', maxPasajeros: 6),
    TipoVehiculo(tipo: 'basico', etiqueta: 'Básico', maxPasajeros: 4),
    TipoVehiculo(tipo: 'confort', etiqueta: 'Confort', maxPasajeros: 4),
  ];

  /// Devuelve la etiqueta de un tipo, o el propio identificador si no esta en la
  /// lista.
  ///
  /// Replace de los `switch` que estaban escritos a mano en cada pantalla: si el
  /// administrador renombra un tipo, aqui sale el nombre bueno sin tocar nada.
  String etiquetaDe(String? tipo) {
    final t = (tipo ?? '').trim();
    if (t.isEmpty) return 'Vehículo';

    for (final v in _tipos) {
      if (v.tipo == t) return v.etiqueta;
    }
    for (final v in respaldo) {
      if (v.tipo == t) return v.etiqueta;
    }

    // Desconocido: se capitaliza para que no salga en minuscula en pantalla.
    return t[0].toUpperCase() + t.substring(1);
  }

  /// `true` si el tipo existe en la configuracion.
  bool esValido(String? tipo) {
    final t = (tipo ?? '').trim();
    if (t.isEmpty) return false;
    if (_tipos.any((v) => v.tipo == t)) return true;
    return respaldo.any((v) => v.tipo == t);
  }

  /// Carga los tipos desde el backend.
  ///
  /// No vuelve a pedir la lista si ya se trajo: se cachea para el resto de la
  /// sesion de la pantalla.
  Future<void> cargar({bool forzar = false}) async {
    if (_cargando) return;
    if (_tipos.isNotEmpty && !forzar) return;

    _cargando = true;
    _fallo = false;
    notifyListeners();

    try {
      final lista = await _get('/vehiculos/tipos');
      _tipos = lista.map(TipoVehiculo.desdeJson).toList();
      // Si el backend devuelve una lista vacia se usa el respaldo: es mejor
      // ofrecer cuatro tipos sin precio que no ofrecer ninguno.
      if (_tipos.isEmpty) _tipos = respaldo;
    } catch (_) {
      _fallo = true;
      _tipos = respaldo;
    }

    _cargando = false;
    notifyListeners();
  }

  static Future<List<Map<String, dynamic>>> _getPorDefecto(String ruta) async {
    final j = await ApiClient.get('${ApiConfig.baseUrl}$ruta');
    if (j is! List) return const [];
    return j.cast<Map<String, dynamic>>();
  }
}