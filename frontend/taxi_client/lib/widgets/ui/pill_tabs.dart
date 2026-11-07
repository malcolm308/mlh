import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Una pestana del selector tipo pildora.
class PillTabItem<T> {
  final T value;
  final String label;
  final IconData? icon;

  const PillTabItem({
    required this.value,
    required this.label,
    this.icon,
  });
}

/// Selector de pestanas en forma de pildora gris claro.
///
/// La pestana activa lleva fondo amarillo solido y texto oscuro; la inactiva
/// es transparente con texto oscuro.
class PillTabs<T> extends StatelessWidget {
  final List<PillTabItem<T>> items;
  final T value;
  final ValueChanged<T> onChanged;

  const PillTabs({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: const ShapeDecoration(
        color: AppColors.deshabilitado,
        shape: StadiumBorder(),
      ),
      child: Row(
        children: [
          for (final item in items)
            Expanded(
              child: _PillTab(
                label: item.label,
                icon: item.icon,
                active: item.value == value,
                onTap: () => onChanged(item.value),
              ),
            ),
        ],
      ),
    );
  }
}

class _PillTab extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool active;
  final VoidCallback onTap;

  const _PillTab({
    required this.label,
    required this.active,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        height: 40,
        decoration: ShapeDecoration(
          color: active ? AppColors.acento : Colors.transparent,
          shape: const StadiumBorder(),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 16,
                color: active ? AppColors.tinta : AppColors.secundario,
              ),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                  color: AppColors.tinta,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
