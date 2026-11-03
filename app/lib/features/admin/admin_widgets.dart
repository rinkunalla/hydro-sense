import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/admin_logic.dart';

/// The admin site uses only Online / Offline / Low battery styling, never the
/// flow status colors (docs/UI_UX_SPEC.md section 3). Icon + word, never color alone.
class StateBadge extends StatelessWidget {
  const StateBadge(this.state, {super.key});

  final AdminState state;

  @override
  Widget build(BuildContext context) {
    final (icon, color, word) = switch (state) {
      AdminState.online => (
        Icons.cloud_done,
        const Color(0xFF2F7D57),
        'Online',
      ),
      AdminState.offline => (
        Icons.cloud_off,
        const Color(0xFF6B7682),
        'Offline',
      ),
      AdminState.sleeping => (
        Icons.battery_alert,
        const Color(0xFFA86F00),
        'Sleeping (low battery)',
      ),
      AdminState.waiting => (
        Icons.hourglass_empty,
        AppColors.textMuted,
        'Waiting to register',
      ),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Flexible(child: Text(word, overflow: TextOverflow.ellipsis)),
      ],
    );
  }
}

class LowBatteryBadge extends StatelessWidget {
  const LowBatteryBadge({super.key});

  @override
  Widget build(BuildContext context) => const Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.battery_alert, size: 18, color: Color(0xFFA86F00)),
      SizedBox(width: 4),
      Text('Low battery'),
    ],
  );
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.action,
  });

  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(AppSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              ?action,
            ],
          ),
          const SizedBox(height: AppSpace.m),
          child,
        ],
      ),
    ),
  );
}
