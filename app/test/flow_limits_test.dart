// Flow limits on Details: automatic or the owner's own (D43).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydro_sense/core/theme.dart';
import 'package:hydro_sense/data/models.dart';
import 'package:hydro_sense/data/providers.dart';
import 'package:hydro_sense/data/repository.dart';
import 'package:hydro_sense/features/client/flow_limits.dart';

import 'test_data.dart';

class FakeRepo implements ClientRepository {
  final limits = <double?>[];

  @override
  Future<void> setFlowLimit(String deviceId, double? normalCutoff) async =>
      limits.add(normalCutoff);

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Widget harness(Device d, FakeRepo repo) => ProviderScope(
  overrides: [repositoryProvider.overrideWithValue(repo)],
  child: MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(
      body: SingleChildScrollView(
        child: FlowLimitsCard(device: d, now: testNow),
      ),
    ),
  ),
);

void main() {
  test('effective limits mirror the server (functions/src/lib/cutoffs.ts)', () {
    const auto = Device(
      id: 'D1',
      nickname: 'Garden',
      lowFlowCutoff: 1.5,
      normalFlowCutoff: 5,
    );
    expect(auto.limits, (low: 1.5, normal: 5.0));
    expect(auto.ownLimit, isFalse);
    const own = Device(
      id: 'D1',
      nickname: 'Garden',
      lowFlowCutoff: 1.5,
      normalFlowCutoff: 5,
      userNormalCutoff: 1.2,
    );
    // No Flow goes back to 0.2, or it would sit above the owner's limit.
    expect(own.limits, (low: 0.2, normal: 1.2));
    const broken = Device(id: 'D1', nickname: 'G', userNormalCutoff: 0.5);
    expect(broken.ownLimit, isFalse);
    expect(broken.limits, (low: 0.2, normal: 2.0));
  });

  testWidgets('shows the three bands and where they come from', (t) async {
    await t.pumpWidget(
      harness(
        Device(
          id: 'D1',
          nickname: 'Garden',
          lowFlowCutoff: 1.5,
          normalFlowCutoff: 5,
          calibratedAt: testNow,
        ),
        FakeRepo(),
      ),
    );
    expect(find.text('above 5.0 L/min'), findsOneWidget);
    expect(find.text('1.5 to 5.0 L/min'), findsOneWidget);
    expect(find.text('below 1.5 L/min'), findsOneWidget);
    expect(find.textContaining('every Sunday'), findsOneWidget);
  });

  testWidgets('set your own limit in 0.5 steps, then back to automatic', (
    t,
  ) async {
    final repo = FakeRepo();
    await t.pumpWidget(
      harness(const Device(id: 'D1', nickname: 'Garden'), repo),
    );
    expect(find.textContaining('Starting values'), findsOneWidget);
    await t.tap(find.text('Change limit'));
    await t.pumpAndSettle();
    expect(find.text('2.0 L/min'), findsOneWidget);
    expect(find.text('Use automatic limits'), findsNothing);
    await t.tap(find.byTooltip('Higher'));
    await t.pump();
    await t.tap(find.byTooltip('Higher'));
    await t.pump();
    expect(find.text('3.0 L/min'), findsOneWidget);
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(repo.limits, [3.0]);

    await t.pumpWidget(
      harness(
        const Device(id: 'D1', nickname: 'Garden', userNormalCutoff: 1.0),
        repo,
      ),
    );
    expect(find.text('Set by you.'), findsOneWidget);
    expect(find.text('below 0.2 L/min'), findsOneWidget);
    await t.tap(find.text('Change limit'));
    await t.pumpAndSettle();
    final lower = t.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.remove_rounded),
        matching: find.byType(IconButton),
      ),
    );
    expect(lower.onPressed, isNull, reason: '1.0 is the lowest limit');
    await t.tap(find.text('Use automatic limits'));
    await t.pumpAndSettle();
    expect(repo.limits, [3.0, null]);
  });
}
