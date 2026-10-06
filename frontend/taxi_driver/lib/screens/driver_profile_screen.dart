import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/vehicle_types_service.dart';
import '../services/api_service.dart';

/// Perfil completo del conductor (opción del menú hamburguesa).
class DriverProfileScreen extends StatefulWidget {
  final ApiService api;
  final String driverId;
  final DriverProfile initialProfile;

  const DriverProfileScreen({
    super.key,
    required this.api,
    required this.driverId,
    required this.initialProfile,
  });

  @override
  State<DriverProfileScreen> createState() => _DriverProfileScreenState();
}

class _DriverProfileScreenState extends State<DriverProfileScreen> {
  late DriverProfile _profile;
  DriverEarnings? _earnings;
  int _dailyTrips = 0;
  bool _loading = false;
  String? _error;

  /// Tipos de vehiculo del backend, para las etiquetas.
  final VehicleTypesService _tiposVehiculo = VehicleTypesService();

  @override
  void initState() {
    super.initState();
    _profile = widget.initialProfile;
    // Las etiquetas de tipo salen de la configuracion del backend; si no
    // responde, el servicio deja la lista de respaldo y el perfil se ve igual.
    _tiposVehiculo.cargar();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await widget.api.getChofer(widget.driverId);
      final e = await widget.api.getEarnings(widget.driverId);
      final day = await widget.api.getDailyTripCount(widget.driverId);
      if (!mounted) return;
      setState(() {
        _profile = p;
        _earnings = e;
        _dailyTrips = (day['daily_trips'] ?? 0) as int;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _profile;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Perfil del conductor'),
        actions: [
          IconButton(
            tooltip: 'Actualizar',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: CircleAvatar(
              radius: 42,
              backgroundColor: const Color(0xFF007AFF),
              child: Text(
                p.fullName.isNotEmpty ? p.fullName[0].toUpperCase() : 'C',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            p.fullName,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF333333)),
          ),
          const SizedBox(height: 4),
          Text(p.email, textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF888888))),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.star, color: Color(0xFFF5A623), size: 18),
              const SizedBox(width: 4),
              Text(p.raiting.toStringAsFixed(1),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 20),
          if (_error != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer)),
              ),
            ),
          _section('Vehículo', [
            _info(Icons.directions_car, 'Modelo',
                p.vehicleModel.isNotEmpty ? p.vehicleModel : 'No registrado'),
            _info(Icons.category_outlined, 'Tipo',
                _type(p.vehicleType)),
            // La licencia ya no se pide en el registro: se valida con el
            // documento. Aqui solo se muestra si el chofer ya la tenia puesta.
            if ((p.licenseNumber ?? '').isNotEmpty)
              _info(Icons.badge_outlined, 'Licencia', p.licenseNumber!),
            _info(Icons.group_outlined, 'Pasajeros',
                '${p.maxPassengers}'),
          ]),
          _section('Datos de contacto', [
            _info(Icons.phone_outlined, 'Teléfono',
                p.telefono.isNotEmpty ? p.telefono : 'No registrado'),
            _info(Icons.email_outlined, 'Email', p.email.isEmpty ? '—' : p.email),
          ]),
          _section('Estadísticas', [
            _info(Icons.account_balance_wallet_outlined, 'Fondo',
                '${p.fondo.toStringAsFixed(2)} CUP'),
            if (_earnings != null) ...[
              _info(Icons.local_taxi_outlined, 'Viajes totales',
                  '${_earnings!.totalTrips}'),
              _info(Icons.paid_outlined, 'Ganancia total',
                  '${_earnings!.totalEarnings.toStringAsFixed(2)} CUP'),
              _info(Icons.route_outlined, 'Distancia total',
                  '${_earnings!.totalDistanceKm.toStringAsFixed(1)} km'),
            ],
            _info(Icons.today_outlined, 'Viajes de hoy', '$_dailyTrips'),
          ]),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  /// Etiqueta del tipo de vehiculo, desde la configuracion del backend.
  ///
  /// Antes era un `switch` con los tipos escritos a mano; si el
  /// administrador anadia uno nuevo en `tariffs`, aqui no saldria.
  String _type(String? type) => _tiposVehiculo.etiquetaDe(type);

  Widget _section(String title, List<Widget> rows) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    color: Color(0xFF007AFF),
                    fontWeight: FontWeight.bold,
                    fontSize: 13)),
            const Divider(height: 18),
            ...rows,
          ],
        ),
      ),
    );
  }

  Widget _info(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: const Color(0xFF888888)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label,
                style: const TextStyle(color: Color(0xFF888888))),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(value,
                textAlign: TextAlign.right,
                style: const TextStyle(
                    color: Color(0xFF333333), fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}