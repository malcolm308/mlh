import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../theme/app_theme.dart';
import 'client_transfer_history_screen.dart';

/// Fondo del pasajero: saldo de la billetera, transferencias de billetera a
/// billetera con otro cliente y el HISTORIAL DE TRANSFERENCIAS interno.
///
/// El pasajero no tiene comisiones, por eso aquí no hay selector: solo el
/// historial de transferencias. El destino se identifica por teléfono.
class ClientFondoScreen extends StatefulWidget {
  final ApiService api;
  final String clientId;
  final String fullName;

  const ClientFondoScreen({
    super.key,
    required this.api,
    required this.clientId,
    required this.fullName,
  });

  @override
  State<ClientFondoScreen> createState() => _ClientFondoScreenState();
}

class _ClientFondoScreenState extends State<ClientFondoScreen> {
  final _phoneCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  bool _loading = true;
  bool _sending = false;
  String? _error;
  double _fondo = 0;
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
      final j = await widget.api.getClientFondo(widget.clientId);
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
      _snack('Ingresa el teléfono del pasajero destino', isError: true);
      return;
    }
    setState(() => _sending = true);
    try {
      final r = await widget.api.transferClientFondo(
        clientId: widget.clientId,
        toClientPhone: telefono,
        amount: amount,
      );
      await _load();
      if (!mounted) return;
      _amountCtrl.clear();
      _phoneCtrl.clear();
      final nombre = (r['to_client_name'] ?? '').toString();
      final destino = (r['to_client_phone'] ?? telefono).toString();
      _snack('Transferencia exitosa a $nombre ($destino). '
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
                      '${_fondo.toStringAsFixed(2)} CUP',
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
              const Text('Transferir a otro pasajero',
                  style: TextStyle(
                      color: Color(0xFF1F2937),
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text(
                'El dinero sale de tu Fondo y entra al del pasajero destino. '
                'La transferencia es inmediata y sin comisión.',
                style: TextStyle(fontSize: 12, color: AppColors.secundario),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Teléfono del pasajero destino',
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
              const SizedBox(height: 26),
              const Divider(height: 1),
              const SizedBox(height: 18),
              const Text(
                'Historial de transferencias',
                style: TextStyle(
                    color: Color(0xFF1F2937),
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              const Text(
                'Movimientos internos de la plataforma: viajes pagados con '
                'billetera o transferencia y transferencias entre pasajeros.',
                style: TextStyle(fontSize: 12, color: AppColors.secundario),
              ),
              const SizedBox(height: 14),
              ClientTransferHistoryView(
                api: widget.api,
                clientId: widget.clientId,
                fullName: widget.fullName,
                embebido: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
