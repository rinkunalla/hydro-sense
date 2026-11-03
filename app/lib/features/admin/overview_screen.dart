import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../core/time_format.dart';
import '../../data/admin_logic.dart';
import '../../data/admin_providers.dart';
import '../../data/admin_repository.dart';
import '../../data/providers.dart' show clockProvider;
import 'admin_widgets.dart';

class OverviewScreen extends ConsumerWidget {
  const OverviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(adminRowsProvider);
    final report = ref.watch(diagnosticsProvider).valueOrNull;
    final now = ref.watch(clockProvider).valueOrNull ?? DateTime.now();

    return ListView(
      padding: const EdgeInsets.all(AppSpace.xl),
      children: [
        rows.when(
          loading: () => Wrap(
            spacing: AppSpace.l,
            runSpacing: AppSpace.l,
            children: [
              for (var i = 0; i < 4; i++)
                Container(
                  width: 200,
                  height: 96,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(AppSpace.cardRadius),
                  ),
                ),
            ],
          ),
          error: (_, _) => const Text(Messages.generic),
          data: (r) {
            final c = countersFor(r);
            if (c.registered == 0) {
              return const SectionCard(
                title: 'Devices',
                child: Text('No devices have registered yet.'),
              );
            }
            return Wrap(
              spacing: AppSpace.l,
              runSpacing: AppSpace.l,
              children: [
                _Counter(
                  'Registered',
                  c.registered,
                  Icons.memory,
                  AppColors.primary,
                ),
                _Counter(
                  'Online',
                  c.online,
                  Icons.cloud_done,
                  const Color(0xFF2F7D57),
                ),
                _Counter(
                  'Offline',
                  c.offline,
                  Icons.cloud_off,
                  const Color(0xFF6B7682),
                ),
                _Counter(
                  'Low battery',
                  c.lowBattery,
                  Icons.battery_alert,
                  const Color(0xFFA86F00),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: AppSpace.l),
        Text(
          report?.lastUpdated == null
              ? 'Last hardware report: none yet'
              : 'Last hardware report: ${clockTime(report!.lastUpdated!, now)}',
          style: const TextStyle(color: AppColors.textMuted),
        ),
        const SizedBox(height: AppSpace.l),
        const ClientCard(),
      ],
    );
  }
}

class _Counter extends StatelessWidget {
  const _Counter(this.label, this.value, this.icon, this.color);

  final String label;
  final int value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '$label: $value',
    child: SizedBox(
      width: 200,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.l),
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, color: color, size: 20),
                    const SizedBox(width: AppSpace.s),
                    Expanded(
                      child: Text(label, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.s),
                Text('$value', style: Theme.of(context).textTheme.displaySmall),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Create client: shown only while no client exists; afterwards the client's
/// name and email (docs/UI_UX_SPEC.md section 5).
class ClientCard extends ConsumerStatefulWidget {
  const ClientCard({super.key});

  @override
  ConsumerState<ClientCard> createState() => _ClientCardState();
}

class _ClientCardState extends ConsumerState<ClientCard> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  bool _temporary = false;
  bool _busy = false;
  String? _error;
  String? _fieldError;
  CreateClientResult? _result;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    super.dispose();
  }

  String? _validate() {
    if (_name.text.trim().isEmpty) return 'Enter the client\'s name.';
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(_email.text.trim())) {
      return 'Enter a valid email address.';
    }
    if (!AppConfig.phMobilePattern.hasMatch(
      _phone.text.replaceAll(RegExp(r'[\s-]'), ''),
    )) {
      return 'Enter a Philippine mobile number, for example 09171234567.';
    }
    return null;
  }

  Future<void> _create() async {
    final problem = _validate();
    setState(() {
      _fieldError = problem;
      _error = null;
    });
    if (problem != null) return;
    setState(() => _busy = true);
    try {
      final r = await ref
          .read(adminRepositoryProvider)
          .createClient(
            name: _name.text.trim(),
            email: _email.text.trim(),
            phone: _phone.text,
            temporaryPassword: _temporary,
          );
      if (mounted) setState(() => _result = r);
    } catch (e) {
      final code = callableDetails(e).code;
      setState(
        () => _error = switch (code) {
          'CLIENT_EXISTS' => 'A client account already exists.',
          'EMAIL_IN_USE' => 'An account with this email already exists.',
          'PHONE_INVALID' =>
            'Enter a Philippine mobile number, for example 09171234567.',
          'EMAIL_INVALID' => 'Enter a valid email address.',
          'NAME_INVALID' => 'Enter the client\'s name.',
          _ => callableMessage(e),
        },
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(clientInfoProvider);
    final r = _result;

    if (r != null) {
      return SectionCard(
        title: 'Client account created',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (r.temporaryPassword != null) ...[
              const Text('Temporary password. Copy it now. It is shown once.'),
              const SizedBox(height: AppSpace.s),
              SelectableText(
                r.temporaryPassword!,
                style: const TextStyle(
                  fontSize: 20,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: AppSpace.s),
              const Text(
                'The client must choose a new password at first sign-in.',
              ),
            ] else if (r.emailSent == false)
              const Text(
                'Account created, but the setup email could not be sent. Use a temporary password instead.',
              )
            else
              const Text('A setup email is on its way to the client.'),
            if (r.adopted > 0) ...[
              const SizedBox(height: AppSpace.s),
              Text(
                '${r.adopted} already-registered ${r.adopted == 1 ? 'device was' : 'devices were'} assigned to the client.',
              ),
            ],
            const SizedBox(height: AppSpace.m),
            TextButton(
              onPressed: () => setState(() => _result = null),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    }

    return client.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const Text(Messages.generic),
      data: (c) {
        if (c != null) {
          return SectionCard(
            title: 'Client',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.name ?? '-',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(c.email ?? '-'),
              ],
            ),
          );
        }
        return SectionCard(
          title: 'Create client account',
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _name,
                  enabled: !_busy,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: AppSpace.m),
                TextField(
                  controller: _email,
                  enabled: !_busy,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                const SizedBox(height: AppSpace.m),
                TextField(
                  controller: _phone,
                  enabled: !_busy,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Mobile number',
                    hintText: '09171234567',
                  ),
                ),
                const SizedBox(height: AppSpace.m),
                RadioGroup<bool>(
                  groupValue: _temporary,
                  onChanged: (v) => setState(() => _temporary = v ?? false),
                  child: const Column(
                    children: [
                      RadioListTile<bool>(
                        value: false,
                        title: Text('Send a setup email link'),
                      ),
                      RadioListTile<bool>(
                        value: true,
                        title: Text('Create a temporary password'),
                      ),
                    ],
                  ),
                ),
                if (_fieldError != null || _error != null) ...[
                  const SizedBox(height: AppSpace.s),
                  Text(
                    _fieldError ?? _error!,
                    style: const TextStyle(color: Color(0xFF8A2A20)),
                  ),
                ],
                const SizedBox(height: AppSpace.m),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    onPressed: _busy ? null : _create,
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Create client'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
