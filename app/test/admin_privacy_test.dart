// KICKOFF.md Phase 6: "a test confirms no query touches devices, flow_logs, or
// client_summary". Static: the admin code never names them and only uses allowed
// paths. Runtime: admin_widget_test renders every admin screen with the client
// repository replaced by one that throws on any use.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final adminFiles = [
  File('lib/admin_router.dart'),
  File('lib/data/admin_repository.dart'),
  File('lib/data/admin_logic.dart'),
  File('lib/data/admin_providers.dart'),
  ...Directory('lib/features/admin')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart')),
];

void main() {
  test('admin code never names the client flow collections', () {
    // Path-like strings only: page routes start with "/" and UI sentences have
    // spaces, so neither is mistaken for a Firestore path.
    final forbidden = RegExp(
      r'''['"](?!/)[\w/{}$]*\b(devices|flow_logs|client_summary)\b[\w/{}$]*['"]''',
    );
    for (final f in adminFiles) {
      final hits = forbidden
          .allMatches(f.readAsStringSync())
          .map((m) => m.group(0))
          .toList();
      expect(hits, isEmpty, reason: '${f.path} names $hits');
    }
  });

  test('admin code does not use the client data layer', () {
    final clientApi = RegExp(
      r'\b(fleetProvider|summaryProvider|statusChangesProvider|repositoryProvider|profileProvider|ClientRepository)\b|data/repository\.dart',
    );
    for (final f in adminFiles) {
      final text = f.readAsStringSync().replaceAll(
        'adminRepositoryProvider',
        '',
      );
      expect(clientApi.firstMatch(text)?.group(0), isNull, reason: f.path);
    }
  });

  test(
    'every Firestore path in the admin repository is one the admin may read',
    () {
      const allowed = {
        'device_health',
        'device_health/{id}/battery_logs',
        'allowed_devices',
        'removed_devices',
        'error_logs',
        'ai_insights/admin_diagnostics',
        'config/system',
      };
      final src = File('lib/data/admin_repository.dart').readAsStringSync();
      final paths = RegExp(r'''\.(?:collection|doc)\(\s*'([^']+)'\s*\)''')
          .allMatches(src)
          .map((m) => m.group(1)!.replaceAll(RegExp(r'\$\w+'), '{id}'))
          .toSet();
      expect(paths, isNotEmpty);
      expect(
        paths.difference(allowed),
        isEmpty,
        reason: 'unexpected paths: ${paths.difference(allowed)}',
      );
    },
  );
}
