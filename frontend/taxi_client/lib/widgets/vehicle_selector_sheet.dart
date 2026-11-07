import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'ui/glass_sheet.dart';
import 'ui/pill_button.dart';

/// Modelo de vehículo con su precio y datos
class VehicleOption {
  final String type;
  final double price;
  final String iconPath;
  final String displayName;

  VehicleOption({
    required this.type,
    required this.price,
    required this.iconPath,
    required this.displayName,
  });

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
    
    return VehicleOption(
      type: type,
      price: (json['price'] as num).toDouble(),
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
  final String etaText;
  final String paymentMethod;
  final List<VehicleOption> vehicles;
  final int selectedIndex;
  final ValueChanged<int> onVehicleSelected;
  final VoidCallback onConfirmTrip;
  final VoidCallback? onBack;
  final bool isLoading;

  const VehicleSelectorSheet({
    super.key,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.distanceKm,
    required this.etaText,
    required this.paymentMethod,
    required this.vehicles,
    required this.selectedIndex,
    required this.onVehicleSelected,
    required this.onConfirmTrip,
    this.onBack,
    this.isLoading = false,
  });

  VehicleOption get _selected => vehicles[selectedIndex];

  @override
  Widget build(BuildContext context) {
    return GlassSheet(
      showHandle: false,
      padding: EdgeInsets.zero,
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _DetailColumn(
                  icon: Icons.attach_money,
                  label: 'Precio',
                  value: '${_selected.price.toStringAsFixed(0)} CUP',
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
              onPressed: isLoading ? null : onConfirmTrip,
            ),
          ),
        ],
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
