import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Convierte un punto WKT "POINT(lng lat)" que devuelve PostGIS a LatLng.
LatLng? parseWktPoint(String? wkt) {
  if (wkt == null) return null;
  final m = RegExp(r'POINT\(\s*([-\d.]+)\s+([-\d.]+)\s*\)').firstMatch(wkt);
  if (m == null) return null;
  final lng = double.tryParse(m.group(1) ?? '');
  final lat = double.tryParse(m.group(2) ?? '');
  if (lat == null || lng == null) return null;
  return LatLng(lat, lng);
}

String? _str(Map<String, dynamic> j, List<String> keys) {
  for (final k in keys) {
    final v = j[k];
    if (v != null && v.toString().isNotEmpty) return v.toString();
  }
  return null;
}

/// Perfil del chofer tal como lo devuelve GET /chofer/{id}.
class DriverProfile {
  final String id;
  final String nombre;
  final String apellidos;
  final String email;
  final String telefono;
  final double fondo;
  final double raiting;
  final String? vehicleType;
  final String vehicleModel;
  final String? licenseNumber;
  final int maxPassengers;
  final bool documentsVerified;

  DriverProfile({
    required this.id,
    required this.nombre,
    required this.apellidos,
    required this.email,
    required this.telefono,
    required this.fondo,
    required this.raiting,
    this.vehicleType,
    this.vehicleModel = '',
    this.licenseNumber,
    this.maxPassengers = 4,
    this.documentsVerified = true,
  });

factory DriverProfile.fromJson(Map<String, dynamic> j) {
    final nombre =
        _str(j, ['Nombre', 'nombre', 'name']) ?? _nested(j, 'profile', 'name') ?? '';
    final apellidos =
        _str(j, ['Apellidos', 'apellidos']) ?? '';
    final vehicle = j['vehicle'];
    // El tipo de vehiculo llega en varias claves segun por donde se creo la
    // cuenta. `vehicle.servicio` es la que escribe el registro con fotos, y antes
    // no se leia: el tipo llegaba null a la app y el backend, al no recibeirlo,
    // devolvia TODAS las ofertas. Un basico veia las de moto.
    final vtype = vehicle is Map
        ? (vehicle['servicio'] ??
            vehicle['type'] ??
            vehicle['tipo'] ??
            j['vehicle_type'] ??
            j['type_vehicle'])
        : (j['vehicle_type'] ?? j['type_vehicle']);
    return DriverProfile(
      id: (j['_id'] ?? j['id'] ?? '').toString(),
      nombre: nombre,
      apellidos: apellidos,
      email: _str(j, ['email']) ?? '',
      telefono: _str(j, ['numero_de_telefono', 'phone']) ?? '',
      fondo: (j['Fondo'] ?? j['fondo'] ?? 0).toDouble(),
      raiting: (j['raiting'] ?? j['rating'] ?? j['Rating'] ?? 5.0).toDouble(),
      vehicleType: _normalizarTipo(vtype),
      vehicleModel: _vehicleModelOf(j),
      licenseNumber: _str(j, ['license_number', 'licenseNumber']),
      maxPassengers: (j['max_passengers'] ?? 4).toInt(),
      documentsVerified: (j['documents_verified'] ?? true) == true,
    );
  }

  /// Tipo de vehiculo del chofer, ya normalizado.
  ///
  /// Si el chofer no tiene tipo declarado devuelve null a proposito: no se
  /// inventa un 'basico'. Con null no llegan ofertas, que es lo correcto; con un
  /// tipo inventado llegan ofertas de un vehiculo que no es el suyo.
  String? get tipoVehiculo => _normalizarTipo(vehicleType);

  /// Sin tipo declarado no se puede trabajar con seguridad.
  bool get sinTipoVehiculo => tipoVehiculo == null;

  String get fullName => '$nombre $apellidos'.trim();
}

/// Normaliza un tipo de vehiculo: quita tildes, espacios y mayusculas.
///
/// Hace falta porque la base guarda 'básico' con tilde y la app escribe
/// 'basico'. Comparar sin normalizar haria que un chofer basico no viera sus
/// propias ofertas, que es el mismo fallo pero del lado opuesto, y igual de malo.
String? _normalizarTipo(Object? valor) {
  if (valor == null) return null;
  var texto = valor.toString().trim();
  if (texto.isEmpty) return null;
  // 'básico' -> 'basico'. Se recorre el mapa en vez de usar una libreria de
  // acentos porque son nueve letras y el proyecto no tiene esa dependencia.
  const acentos = {
    'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u',
    'Á': 'a', 'É': 'e', 'Í': 'i', 'Ó': 'o', 'Ú': 'u', 'ü': 'u', 'Ü': 'u',
    'ñ': 'n',
  };
  texto = texto.split('').map((c) => acentos[c] ?? c).join();
  return texto.replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
}

/// Extrae "Marca model" del dict `vehicle` (ej. "Lada 2105").
String _vehicleModelOf(Map<String, dynamic> j) {
  final v = j['vehicle'];
  if (v is Map) {
    final marca = v['Marca']?.toString() ?? '';
    final model = v['model']?.toString() ?? '';
    final s = '$marca $model'.trim();
    if (s.isNotEmpty) return s;
  }
  return _str(j, ['vehicle_model', 'vehicleModel']) ?? '';
}

String? _nested(Map<String, dynamic> j, String key, String sub) {
  final v = j[key];
  if (v is Map) return v[sub]?.toString();
  return null;
}

/// Viaje sin asignar (oferta) o viaje activo.
class TripOffer {
  final String tripId;
  final String? clientId;
  final LatLng? pickup;
  final LatLng? dropoff;
  final double? precioEstimado;
  final String vehicleType;
  final int numPasajes;
  final bool equipaje;
  final bool mascota;
  final double? distanciaChoferKm;
  final String? clientName;
  final String? clientPhone;
final String status;
  final String? requestedAt;

  /// Cuando el chófer marco "He llegado" al punto de recogida.
  ///
  /// Es el arranque del reloj de espera: hasta que el pasajero no pulse
  /// "Iniciar viaje", este tiempo es del pasajero. Los primeros
  /// `tiempo_espera_cortesia_minutos` no se cobran y el resto se le paga al
  /// chófer como si fuera tiempo de trayecto.
  final String? horaLlegada;

  /// Segundos que el pasajero estuvo esperando, si el viaje ya empezo.
  ///
  /// Lo calcula el backend. Aqui no se cuenta con el reloj del telefono porque
  /// la hora de llegada y la de inicio las pone el servidor y son las que se
  /// cobran.
  final int? esperaSegs;

  /// De esos segundos, los que se cobran al pasajero por pasar de la cortesia.
  final int? excedenteEsperaSegs;

  /// Minutos de espera que regala la plataforma, para poder escribir
  /// "de los N min que lleva esperando, 2 son gratis".
  final int? cortesiaMin;
  final String? requestAddress;
  final String? dropoffAddress;
  final double? totalFare;
  final double? distanceKm;
  final String currency;
  final int? offerExpiresInSecs;

  /// Chofer adjudicado al viaje, si lo hay.
  ///
  /// Lo devuelve el backend en `driver_id` de `getTrip`. Se usa para saber si
  /// un viaje que desaparece del sondeo lo tomó otro chofer o lo ganó este:
  /// si el `driver_id` es el nuestro, no es un viaje perdido.
  final String? tripDriverId;

  TripOffer({
    required this.tripId,
    this.clientId,
    this.pickup,
    this.dropoff,
    this.precioEstimado,
    this.vehicleType = 'basico',
    this.numPasajes = 1,
    this.equipaje = false,
    this.mascota = false,
    this.distanciaChoferKm,
    this.clientName,
    this.clientPhone,
    this.status = 'requested',
    this.requestedAt,
    this.horaLlegada,
    this.esperaSegs,
    this.excedenteEsperaSegs,
    this.cortesiaMin,
    this.requestAddress,
    this.dropoffAddress,
    this.totalFare,
    this.distanceKm,
this.currency = 'CUP',
    this.offerExpiresInSecs,
    this.tripDriverId,
  });

  /// Segundos de espera que se cobran al pasajero.
  ///
  /// Lo calcula el backend al cerrar el viaje y lo guarda en el viaje. Mientras
  /// el viaje sigue en marcha se usa este getter, que aplica la misma regla:
  /// gratis lo que quepa en la cortesía, pagado el resto. Se duplica aqui a
  /// proposito, para que el contador que ve el chófer vaya cambiando solo sin
  /// tener que pegarle al servidor cada segundo.
  int get excedenteEsperaVivo {
    if (excedenteEsperaSegs != null) return excedenteEsperaSegs!;
    final espera = esperaSegs ?? 0;
    if (espera <= 0) return 0;
    final gratis = (cortesiaMin ?? 4) * 60;
    final exceso = espera - gratis;
    return exceso > 0 ? exceso : 0;
  }

  /// `true` cuando el pasajero ya está esperando y todavía no ha subido.
  bool get esperandoPasajero =>
      status == 'driver_arrived' && horaLlegada != null;

  /// Espera formateada para pintar, por ejemplo "8 min" o "1:05".
  String get esperaLegible {
    final total = esperaSegs ?? 0;
    if (total <= 0) return '0 min';
    final minutos = total ~/ 60;
    final segundos = total % 60;
    if (minutos == 0) return '$segundos s';
    if (segundos == 0) return '$minutos min';
    return '$minutos:${segundos.toString().padLeft(2, '0')} min';
  }

  factory TripOffer.fromJson(Map<String, dynamic> j) => TripOffer(
        tripId: (j['trip_id'] ?? '').toString(),
        clientId: j['client_id']?.toString(),
        pickup: parseWktPoint(j['request_location']?.toString() ??
            j['pickup_location']?.toString()),
        dropoff: parseWktPoint(j['dropoff_location']?.toString()),
        precioEstimado: (j['precio_estimado'] ?? j['precioEstimado'])?.toDouble(),
        vehicleType: (j['vehicle_type'] ?? 'basico').toString(),
        numPasajes: (j['num_pasajes'] ?? 1).toInt(),
        equipaje: (j['equipaje'] ?? false) == true,
        mascota: (j['mascota'] ?? false) == true,
        distanciaChoferKm:
            (j['distance_from_driver_km'] ?? j['distance_from_driver_km'])?.toDouble(),
        clientName: j['client_name']?.toString(),
        clientPhone: j['client_phone']?.toString(),
        status: (j['status'] ?? 'requested').toString(),
        requestedAt: j['requested_at']?.toString(),
        horaLlegada: j['hora_llegada']?.toString(),
        esperaSegs: (j['espera_segundos'])?.toInt(),
        excedenteEsperaSegs: (j['excedente_espera_segundos'])?.toInt(),
        cortesiaMin: (j['tiempo_espera_cortesia_minutos'])?.toInt(),
        requestAddress: j['request_address']?.toString(),
        dropoffAddress: j['dropoff_address']?.toString(),
        totalFare: (j['total_fare'] ?? j['total_fare'])?.toDouble(),
        distanceKm: (j['distance_km'] ?? j['distance_km'])?.toDouble(),
currency: (j['currency'] ?? 'CUP').toString(),
        offerExpiresInSecs: (j['offer_expires_in_secs'])?.toInt(),
        tripDriverId: j['driver_id']?.toString(),
      );
}

/// Resultado de completar un viaje.
class CompletedTrip {
  final String tripId;
  final double distanceKm;
  final int durationSecs;
  final double baseFare;
  final double distanceFare;
  final double timeFare;
  final double tip;
  final double totalFare;
  final double commission;

  /// Tasa de comision aplicada: 0.15 normal, 0.10 en el 3er viaje del dia.
  final double commissionRate;

  /// Etiqueta lista para pintar, por ejemplo "15%" o "10%".
  final String commissionLabel;

  /// `true` cuando este viaje uso el descuento del 3er viaje del dia.
  final bool commissionDiscount;

  final String currency;
  final String? appliedRule;

  /// Coeficiente por distancia que se aplicó a este viaje.
  ///
  /// El kilometraje se cobra multiplicado por este valor, así que por debajo
  /// del tramo corto el chofer percibe menos de lo que daría `price_per_km` a
  /// pelo. Se guarda y se muestra para que la cifra del recibo no aparezca sin
  /// explicación.
  final double? coeficienteAplicado;

  /// Lo que el kilometraje habría costado sin ese coeficiente.
  final double? distanceFareSinCoeficiente;

  /// Segundos que el pasajero estuvo esperando, y de ellos los que se pagaron.
  ///
  /// La espera de cortesía es el único momento del viaje en el que el chofer
  /// está parado y cobrando. Mostrarlo es la mitad del trabajo: sin esto, el
  /// chofer no tiene forma de saber si le ha tocado esperar de más.
  final int? esperaSegs;
  final int? excedenteEsperaSegs;

  CompletedTrip({
    required this.tripId,
    required this.distanceKm,
    required this.durationSecs,
    required this.baseFare,
    required this.distanceFare,
    required this.timeFare,
    required this.tip,
    required this.totalFare,
    required this.commission,
    required this.currency,
    this.commissionRate = 0.15,
    this.commissionLabel = '15%',
    this.commissionDiscount = false,
    this.appliedRule,
    this.coeficienteAplicado,
    this.distanceFareSinCoeficiente,
    this.esperaSegs,
    this.excedenteEsperaSegs,
  });

  factory CompletedTrip.fromJson(Map<String, dynamic> j) => CompletedTrip(
        tripId: (j['trip_id'] ?? '').toString(),
        distanceKm: (j['distance_km'] ?? 0).toDouble(),
        durationSecs: (j['duration_secs'] ?? 0).toInt(),
        baseFare: (j['base_fare'] ?? 0).toDouble(),
        distanceFare: (j['distance_fare'] ?? 0).toDouble(),
        timeFare: (j['time_fare'] ?? 0).toDouble(),
        tip: (j['tip'] ?? 0).toDouble(),
        totalFare: (j['total_fare'] ?? 0).toDouble(),
        commission: (j['commission'] ?? 0).toDouble(),
        commissionRate: (j['commission_rate'] ?? 0.15).toDouble(),
        commissionLabel: (j['commission_label'] ?? '15%').toString(),
        commissionDiscount: (j['commission_discount'] ?? false) == true,
        currency: (j['currency'] ?? 'CUP').toString(),
        appliedRule: j['applied_rule']?.toString(),
        coeficienteAplicado: (j['coeficiente_aplicado'])?.toDouble(),
        distanceFareSinCoeficiente:
            (j['distance_fare_sin_coeficiente'])?.toDouble(),
        esperaSegs: (j['espera_segundos'] ?? j['espera_secs'])?.toInt(),
        excedenteEsperaSegs:
            (j['excedente_espera_segundos'] ?? j['excedente_espera_secs'])?.toInt(),
      );
}

/// Punto de la ruta trazada por Traccar: /trips/{id}/route.
class RoutePoint {
  final double lat;
  final double lng;
  final String? time;

  RoutePoint({required this.lat, required this.lng, this.time});

  factory RoutePoint.fromJson(Map<String, dynamic> j) => RoutePoint(
        lat: (j['lat'] ?? 0).toDouble(),
        lng: (j['lng'] ?? 0).toDouble(),
        time: j['time']?.toString(),
      );

  LatLng get point => LatLng(lat, lng);
}

/// Ganancias del conductor: /drivers/{id}/earnings.
class DriverEarnings {
  final int totalTrips;
  final double totalEarnings;
  final double avgFare;
  final double totalDistanceKm;
  final double totalDurationSecs;

  DriverEarnings({
    required this.totalTrips,
    required this.totalEarnings,
    required this.avgFare,
    required this.totalDistanceKm,
    required this.totalDurationSecs,
  });

  factory DriverEarnings.fromJson(Map<String, dynamic> j) => DriverEarnings(
        totalTrips: (j['total_trips'] ?? 0).toInt(),
        totalEarnings: (j['total_earnings'] ?? 0).toDouble(),
        avgFare: (j['avg_fare'] ?? 0).toDouble(),
        totalDistanceKm: (j['total_distance_km'] ?? 0).toDouble(),
totalDurationSecs: (j['total_duration_secs'] ?? 0).toDouble(),
      );
}
