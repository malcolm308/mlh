import 'package:flutter/material.dart';

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
    this.isLoading = false,
  });

  VehicleOption get _selected => vehicles[selectedIndex];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
        boxShadow: [
          BoxShadow(
            color: Color(0x29000000),
            blurRadius: 12,
            offset: Offset(0, -3),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
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
                  valueColor: const Color(0xFF007AFF),
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
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: isLoading ? null : onConfirmTrip,
                icon: isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.local_taxi),
                label: Text(
                  isLoading ? 'Solicitando...' : 'Viajar ahora',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF007AFF),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
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
          color: isSelected
              ? const Color(0xFF007AFF).withValues(alpha: 0.08)
              : Colors.grey[100],
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? const Color(0xFF007AFF) : Colors.grey[300]!,
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
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? const Color(0xFF007AFF) : Colors.grey[800],
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
