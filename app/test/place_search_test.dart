// Map search and My location (fakes for the search callable and the GPS).
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydro_sense/core/theme.dart';
import 'package:hydro_sense/data/places.dart';
import 'package:hydro_sense/features/client/place_search.dart';
import 'package:latlong2/latlong.dart';

class FakeSearch implements PlaceSearch {
  final queries = <String>[];
  Object? error;

  @override
  Future<List<Place>> search(String query) async {
    queries.add(query);
    if (error != null) throw error!;
    return const [
      Place('San Fabian, Pangasinan, Philippines', 16.12, 120.40),
      Place('San Fabian Church, San Fabian, Pangasinan', 16.13, 120.41),
    ];
  }
}

class FakeLocation implements MyLocation {
  FakeLocation(this.result);

  final Object result;

  @override
  Future<LatLng> current() async {
    if (result is LocationError) throw result;
    return result as LatLng;
  }
}

Widget harness(Widget child, {PlaceSearch? search, MyLocation? location}) =>
    ProviderScope(
      overrides: [
        if (search != null) placeSearchProvider.overrideWithValue(search),
        if (location != null) myLocationProvider.overrideWithValue(location),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    );

void main() {
  testWidgets('searches only on tap, then a picked result is reported', (
    t,
  ) async {
    final search = FakeSearch();
    Place? picked;
    await t.pumpWidget(
      harness(PlaceSearchBar(onPick: (p) => picked = p), search: search),
    );
    await t.enterText(find.byType(TextField), 'San Fabian');
    await t.pump();
    expect(search.queries, isEmpty, reason: 'no search-as-you-type');
    await t.tap(find.text('Search'));
    await t.pumpAndSettle();
    expect(search.queries, ['San Fabian']);
    expect(find.text('San Fabian, Pangasinan, Philippines'), findsOneWidget);
    expect(find.text('Search © OpenStreetMap contributors'), findsOneWidget);
    await t.tap(find.text('San Fabian Church, San Fabian, Pangasinan'));
    await t.pumpAndSettle();
    expect(picked?.lat, 16.13);
    expect(find.text('San Fabian, Pangasinan, Philippines'), findsNothing);
  });

  testWidgets('the keyboard search key works too; one letter is refused', (
    t,
  ) async {
    final search = FakeSearch();
    await t.pumpWidget(harness(PlaceSearchBar(onPick: (_) {}), search: search));
    await t.enterText(find.byType(TextField), 'a');
    await t.testTextInput.receiveAction(TextInputAction.search);
    await t.pump();
    expect(find.text('Type at least 2 letters.'), findsOneWidget);
    expect(search.queries, isEmpty);
    await t.enterText(find.byType(TextField), 'Dagupan');
    await t.testTextInput.receiveAction(TextInputAction.search);
    await t.pumpAndSettle();
    expect(search.queries, ['Dagupan']);
  });

  testWidgets('says when search is switched off or busy', (t) async {
    final search = FakeSearch()
      ..error = FirebaseFunctionsException(
        code: 'failed-precondition',
        message: 'x',
        details: {'code': 'SEARCH_OFF'},
      );
    await t.pumpWidget(harness(PlaceSearchBar(onPick: (_) {}), search: search));
    await t.enterText(find.byType(TextField), 'Dagupan');
    await t.tap(find.text('Search'));
    await t.pumpAndSettle();
    expect(
      find.text('Place search is off for now. Move the map by hand.'),
      findsOneWidget,
    );
    search.error = FirebaseFunctionsException(
      code: 'resource-exhausted',
      message: 'x',
      details: {'code': 'SEARCH_BUSY'},
    );
    await t.tap(find.text('Search'));
    await t.pumpAndSettle();
    expect(find.text('Search is busy. Try again in a moment.'), findsOneWidget);
  });

  testWidgets('My location reports the position', (t) async {
    LatLng? found;
    await t.pumpWidget(
      harness(
        MyLocationButton(onFound: (at) => found = at),
        location: FakeLocation(const LatLng(16.05, 120.33)),
      ),
    );
    await t.tap(find.bySemanticsLabel('My location'));
    await t.pumpAndSettle();
    expect(found, const LatLng(16.05, 120.33));
  });

  for (final (problem, words) in [
    (LocationProblem.servicesOff, 'Turn on Location in your phone settings'),
    (LocationProblem.denied, 'Allow location to show where you are.'),
    (LocationProblem.blocked, 'Location is blocked for Hydro Sense'),
  ]) {
    testWidgets('My location explains: ${problem.name}', (t) async {
      await t.pumpWidget(
        harness(
          MyLocationButton(onFound: (_) {}),
          location: FakeLocation(LocationError(problem)),
        ),
      );
      await t.tap(find.bySemanticsLabel('My location'));
      await t.pump();
      await t.pump();
      expect(find.textContaining(words), findsOneWidget);
    });
  }
}
