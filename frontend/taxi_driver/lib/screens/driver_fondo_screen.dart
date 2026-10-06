import 'package:flutter/material.dart';

import '../services/api_service.dart';

/// Muestra el Fondo del chofer y permite transferir a otro conductor.
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
  final _emailCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  bool _loading = true;
  bool _sending = false;
  String? _error;
  double? _fondo;
  String? _email;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final j = await widget.api.getDriverFondo(widget.driverId);
      if (!mounted) return;
      setState(() {
        _fondo = (j['fondo'] as num?)?.toDouble() ?? 0;
        _email = j['email']?.toString();
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
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) {
      _snack('Ingresa el email del chofer destino', isError: true);
      return;
    }
    setState(() => _sending = true);
    try {
      final r = await widget.api.transferFondo(
        driverId: widget.driverId,
        toDriverEmail: email,
        amount: amount,
      );
      await _load();
      if (!mounted) return;
      _amountCtrl.clear();
      _snack(
          'Transferencia exitosa. Fondo restante: ${r['fondo_restante']} CUP');
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
      backgroundColor:
          isError ? const Color(0xFFDC2626) : const Color(0xFF007AFF),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Fondo')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF007AFF), Color(0xFF4DABFF)],
                  ),
                  borderRadius: BorderRadius.circular(18),
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
                            '${widget.fullName} · ${_email ?? widget.driverId}',
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
              const SizedBox(height: 12),
              TextField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Email del chofer destino',
                  prefixIcon: Icon(Icons.email_outlined),
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
                  minimumSize: const Size.fromHeight(48),
                  backgroundColor: const Color(0xFF111827),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.swap_horiz),
                label:
                    Text(_sending ? 'Enviando...' : 'Transferir'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}