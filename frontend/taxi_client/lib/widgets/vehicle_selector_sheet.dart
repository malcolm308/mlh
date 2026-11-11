import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'ui/glass_sheet.dart';
import 'ui/pill_button.dart';

/// Modelo de vehículo con su precio y datos
class VehicleOption {
  final String type;
  final double price;

  /// Precio cuando se paga por TRANSFERENCIA externa: ya incluye el recargo
  /// (10% por defecto), calculado por el backend.
  final double priceTransferencia;

  final String iconPath;
  final String displayName;

  VehicleOption({
    required this.type,
    required this.price,
    required this.iconPath,
    required this.displayName,
    double? priceTransferencia,
  }) : priceTransferencia = priceTransferencia ?? price * 1.10;

  /// Precio final segun el metodo de pago elegido.
  double priceFor(String metodo) =>
      metodo == 'Transferencia' ? priceTransferencia : price;

  factory VehicleOption.fromApi(Map<String, dynamic> json) {
    final type = json['vehicle_type'] as String;
    String iconPath;
    String displayName;
    
    switch (type) {
      case 'moto':
        iconPath = 'assets/icons/moto_scooter.png';
        displayName = 'Moto';
        break;
      case 'triciclo':
        iconPath = 'assets/icons/triciclo_rickshaw.png';
        displayName = 'Triciclo';
        break;
      case 'basico':
        iconPath = 'assets/icons/basico_lada.png';
        displayName = 'Básico';
        break;
      case 'confort':
        iconPath = 'assets/icons/confort_suv.png';
        displayName = 'Confort';
        break;
      default:
        iconPath = 'assets/icons/basico_lada.png';
        displayName = type;
    }
    
    final precio = (json['price'] as num).toDouble();
    return VehicleOption(
      type: type,
      price: precio,
      priceTransferencia: (json['price_transferencia'] as num?)?.toDouble() ??
          precio * 1.10,
      iconPath: iconPath,
      displayName: displayName,
    );
  }
}

/// BottomSheet de selección de vehículo (Paso 2 del flujo).
///
/// Recibe `selectedIndex` y `onVehicleSelected(int)`. La reconstrucción se
/// controla desde fuera con `StatefulBuilder` para que al tocar una tarjeta
/// solo cambie el resaltado y el precio, sin cerrar/reabrir el sheet.
class VehicleSelectorSheet extends StatelessWidget {
  final String pickupAddress;
  final String dropoffAddress;
  final double distanceKm;

  /// Duracion del trayecto en minutos (la de OSRM, no la llegada del chofer).
  final double durationMin;
  final String etaText;
  final String paymentMethod;

  /// Saldo actual de la billetera del pasajero (Fondo). Se muestra en el
  /// selector y bloquea el viaje si no alcanza.
  final double walletBalance;

  /// Recargo configurado para pago por transferencia (0.10 = 10%).
  final double transferSurchargeRate;

  /// Cambia el metodo de pago elegido (Efectivo / Billetera / Transferencia).
  final ValueChanged<String> onPaymentMethodChanged;

  final List<VehicleOption> vehicles;
  final int selectedIndex;
  final int numPasajes;
  final bool equipaje;
  final bool mascota;
  final ValueChanged<int> onPasajerosChanged;
  final ValueChanged<bool> onEquipajeChanged;
  final ValueChanged<bool> onMascotaChanged;
  final ValueChanged<int> onVehicleSelected;
  final VoidCallback onConfirmTrip;
  final VoidCallback? onBack;
  final bool isLoading;

  const VehicleSelectorSheet({
    super.key,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.distanceKm,
    this.durationMin = 0,
    required this.etaText,
    required this.paymentMethod,
    required this.onPaymentMethodChanged,
    this.walletBalance = 0,
    this.transferSurchargeRate = 0.10,
    required this.vehicles,
    required this.selectedIndex,
    required this.numPasajes,
    required this.equipaje,
    required this.mascota,
    required this.onPasajerosChanged,
    required this.onEquipajeChanged,
    required this.onMascotaChanged,
    required this.onVehicleSelected,
    required this.onConfirmTrip,
    this.onBack,
    this.isLoading = false,
  });

  VehicleOption get _selected => vehicles[selectedIndex];

  /// La billetera solo confirma si el saldo cubre el precio del viaje. Con
  /// efectivo o transferencia externa no hay nada que validar aqui.
  bool get _puedeConfirmar =>
      paymentMethod != 'Billetera' ||
      walletBalance + 0.009 >= _selected.priceFor('Billetera');

  @override
  Widget build(BuildContext context) {
    return GlassSheet(
      showHandle: false,
      padding: EdgeInsets.zero,
      // El selector de pago agrega alto: la hoja se puede desplazar en
      // pantallas pequenas sin recortar el boton de confirmar.
      child: SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
          // Cabecera: botón "Cambiar ruta" + indicador de arrastre
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (onBack != null)
                  InkWell(
                    onTap: onBack,
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.arrow_back, size: 18),
                          const SizedBox(width: 4),
                          Text(
                            'Cambiar ruta',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey[700],
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  const SizedBox(width: 80),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD2D6DB),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 80),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _AddressRow(
                  icon: Icons.circle,
                  iconColor: Colors.green,
                  address: pickupAddress,
                  label: 'Recogida',
                ),
                const SizedBox(height: 8),
                _AddressRow(
                  icon: Icons.flag,
                  iconColor: const Color(0xFFB91C1C),
                  address: dropoffAddress,
                  label: 'Destino',
                ),
                // Distancia y tiempo REALES del trazado (OSRM). Si la ruta
                // aun no tiene datos no se muestra nada en vez de un "0.0 km"
                // que parezca un fallo.
                if (distanceKm > 0) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.route_rounded,
                          size: 15, color: AppColors.secundario),
                      const SizedBox(width: 6),
                      Text(
                        '${distanceKm.toStringAsFixed(1)} km · '
                        '${durationMin.ceil()} min',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.secundario,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 110,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: vehicles.length,
              itemBuilder: (context, index) {
                final isSelected = index == selectedIndex;
                return _VehicleCard(
                  vehicle: vehicles[index],
                  isSelected: isSelected,
                  onTap: () => onVehicleSelected(index),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          // Pasajeros / equipaje / mascota: se envian con la solicitud y el
          // chofer los ve antes de aceptar.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.people_alt_rounded,
                        size: 18, color: AppColors.secundario),
                    const SizedBox(width: 8),
                    const Text(
                      'Pasajeros',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.tinta,
                      ),
                    ),
                    const Spacer(),
                    _PassengerCounter(
                      value: numPasajes,
                      onChanged: onPasajerosChanged,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _ExtraToggle(
                        icon: Icons.luggage_rounded,
                        label: 'Equipaje',
                        value: equipaje,
                        onChanged: onEquipajeChanged,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _ExtraToggle(
                        icon: Icons.pets_rounded,
                        label: 'Mascota',
                        value: mascota,
                        onChanged: onMascotaChanged,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _PaymentSelector(
              value: paymentMethod,
              walletBalance: walletBalance,
              transferSurchargeRate: transferSurchargeRate,
              precio: _selected.priceFor('Efectivo'),
              precioTransferencia: _selected.priceTransferencia,
              onChanged: onPaymentMethodChanged,
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _DetailColumn(
                  icon: Icons.attach_money,
                  label: 'Precio',
                  value:
                      '${_selected.priceFor(paymentMethod).toStringAsFixed(0)} CUP',
                  valueColor: AppColors.ambar,
                ),
                _DetailColumn(
                  icon: Icons.payment,
                  label: 'Pago',
                  value: paymentMethod,
                ),
                _DetailColumn(
                  icon: Icons.access_time,
                  label: 'Llegada',
                  value: etaText,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: PillButton(
              label: isLoading ? 'Solicitando...' : 'Viajar ahora',
              loading: isLoading,
              loadingLabel: 'Solicitando...',
              icon: Icons.local_taxi_rounded,
              onPressed: isLoading || !_puedeConfirmar ? null : onConfirmTrip,
            ),
          ),
          ],
        ),
      ),
    );
  }
}

/// Contador compacto de pasajeros (1 a 6).
class _PassengerCounter extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;

  const _PassengerCounter({
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.campo,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borde),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _stepButton(
            icon: Icons.remove_rounded,
            enabled: value > 1,
            onTap: () => onChanged(value - 1),
            tooltip: 'Quitar pasajero',
          ),
          SizedBox(
            width: 26,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.tinta,
              ),
            ),
          ),
          _stepButton(
            icon: Icons.add_rounded,
            enabled: value < 6,
            onTap: () => onChanged(value + 1),
            tooltip: 'Agregar pasajero',
          ),
        ],
      ),
    );
  }

  Widget _stepButton({
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: enabled ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: enabled ? AppColors.borde : Colors.transparent,
            ),
          ),
          child: Icon(
            icon,
            size: 16,
            color: enabled ? AppColors.tinta : AppColors.deshabilitadoTexto,
          ),
        ),
      ),
    );
  }
}

/// Chip de equipaje/mascota: se enciende con el acento del tema.
class _ExtraToggle extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ExtraToggle({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: value ? AppColors.acentoSuave : AppColors.campo,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: value ? AppColors.acento : AppColors.borde,
            width: value ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: value ? AppColors.acento : AppColors.secundario,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: value ? FontWeight.w700 : FontWeight.w500,
                  color: value ? AppColors.tinta : AppColors.secundario,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddressRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String address;
  final String label;

  const _AddressRow({
    required this.icon,
    required this.iconColor,
    required this.address,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 10, color: iconColor),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.grey[600],
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                address,
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF1F2937),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _VehicleCard extends StatelessWidget {
  final VehicleOption vehicle;
  final bool isSelected;
  final VoidCallback onTap;

  const _VehicleCard({
    required this.vehicle,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 100,
        margin: const EdgeInsets.only(right: 12),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.acentoSuave : AppColors.campo,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? AppColors.acento : AppColors.borde,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
              child: Center(
                child: Image.asset(
                  vehicle.iconPath,
                  cacheWidth: 256,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stack) =>
                      const Icon(Icons.directions_car, size: 48),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              vehicle.displayName,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? AppColors.tinta : AppColors.secundario,
                decoration: isSelected ? TextDecoration.underline : null,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Selector de metodo de pago con las tres opciones reales del backend:
/// Efectivo, Billetera (saldo) y Transferencia externa (con recargo).
///
/// * Billetera muestra el saldo y avisa si no alcanza.
/// * Transferencia muestra el aviso del recargo configurado y el precio ya
///   incluye ese porcentaje (lo calculo el backend).
class _PaymentSelector extends StatelessWidget {
  final String value;
  final double walletBalance;
  final double transferSurchargeRate;
  final double precio;
  final double precioTransferencia;
  final ValueChanged<String> onChanged;

  const _PaymentSelector({
    required this.value,
    required this.walletBalance,
    required this.transferSurchargeRate,
    required this.precio,
    required this.precioTransferencia,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final sinSaldo = walletBalance + 0.009 < precio;
    final porcentaje = (transferSurchargeRate * 100).toStringAsFixed(
        transferSurchargeRate * 100 == (transferSurchargeRate * 100).round()
            ? 0
            : 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.account_balance_wallet_outlined,
                size: 18, color: AppColors.secundario),
            const SizedBox(width: 8),
            const Text(
              'Método de pago',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.tinta,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _MetodoCard(
                icon: Icons.payments_outlined,
                label: 'Efectivo',
                selected: value == 'Efectivo',
                onTap: () => onChanged('Efectivo'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MetodoCard(
                icon: Icons.account_balance_wallet_outlined,
                label: 'Billetera',
                detalle: '${walletBalance.toStringAsFixed(0)} CUP',
                selected: value == 'Billetera',
                onTap: () => onChanged('Billetera'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MetodoCard(
                icon: Icons.swap_horiz_rounded,
                label: 'Transferencia',
                selected: value == 'Transferencia',
                onTap: () => onChanged('Transferencia'),
              ),
            ),
          ],
        ),
        if (value == 'Billetera' && sinSaldo) ...[
          const SizedBox(height: 8),
          _Aviso(
            icon: Icons.error_outline,
            color: AppColors.error,
            texto: 'Saldo insuficiente: tienes '
                '${walletBalance.toStringAsFixed(2)} CUP y el viaje cuesta '
                '${precio.toStringAsFixed(2)} CUP. Elige otro método de pago.',
          ),
        ],
        if (value == 'Transferencia') ...[
          const SizedBox(height: 8),
          _Aviso(
            icon: Icons.info_outline,
            color: AppColors.ambar,
            texto: 'Al pagar por transferencia, se añade un $porcentaje% al '
                'costo del viaje '
                '(${precioTransferencia.toStringAsFixed(2)} CUP).',
          ),
        ],
      ],
    );
  }
}

class _MetodoCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? detalle;
  final bool selected;
  final VoidCallback onTap;

  const _MetodoCard({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.detalle,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color: selected ? AppColors.acentoSuave : AppColors.campo,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.acento : AppColors.borde,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 18,
                color: selected ? AppColors.tinta : AppColors.secundario),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? AppColors.tinta : AppColors.secundario,
              ),
            ),
            if (detalle != null) ...[
              const SizedBox(height: 1),
              Text(
                detalle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 10, color: AppColors.secundario),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Aviso extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String texto;

  const _Aviso({
    required this.icon,
    required this.color,
    required this.texto,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              texto,
              style: TextStyle(fontSize: 11.5, color: color, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailColumn extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _DetailColumn({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, size: 20, color: Colors.grey[600]),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(fontSize: 10, color: Colors.grey[600]),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: valueColor ?? Colors.grey[900],
            ),
            maxLines: 1,
          ),
        ],
      ),
    );
  }
}
