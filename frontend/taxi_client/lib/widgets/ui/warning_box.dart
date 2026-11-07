import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Caja de advertencia con fondo ambar muy suave, borde sutil y texto ambar.
///
/// Se usa para avisos del sistema (por ejemplo el recordatorio del vehiculo
/// activo o el estado de las solicitudes).
class WarningBox extends StatelessWidget {
  final String title;
  final String? message;
  final IconData icon;

  const WarningBox({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.info_outline,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.ambarFondo,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.ambarBorde),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 17, color: AppColors.ambar),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.ambar,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
                if (message != null && message!.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    message!,
                    style: const TextStyle(
                      color: AppColors.ambar,
                      fontSize: 11.5,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
