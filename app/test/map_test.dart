// Map tab and Edit pipeline (KICKOFF.md stage 5a, docs/UI_UX_SPEC.md 4.4, 4.5).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydro_sense/app.dart';
import 'package:hydro_sense/core/glass.dart';
import 'package:hydro_sense/core/theme.dart';
import 'package:hydro_sense/data/models.dart';
import 'package:hydro_sense/data/pipeline.dart';
import 'package:hydro_sense/data/providers.dart';
import 'package:hydro_sense/features/client/edit_pipeline_screen.dart';
import 'package:hydro_sense/features/client/map_screen.dart';
import 'package:hydro_sense/features/client/map_tiles.dart';

import 'test_data.dart';

const source = PipePoint('Main water tank', 16.0400, 120.3300);
const home = PipePoint('Home', 16.0500, 120.3300);

Widget harness(
  Widget screen, {
  List<DeviceView> views = const [],
  Pipeline? pipeline,
}) => ProviderScope(
  overrides: [
    fleetProvider.overrideWith((_) => Stream.value(Fleet(views))),
    pipelineProvider.overrideWith((_) => Stream.value(pipeline)),
    clockProvider.overrideWith((_) => Stream.value(testNow)),
    googleSessionProvider.overrideWith((_) async => null),
    uidProvider.overrideWithValue('u1'),
  ],
  child: MaterialApp(
    theme: buildLightTheme(),
    builder: clampTextScale,
    home: AppBackground(child: screen),
  ),
);

Future<void> phone(WidgetTester t, {double textScale = 1.0}) async {
  t.view.physicalSize = const Size(360 * 3, 780 * 3);
  t.view.devicePixelRatio = 3;
  t.platformDispatcher.textScaleFactorTestValue = textScale;
  t.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

DeviceView at(String id, double? lat, {String status = 'Normal Flow'}) =>
    view(id, nickname: id, lat: lat, flowStatus: status);

void main() {
  testWidgets('no pipeline yet: device pins and the Draw your pipeline card', (
    t,
  ) async {
    await phone(t);
    await t.pumpWidget(
      harness(const MapScreen(), views: [at('Garden', 16.041)]),
    );
    await t.pump();
    await t.pump();
    expect(find.text('Map'), findsOneWidget);
    expect(
      find.text('Draw your pipeline: set the source, then add a branch.'),
      findsOneWidget,
    );
    expect(find.text('Start'), findsOneWidget);
    expect(find.bySemanticsLabel('Garden, Normal'), findsOneWidget);
  });

  testWidgets('OSM attribution is always visible; no Satellite without a key', (
    t,
  ) async {
    await phone(t);
    await t.pumpWidget(harness(const MapScreen()));
    await t.pump();
    expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
    expect(satelliteAvailable, isFalse);
    expect(find.text('Satellite'), findsNothing);
  });

  testWidgets('a pipeline shows its name, source and end pins', (t) async {
    await phone(t, textScale: 1.5);
    await t.pumpWidget(
      harness(
        const MapScreen(),
        views: [at('North tank', 16.043), at('Unplaced', null)],
        pipeline: const Pipeline(
          name: 'Farm pipeline',
          source: source,
          branches: [
            Branch(id: 'b1', end: home, deviceIds: ['North tank', 'Unplaced']),
          ],
        ),
      ),
    );
    await t.pump();
    await t.pump();
    expect(find.text('Farm pipeline'), findsOneWidget);
    expect(find.byIcon(Icons.water_rounded), findsOneWidget); // source pin
    expect(find.text('Home'), findsOneWidget); // end point pin
    expect(
      find.text('1 device has no location yet. Set it in Edit pipeline.'),
      findsOneWidget,
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('edit: new devices are ordered by distance from the source', (
    t,
  ) async {
    await phone(t);
    await t.pumpWidget(
      harness(
        const EditPipelineScreen(),
        views: [at('Far', 16.050), at('Unknown', null), at('Near', 16.041)],
        pipeline: const Pipeline(name: 'Farm pipeline', source: source),
      ),
    );
    await t.pump();
    await t.pump();
    final names = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data)
        .where((s) => s == 'Far' || s == 'Near' || s == 'Unknown')
        .toList();
    expect(names, ['Near', 'Far', 'Unknown']);
    expect(
      find.text('No location yet. Tap the pin to set it.'),
      findsOneWidget,
    );
    expect(find.text("Location from the device's GPS"), findsNWidgets(2));
  });

  testWidgets('edit: leaving with changes asks to discard them', (t) async {
    await phone(t);
    await t.pumpWidget(
      harness(
        const EditPipelineScreen(),
        views: [at('Near', 16.041)],
        pipeline: const Pipeline(name: 'Farm pipeline', source: source),
      ),
    );
    await t.pump();
    await t.pump();
    await t.enterText(
      find.widgetWithText(TextField, 'Pipeline name'),
      'River line',
    );
    await t.tap(find.byTooltip('Back'));
    await t.pumpAndSettle();
    expect(find.text('Discard your changes?'), findsOneWidget);
    await t.tap(find.text('Keep editing'));
    await t.pumpAndSettle();
    expect(find.text('Discard your changes?'), findsNothing);
    expect(find.text('Edit pipeline'), findsOneWidget);
  });
}
