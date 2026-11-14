import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/admin_logic.dart';

/// The admin site shows only connection states, never flow or battery colors
/// (D24, docs/UI_UX_SPEC.md section 3). Icon + word, never color alone.
class StateBadge extends StatelessWidget {
  const StateBadge(this.state, {super.key, this.detail});

  final AdminState state;

  /// Extra words after the state, for example "since 3:42 PM".
  final String? detail;

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
      AdminState.notSetUp => (
        Icons.hourglass_empty,
        AppColors.textMuted,
        'Not set up yet',
      ),
      AdminState.removed => (Icons.block, const Color(0xFF8A2A20), 'Removed'),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            detail == null ? word : '$word $detail',
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
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
