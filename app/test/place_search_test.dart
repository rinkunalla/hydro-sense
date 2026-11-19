// Live place search (Google Places) and My location, with fakes.
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydro_sense/core/theme.dart';
import 'package:hydro_sense/data/places.dart';
import 'package:hydro_sense/features/client/place_search.dart';
import 'package:latlong2/latlong.dart';

class FakeSearch implements PlaceSearch {
  final typed = <String>[];
  final sessions = <String>[];
  final located = <String>[];
  LatLng? nearSeen;
  Object? error;

  @override
  Future<List<PlaceSuggestion>> suggest(
    String input,
    String session, {
    LatLng? near,
  }) async {
    typed.add(input);
    sessions.add(session);
    nearSeen = near;
    if (error != null) throw error!;
    return const [
      PlaceSuggestion('p1', 'SM City Rosales', 'Rosales, Pangasinan'),
      PlaceSuggestion('p2', 'Rosales Public Market', ''),
    ];
  }

  @override
  Future<LatLng> locate(String placeId, String session) async {
    located.add('$placeId@$session');
    return const LatLng(15.89, 120.6);
  }
}

Widget harness(Widget child, {PlaceSearch? search}) => ProviderScope(
  overrides: [
    if (search != null) placeSearchProvider.overrideWithValue(search),
  ],
  child: MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(
      body: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  ),
);

const pause = Duration(milliseconds: 400);

void main() {
  test('session tokens are fresh UUID v4s', () {
    final a = newPlacesSession();
    expect(
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(a),
      isTrue,
    );
    expect(newPlacesSession(), isNot(a));
  });

  testWidgets('suggests while typing after a pause, then a pick is located '
      'in the same session', (t) async {
    final search = FakeSearch();
    Place? picked;
    await t.pumpWidget(
      harness(
        PlaceSearchBar(
          onPick: (p) => picked = p,
          near: () => const LatLng(16, 120.4),
        ),
        search: search,
      ),
    );
    await t.enterText(find.byType(TextField), 'sm');
    await t.pump(pause);
    expect(search.typed, isEmpty, reason: 'under 3 letters');

    await t.enterText(find.byType(TextField), 'sm c');
    await t.pump(const Duration(milliseconds: 100));
    await t.enterText(find.byType(TextField), 'sm ci');
    await t.pump(pause);
    await t.pump();
    expect(search.typed, ['sm ci'], reason: 'one call after the pause');
    expect(search.nearSeen, const LatLng(16, 120.4));
    expect(find.text('SM City Rosales'), findsOneWidget);
    expect(find.text('Rosales, Pangasinan'), findsOneWidget);

    await t.tap(find.text('SM City Rosales'));
    await t.pumpAndSettle();
    expect(picked?.name, 'SM City Rosales');
    expect(picked?.lat, 15.89);
    expect(search.located, ['p1@${search.sessions.single}']);
    expect(find.text('Rosales Public Market'), findsNothing);

    // The next search starts a new session.
    await t.enterText(find.byType(TextField), 'market');
    await t.pump(pause);
    await t.pump();
    expect(search.sessions.last, isNot(search.sessions.first));
  });

  testWidgets('the keyboard search key picks the first suggestion', (t) async {
    final search = FakeSearch();
    Place? picked;
    await t.pumpWidget(
      harness(PlaceSearchBar(onPick: (p) => picked = p), search: search),
    );
    await t.enterText(find.byType(TextField), 'rosales');
    await t.pump(pause);
    await t.pump();
    await t.testTextInput.receiveAction(TextInputAction.search);
    await t.pumpAndSettle();
    expect(picked?.name, 'SM City Rosales');
  });

  testWidgets('says when search is off or the daily limit is reached', (
    t,
  ) async {
    final search = FakeSearch()
      ..error = FirebaseFunctionsException(
        code: 'failed-precondition',
        message: 'x',
        details: {'code': 'SEARCH_OFF'},
      );
    await t.pumpWidget(harness(PlaceSearchBar(onPick: (_) {}), search: search));
    await t.enterText(find.byType(TextField), 'dagupan');
    await t.pump(pause);
    await t.pump();
    expect(
      find.text('Place search is off for now. Move the map by hand.'),
      findsOneWidget,
    );
    search.error = FirebaseFunctionsException(
      code: 'resource-exhausted',
      message: 'x',
      details: {'code': 'PLACES_USER_LIMIT'},
    );
    await t.enterText(find.byType(TextField), 'dagupan city');
    await t.pump(pause);
    await t.pump();
    expect(find.textContaining("You've searched a lot today"), findsOneWidget);
  });
}
