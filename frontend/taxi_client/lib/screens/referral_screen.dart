import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';

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

  @override
  void initState() {
    super.initState();
    _loadAll();
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
        'Hola! Usá mi código ${_myCode} para registrarte en RapiTaxi y obtener un 10% de descuento en tu primer viaje. ${ApiConfig.baseUrl}';
    
    // Android share sheet
    try {
      final shareUrl = Uri(
        scheme: 'sms',
        path: '',
        queryParameters: {'body': message},
      );
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
      if (!mounted) return;
      await Clipboard.setData(ClipboardData(text: message));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Código copiado al portapapeles')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Invitar amigos')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline, size: 48, color: Colors.red),
                      const SizedBox(height: 16),
                      Text(_error!),
                      const SizedBox(height: 16),
                      FilledButton(onPressed: _loadAll, child: const Text('Reintentar')),
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
                                Icons.discount,
                                size: 40,
                                color: scheme.primary,
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
                        ..._referred.map((r) => Card(
                              child: ListTile(
                                leading: CircleAvatar(
                                  child: Text(
                                    (r['full_name']?.toString() ?? '?')[0].toUpperCase(),
                                  ),
                                ),
                                title: Text(r['full_name']?.toString() ?? 'Usuario'),
                                subtitle: Text(r['email']?.toString() ?? ''),
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
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              num,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
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
