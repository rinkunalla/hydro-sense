// Admin privacy (CLAUDE.md D24, KICKOFF.md stage 6): the admin code never queries
// devices, device_health, flow_logs or pipelines. Static: it never names them and
// never imports Firestore (all admin data comes from callables). Runtime:
// admin_widget_test renders the admin screens with the user repository replaced
// by one that throws on any use.
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
  test('admin code never names the user data collections', () {
    // Path-like strings only: page routes start with "/" and UI sentences have
    // spaces, so neither is mistaken for a Firestore path.
    final forbidden = RegExp(
      r'''['"](?!/)[\w/{}$]*\b(devices|device_health|flow_logs|pipelines)\b[\w/{}$]*['"]''',
    );
    for (final f in adminFiles) {
      final hits = forbidden
          .allMatches(f.readAsStringSync())
          .map((m) => m.group(0))
          .toList();
      expect(hits, isEmpty, reason: '${f.path} names $hits');
    }
  });

  test('admin code does not use the user data layer', () {
    final clientApi = RegExp(
      r'\b(fleetProvider|statusChangesProvider|repositoryProvider|profileProvider|ClientRepository)\b|data/repository\.dart',
    );
    for (final f in adminFiles) {
      final text = f.readAsStringSync().replaceAll(
        'adminRepositoryProvider',
        '',
      );
      expect(clientApi.firstMatch(text)?.group(0), isNull, reason: f.path);
    }
  });

  test('admin code never imports Firestore: callables only (D24)', () {
    for (final f in adminFiles) {
      expect(
        f.readAsStringSync().contains('package:cloud_firestore/'),
        isFalse,
        reason: '${f.path} imports cloud_firestore',
      );
    }
  });
}
