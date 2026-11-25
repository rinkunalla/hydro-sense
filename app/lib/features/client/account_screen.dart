import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../core/time_format.dart';
import '../../data/providers.dart';

/// Account (4.6): the staff member's details, read only (D64), the display
/// switch and Sign out.
class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  @override
  Widget build(BuildContext context) {
    final p = ref.watch(profileProvider).valueOrNull;
    final solid = ref.watch(solidGlassProvider);
    final name = p?.displayName ?? '';
    final initials = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();

    // Read only (D64): the admin changes staff details and passwords.
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppText.note),
                Text(value, style: AppText.strong),
              ],
            ),
          ),
        ],
      ),
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.l,
            AppSpace.xl,
            AppSpace.l,
            AppSpace.xxl * 3,
          ),
          children: [
            Semantics(
              header: true,
              child: Text('Account', style: AppText.title(26)),
            ),
            const SizedBox(height: AppSpace.l),
            GlassPanel(
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: AppColors.tint,
                    child: Text(
                      initials.isEmpty ? '?' : initials,
                      style: AppText.title(
                        20,
                      ).copyWith(color: AppColors.onActionTint),
                    ),
                  ),
                  const SizedBox(width: AppSpace.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: AppText.title(20)),
                        Text('Staff', style: AppText.note),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.m),
            GlassPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  row('Username', p?.username ?? '-'),
                  row(
                    'Mobile number',
                    p?.phone == null ? 'None' : displayPhone(p?.phone),
                  ),
                  row('Email', p?.email ?? 'None'),
                  const SizedBox(height: AppSpace.s),
                  Text(
                    'Alerts go to this phone and the contacts above. Your admin can change them.',
                    style: AppText.note,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.l),
            const SectionLabel('Display'),
            GlassPanel(
              child: MergeSemantics(
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Solid glass', style: AppText.strong),
                  subtitle: Text(
                    'Easier to read: no see-through panels',
                    style: AppText.note,
                  ),
                  value: solid,
                  activeThumbColor: Colors.white,
                  activeTrackColor: AppColors.action,
                  onChanged: (v) =>
                      ref.read(solidGlassProvider.notifier).set(v),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.xl),
            SecondaryButton(
              label: 'Sign out',
              icon: Icons.logout_rounded,
              destructive: true,
              onPressed: () => signOut(ref),
            ),
            const SizedBox(height: AppSpace.s),
            Center(
              child: Text(
                'Hydro Sense ${AppConfig.appVersion}',
                style: AppText.note,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
