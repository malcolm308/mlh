import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../theme/app_theme.dart';
import 'driver_commission_history_screen.dart';
import 'driver_transfer_history_screen.dart';

/// Fondo del chofer con un SELECTOR interno de tres pestañas:
///
///  * **Fondo**: saldo y transferencia de billetera a billetera.
///  * **Transferencias**: historial de movimientos internos del Fondo.
///  * **Comisiones**: desglose de comisiones carrera por carrera.
///
/// Las transferencias de esta pantalla son INTERNAS de la plataforma (Fondo),
/// no tienen nada que ver con el método de pago "Transferencia".
class DriverFondoScreen extends StatefulWidget {
  final ApiService api;
  final String driverId;
  final String fullName;

  const DriverFondoScreen({
    super.key,
    required this.api,
    required this.driverId,
    required this.fullName,
  });

  @override
  State<DriverFondoScreen> createState() => _DriverFondoScreenState();
}

class _DriverFondoScreenState extends State<DriverFondoScreen> {
  final _phoneCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  bool _loading = true;
  bool _sending = false;
  String? _error;
  double? _fondo;
  String? _telefono;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final j = await widget.api.getDriverFondo(widget.driverId);
      if (!mounted) return;
      setState(() {
        _fondo = (j['fondo'] as num?)?.toDouble() ?? 0;
        _telefono = j['telefono']?.toString();
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _transfer() async {
    final amount = double.tryParse(_amountCtrl.text.trim());
    if (amount == null || amount <= 0) {
      _snack('Ingresa un monto válido', isError: true);
      return;
    }
    final telefono = _phoneCtrl.text.trim();
    if (telefono.isEmpty) {
      _snack('Ingresa el teléfono del chofer destino', isError: true);
      return;
    }
    setState(() => _sending = true);
    try {
      final r = await widget.api.transferFondo(
        driverId: widget.driverId,
        toDriverPhone: telefono,
        amount: amount,
      );
      await _load();
      if (!mounted) return;
      _amountCtrl.clear();
      _phoneCtrl.clear();
      final destino = r['to_driver_phone']?.toString();
      _snack(
          'Transferencia exitosa${destino == null ? '' : ' a $destino'}. '
          'Fondo restante: ${r['fondo_restante']} CUP');
    } catch (e) {
      if (!mounted) return;
      _snack('$e', isError: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _snack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      backgroundColor: isError ? AppColors.error : AppColors.tinta,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Fondo y transferencias'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Fondo'),
              Tab(text: 'Transferencias'),
              Tab(text: 'Comisiones'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _fondoTab(),
            DriverTransferHistoryView(
              api: widget.api,
              driverId: widget.driverId,
              fullName: widget.fullName,
            ),
            DriverCommissionHistoryView(
              api: widget.api,
              driverId: widget.driverId,
              fullName: widget.fullName,
            ),
          ],
        ),
      ),
    );
  }

  Widget _fondoTab() {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                // Tarjeta de saldo en el tinte oscuro de marca: mantiene el
                // contraste alto sin meter azul de la paleta vieja.
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF23262B), Color(0xFF45484F)],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Saldo disponible',
                      style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 4),
                  Text(
                    '${(_fondo ?? 0).toStringAsFixed(2)} CUP',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.person_outline,
                          color: Colors.white70, size: 16),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          '${widget.fullName}'
                          '${(_telefono ?? '').trim().isEmpty ? '' : ' · $_telefono'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12),
                        ),
                      ),
                      IconButton(
                        onPressed: _loading ? null : _load,
                        icon: const Icon(Icons.refresh,
                            color: Colors.white, size: 20),
                        tooltip: 'Actualizar',
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            const Text('Transferir a otro chofer',
                style: TextStyle(
                    color: Color(0xFF1F2937),
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text(
              'Movimiento interno de la plataforma: el dinero sale de tu Fondo '
              'y entra al Fondo del chofer destino, sin comisión.',
              style: TextStyle(fontSize: 12, color: AppColors.secundario),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Teléfono del chofer destino',
                hintText: '+53 59295207',
                helperText: 'El número se busca por sus últimos 8 dígitos.',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _amountCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Monto (CUP)',
                prefixIcon: Icon(Icons.attach_money),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Color(0xFFDC2626), fontSize: 13)),
            ],
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _sending ? null : _transfer,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                backgroundColor: AppColors.acento,
                foregroundColor: AppColors.tinta,
                shape: const StadiumBorder(),
              ),
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.swap_horiz),
              label: Text(_sending ? 'Enviando...' : 'Transferir'),
            ),
          ],
        ),
      ),
    );
  }
}
