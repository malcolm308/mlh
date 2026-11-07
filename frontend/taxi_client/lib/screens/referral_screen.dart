import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_config.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

/// Pantalla de referidos: muestra el código personal, permite compartirlo
/// y ver cuántos descuentos tiene disponibles.
class ReferralScreen extends StatefulWidget {
  final ApiService api;
  final String clientId;
  final String fullName;

  const ReferralScreen({
    super.key,
    required this.api,
    required this.clientId,
    required this.fullName,
  });

  @override
  State<ReferralScreen> createState() => _ReferralScreenState();
}

class _ReferralScreenState extends State<ReferralScreen> {
  String? _myCode;
  int _discounts = 0;
  List<Map<String, dynamic>> _referred = [];
  bool _loading = true;
  String? _error;

  final _codigoCtrl = TextEditingController();
  bool _canjeando = false;
  String? _canjeMsg;
  bool _canjeOk = false;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _codigoCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.api.getMyReferralCode(),
        widget.api.getMyDiscounts(),
        widget.api.getMyReferrals(),
      ]);
      if (!mounted) return;
      setState(() {
        _myCode = (results[0] as Map)['codigo'] as String?;
        _discounts = (results[1] as Map)['descuentos_disponibles'] as int? ?? 0;
        _referred = (results[2] as List).cast<Map<String, dynamic>>();
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

  Future<void> _shareCode() async {
    if (_myCode == null) return;
    final message =
        'Hola! Usá mi código $_myCode para registrarte en RapiTaxi y obtener un 10% de descuento en tu primer viaje. ${ApiConfig.baseUrl}';
    
    // Android share sheet
    try {
      // Fallback: copiar al portapapeles
      await Clipboard.setData(ClipboardData(text: message));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Código copiado al portapapeles. ¡Compartelo!'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: message));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Código copiado al portapapeles')),
      );
    }
  }

  Future<void> _redeem() async {
    final code = _codigoCtrl.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _canjeando = true;
      _canjeMsg = null;
    });
    try {
      final res = await widget.api.redeemReferralCode(code);
      if (!mounted) return;
      setState(() {
        _canjeando = false;
        _canjeOk = true;
        _canjeMsg = res['mensaje']?.toString() ?? 'Código aplicado';
        _codigoCtrl.clear();
      });
      await _loadAll();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _canjeando = false;
        _canjeOk = false;
        _canjeMsg = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Código de referidos')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 30),
                      const Icon(Icons.error_outline,
                          size: 52, color: AppColors.error),
                      const SizedBox(height: 12),
                      Text(_error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: AppColors.secundario, height: 1.4)),
                      const SizedBox(height: 16),
                      Center(
                        child: OutlinedButton(
                          onPressed: _loadAll,
                          child: const Text('Reintentar'),
                        ),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadAll,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      // Card con código personal
                      Card(
                        color: scheme.primaryContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            children: [
                              Text(
                                'Tu código de referido',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: scheme.onPrimaryContainer,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    _myCode ?? '—',
                                    style: TextStyle(
                                      fontSize: 32,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 4,
                                      color: scheme.onPrimaryContainer,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              FilledButton.icon(
                                onPressed: _myCode != null ? _shareCode : null,
                                icon: const Icon(Icons.share),
                                label: const Text('Compartir código'),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Descuentos disponibles
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Icon(
                                Icons.discount_rounded,
                                size: 34,
                                color: AppColors.ambar,
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Descuentos disponibles',
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: Colors.grey[600],
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '$_discounts viajes con 10% OFF',
                                      style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Canjear el código de un amigo
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '¿Te invitaron?',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Ingresa el código de tu amigo y obtén 10% OFF en tu primer viaje.',
                                style: TextStyle(fontSize: 13),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _codigoCtrl,
                                textCapitalization:
                                    TextCapitalization.characters,
                                decoration: const InputDecoration(
                                  labelText: 'Código de referido',
                                  border: OutlineInputBorder(),
                                  prefixIcon: Icon(
                                      Icons.confirmation_number_outlined),
                                ),
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: _canjeando ? null : _redeem,
                                  icon: _canjeando
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2),
                                        )
                                      : const Icon(Icons.check_circle_outline),
                                  label: Text(
                                      _canjeando ? 'Aplicando...' : 'Aplicar código'),
                                ),
                              ),
                              if (_canjeMsg != null) ...[
                                const SizedBox(height: 8),
                                Text(
                                  _canjeMsg!,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: _canjeOk
                                        ? Colors.green[700]
                                        : Colors.red[700],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Cómo funciona
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Cómo funciona',
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                              ),
                              const SizedBox(height: 8),
                              _infoRow('1', 'Compartí tu código con amigos'),
                              _infoRow('2', 'Ellos obtienen 10% OFF en su primer viaje'),
                              _infoRow('3', 'Vos ganás 1 descuento por cada referido'),
                              _infoRow('4', 'Usá tus descuentos en tus próximos viajes'),
                            ],
                          ),
                        ),
                      ),
                      if (_referred.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          'Tus referidos (${_referred.length})',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        const SizedBox(height: 8),
                        ..._referred.map((r) => Material(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              clipBehavior: Clip.antiAlias,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: AppColors.borde),
                                ),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      backgroundColor: AppColors.acentoSuave,
                                      child: Text(
                                        ((r['full_name']?.toString() ?? '?')[0])
                                            .toUpperCase(),
                                        style: const TextStyle(
                                          color: AppColors.ambar,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            r['full_name']?.toString() ??
                                                'Usuario',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              color: AppColors.tinta,
                                            ),
                                          ),
                                          Text(
                                            r['email']?.toString() ?? '',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: AppColors.secundario,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _infoRow(String num, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: const BoxDecoration(
              color: AppColors.acento,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              num,
              style: const TextStyle(
                color: AppColors.tinta,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 14)),
          ),
        ],
      ),
    );
  }
}
