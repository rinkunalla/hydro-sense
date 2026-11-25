// Map tab and Edit pipeline (4.5).
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:hydro_sense/data/places.dart';
import 'package:hydro_sense/app.dart';
import 'package:hydro_sense/core/glass.dart';
import 'package:hydro_sense/core/theme.dart';
import 'package:hydro_sense/data/models.dart';
import 'package:hydro_sense/data/pipeline.dart';
import 'package:hydro_sense/data/providers.dart';
import 'package:hydro_sense/data/repository.dart';
import 'package:hydro_sense/features/client/edit_pipeline_screen.dart';
import 'package:hydro_sense/features/client/map_screen.dart';
import 'package:hydro_sense/features/client/map_tiles.dart';

import 'test_data.dart';

const source = PipePoint('Main water tank', 16.0400, 120.3300);
const home = PipePoint('Home', 16.0500, 120.3300);

/// Records the pipelines the screens save (the map direction, 2026-11-25).
class SavingRepo implements ClientRepository {
  final saved = <Pipeline>[];

  @override
  Future<void> savePipeline(Pipeline pipeline) async => saved.add(pipeline);

  @override
  Future<void> setManualPin(String deviceId, double? lat, double? lng) async {}

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Widget harness(
  Widget screen, {
  List<DeviceView> views = const [],
  Pipeline? pipeline,
  MyLocation? location,
  bool admin = true,
  SavingRepo? repo,
}) => ProviderScope(
  overrides: [
    if (repo != null) repositoryProvider.overrideWithValue(repo),
    // The pipeline editor is the admin's (D63); staff only view the map.
    isAdminProvider.overrideWithValue(admin),
    fleetProvider.overrideWith((_) => Stream.value(Fleet(views))),
    pipelineProvider.overrideWith((_) => Stream.value(pipeline)),
    clockProvider.overrideWith((_) => Stream.value(testNow)),
    googleSessionProvider.overrideWith((ref, view) async => null),
    uidProvider.overrideWithValue('u1'),
    if (location != null) myLocationProvider.overrideWithValue(location),
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
  testWidgets('Show on map centres on that device and rings its pin', (
    t,
  ) async {
    await phone(t);
    final views = [at('Garden', 16.041), at('Farm', 16.300)];
    await t.pumpWidget(harness(const MapScreen(), views: views));
    await t.pump();
    await t.pump();
    // Both in view when the map opens normally.
    expect(find.bySemanticsLabel('Garden, Normal'), findsOneWidget);
    expect(find.bySemanticsLabel('Farm, Normal'), findsOneWidget);

    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(
      harness(const MapScreen(focusDevice: 'Farm'), views: views),
    );
    await t.pump();
    await t.pump();
    expect(find.bySemanticsLabel('Farm, Normal'), findsOneWidget);
    expect(find.bySemanticsLabel('Garden, Normal'), findsNothing);
  });

  testWidgets('labelled buttons: My devices brings them back, Full screen', (
    t,
  ) async {
    await phone(t);
    await t.pumpWidget(
      harness(const MapScreen(), views: [at('Garden', 16.041)]),
    );
    await t.pump();
    await t.pump();
    expect(find.text('My devices'), findsOneWidget);
    expect(find.text('Full screen'), findsOneWidget);
    expect(
      find.text("Use my phone's location"),
      findsNothing,
      reason: 'pin picker only',
    );
    for (var i = 0; i < 4; i++) {
      await t.drag(find.byType(FlutterMap), const Offset(-300, -300));
      await t.pumpAndSettle();
    }
    expect(find.bySemanticsLabel('Garden, Normal'), findsNothing);
    await t.tap(find.text('My devices'));
    await t.pumpAndSettle();
    expect(find.bySemanticsLabel('Garden, Normal'), findsOneWidget);
  });

  testWidgets('full screen hides the title and returns on the button or Back', (
    t,
  ) async {
    await phone(t);
    await t.pumpWidget(
      harness(const MapScreen(), views: [at('Garden', 16.041)]),
    );
    await t.pump();
    await t.pump();
    expect(find.text('Draw pipeline'), findsOneWidget);
    await t.tap(find.text('Full screen'));
    await t.pump();
    expect(find.text('Draw pipeline'), findsNothing);
    expect(find.bySemanticsLabel('Garden, Normal'), findsOneWidget);
    await t.tap(find.text('Exit full screen'));
    await t.pump();
    expect(find.text('Draw pipeline'), findsOneWidget);

    await t.tap(find.text('Full screen'));
    await t.pump();
    await t.binding.handlePopRoute();
    await t.pump();
    expect(find.text('Draw pipeline'), findsOneWidget, reason: 'Back exits');
  });

  testWidgets('staff see the map but never the pipeline editor (D63)', (
    t,
  ) async {
    // Reduce motion: the droplets along a pipeline never settle otherwise.
    await phone(t);
    await t.pumpWidget(
      harness(
        const MapScreen(),
        views: [at('Garden', 16.041), at('Unplaced', null)],
        pipeline: const Pipeline(
          name: 'Farm pipeline',
          source: source,
          branches: [
            Branch(id: 'b1', end: home, deviceIds: ['Garden', 'Unplaced']),
          ],
        ),
        admin: false,
      ),
    );
    await t.pump();
    await t.pump();
    expect(find.text('Farm pipeline'), findsOneWidget);
    expect(find.text('Draw pipeline'), findsNothing);
    expect(find.text('Edit pipeline'), findsNothing);
    // No pointer to a screen staff can't open.
    expect(find.text('1 device has no location yet.'), findsOneWidget);
  });

  testWidgets('no pipeline yet: device pins and one Draw pipeline button', (
    t,
  ) async {
    await phone(t);
    await t.pumpWidget(
      harness(const MapScreen(), views: [at('Garden', 16.041)]),
    );
    await t.pump();
    await t.pump();
    expect(find.text('Map'), findsOneWidget);
    expect(find.text('Draw pipeline'), findsOneWidget);
    expect(find.text('Edit pipeline'), findsNothing);
    expect(find.text('Start'), findsNothing);
    expect(find.bySemanticsLabel('Garden, Normal'), findsOneWidget);
  });

  testWidgets('OSM attribution is always visible; no Satellite without a key', (
    t,
  ) async {
    await phone(t);
    await t.pumpWidget(harness(const MapScreen()));
    await t.pump();
    expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
    expect(googleTilesAvailable, isFalse);
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
    expect(find.text('No location yet'), findsOneWidget);
    expect(find.text("Location from the device's GPS"), findsNWidgets(2));
  });

  testWidgets('edit: Set location opens the map; the phone sets it', (t) async {
    await phone(t);
    await t.pumpWidget(
      harness(
        const EditPipelineScreen(),
        views: [at('Near', 16.041)],
        location: const _Here(LatLng(16.05, 120.34)),
      ),
    );
    await t.pump();
    await t.pump();
    expect(find.text('Placed on the map'), findsNothing);
    await t.tap(find.widgetWithText(SecondaryButton, 'Set location').first);
    await t.pumpAndSettle();
    expect(find.text('Place the pin here'), findsOneWidget);
    expect(find.text('Use device GPS'), findsNothing, reason: 'devices only');
    await t.tap(find.text("Use my phone's location"));
    await t.pumpAndSettle();
    expect(find.text('Placed on the map'), findsOneWidget);
  });

  testWidgets('edit: no device GPS option while the module is off', (t) async {
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
    final row = find.widgetWithText(TextButton, 'Edit location');
    await t.ensureVisible(row);
    await t.pumpAndSettle();
    await t.tap(row);
    await t.pumpAndSettle();
    expect(find.text('No device GPS yet'), findsNothing);
    expect(find.text('Use device GPS'), findsNothing);
    expect(find.text("Use my phone's location"), findsOneWidget);
    expect(find.text('Place the pin here'), findsOneWidget);
  });

  testWidgets('edit: the picker explains a location problem', (t) async {
    await phone(t);
    await t.pumpWidget(
      harness(
        const EditPipelineScreen(),
        views: [at('Near', 16.041)],
        location: const _Fails(LocationProblem.servicesOff),
      ),
    );
    await t.pump();
    await t.pump();
    await t.tap(find.widgetWithText(SecondaryButton, 'Set location').first);
    await t.pumpAndSettle();
    await t.tap(find.text("Use my phone's location"));
    await t.pump();
    await t.pump();
    expect(find.textContaining('Turn on Location'), findsOneWidget);
    expect(
      find.text('Place the pin here'),
      findsOneWidget,
      reason: 'stays open',
    );
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
  group('map direction (2026-11-25)', () {
    const turned = Pipeline(
      name: 'Farm pipeline',
      source: source,
      branches: [
        Branch(id: 'b1', end: home, deviceIds: ['North tank']),
      ],
      rotation: 35,
    );

    testWidgets('staff: opens turned, compass to north, no Save', (t) async {
      await phone(t);
      await t.pumpWidget(
        harness(
          const MapScreen(),
          views: [at('North tank', 16.043)],
          pipeline: turned,
          admin: false,
        ),
      );
      await t.pump();
      await t.pump();
      final camera = MapCamera.of(t.element(find.byType(MarkerLayer)));
      expect(camera.rotation, closeTo(35, 0.01));
      expect(find.text('North up'), findsOneWidget);
      expect(find.text('Save this direction'), findsNothing);
      await t.tap(find.text('North up'));
      await t.pump();
      expect(MapCamera.of(t.element(find.byType(MarkerLayer))).rotation, 0);
      // Back to everyone's direction from the same button.
      expect(find.text('Saved direction'), findsOneWidget);
      expect(find.text('Save this direction'), findsNothing);
    });

    testWidgets('admin: turning away offers Save this direction', (t) async {
      await phone(t);
      final repo = SavingRepo();
      await t.pumpWidget(
        harness(
          const MapScreen(),
          views: [at('North tank', 16.043)],
          pipeline: turned,
          repo: repo,
        ),
      );
      await t.pump();
      await t.pump();
      expect(find.text('Save this direction'), findsNothing);
      await t.tap(find.text('North up'));
      await t.pump();
      await t.tap(find.text('Save this direction'));
      await t.pump();
      expect(repo.saved.single.rotation, 0);
      expect(repo.saved.single.branches.single.deviceIds, ['North tank']);
    });

    testWidgets('north up: no compass at all', (t) async {
      await phone(t);
      await t.pumpWidget(
        harness(
          const MapScreen(),
          views: [at('North tank', 16.043)],
          pipeline: turned.copyWith(rotation: 0),
        ),
      );
      await t.pump();
      await t.pump();
      expect(find.text('North up'), findsNothing);
      expect(find.text('Saved direction'), findsNothing);
    });

    testWidgets('Edit pipeline: Source at the top, kept through Save', (
      t,
    ) async {
      await phone(t);
      final repo = SavingRepo();
      await t.pumpWidget(
        harness(
          const EditPipelineScreen(),
          views: [at('North tank', 16.043)],
          pipeline: turned.copyWith(rotation: 0),
          repo: repo,
        ),
      );
      await t.pump();
      await t.pump();
      // The editor's list builds lazily: scroll down to the section.
      final atTop = find.widgetWithText(SecondaryButton, 'Source at the top');
      await t.scrollUntilVisible(
        atTop,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await t.pumpAndSettle();
      await t.tap(atTop);
      await t.pump();
      expect(
        find.text('Source at the top'),
        findsNWidgets(2),
      ); // label + button
      // Save sits in the header, scrolled away above: back up to it.
      final save = find.widgetWithText(PrimaryButton, 'Save');
      await t.scrollUntilVisible(
        save,
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(save);
      await t.pump();
      // home is due north of the source: the map turns half way round.
      expect(repo.saved.single.rotation.abs(), closeTo(180, 0.01));
    });
  });
}

class _Here implements MyLocation {
  const _Here(this.at);

  final LatLng at;

  @override
  Future<LatLng> current() async => at;
}

class _Fails implements MyLocation {
  const _Fails(this.problem);

  final LocationProblem problem;

  @override
  Future<LatLng> current() async => throw LocationError(problem);
}
