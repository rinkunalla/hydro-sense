// Pipeline logic (acceptance).
import 'package:flutter_test/flutter_test.dart';
import 'package:hydro_sense/data/models.dart';
import 'package:hydro_sense/data/pipeline.dart';
import 'package:hydro_sense/data/pipeline_logic.dart';

import 'test_data.dart';

void main() {
  const source = PipePoint('Main water tank', 16.0400, 120.3300);
  DeviceView at(String id, double? lat, {String status = 'Normal Flow'}) =>
      view(id, nickname: id, lat: lat, flowStatus: status);

  test('distance: about 111 m per 0.001 degree of latitude', () {
    expect(distanceM(16.04, 120.33, 16.041, 120.33), closeTo(111.2, 0.5));
  });

  test('default order: nearest first; no location listed last, not placed', () {
    final order = defaultOrder(source, [
      at('Far', 16.0500),
      at('Unknown', null),
      at('Near', 16.0410),
      at('Mid', 16.0450),
    ]);
    expect(order.map((v) => v.nickname), ['Near', 'Mid', 'Far', 'Unknown']);
    expect(order.last.hasLocation, isFalse);
  });

  test(
    'branch order follows the saved IDs and skips devices no longer owned',
    () {
      final b = Branch(
        id: 'b1',
        end: const PipePoint('Home', 16.05, 120.33),
        deviceIds: const ['B', 'GONE', 'A'],
      );
      expect(inBranch(b, [at('A', 1), at('B', 2)]).map((v) => v.id), [
        'B',
        'A',
      ]);
    },
  );

  test('ordinals', () {
    expect([1, 2, 3, 4, 11, 12, 13, 21, 22].map(ordinal), [
      '1st',
      '2nd',
      '3rd',
      '4th',
      '11th',
      '12th',
      '13th',
      '21st',
      '22nd',
    ]);
  });

  group('where water stops', () {
    WaterStop? stops(List<String> statuses) => waterStops([
      for (final (i, s) in statuses.indexed)
        s == 'Offline'
            ? view('D$i', online: false)
            : s == 'Waiting'
            ? view('D$i', flowStatus: null)
            : view('D$i', flowStatus: s),
    ]);

    test('no problem on the branch', () {
      expect(stops(['Normal Flow', 'Normal Flow']), isNull);
      expect(stops(['Normal Flow', 'Offline']), isNull);
    });

    test('between the last Normal device and the first Low/No device', () {
      final s = stops(['Normal Flow', 'Normal Flow', 'No Flow', 'No Flow'])!;
      expect([s.fromIndex, s.toIndex], [1, 2]);
    });

    test('right after the source when the first device has no water', () {
      final s = stops(['No Flow', 'Normal Flow'])!;
      expect([s.fromIndex, s.toIndex], [-1, 0]);
    });

    test('Offline and not-yet-reporting devices are skipped', () {
      final s = stops(['Normal Flow', 'Offline', 'Waiting', 'Low Flow'])!;
      expect([s.fromIndex, s.toIndex], [0, 3]);
      final t = stops(['Offline', 'No Flow'])!;
      expect([t.fromIndex, t.toIndex], [-1, 1]);
    });

    test('the first problem counts, even if water returns further on', () {
      final s = stops(['Normal Flow', 'Low Flow', 'Normal Flow', 'No Flow'])!;
      expect([s.fromIndex, s.toIndex], [0, 1]);
    });
  });

  test('map banner wording (4.4)', () {
    final b = Branch(
      id: 'b1',
      end: const PipePoint('Home', 16.05, 120.33),
      deviceIds: const ['North tank', 'Home line'],
    );
    expect(
      mapBanner(b, [
        at('North tank', 1),
        at('Home line', 2, status: 'No Flow'),
      ]),
      'Problem on the Home branch · Water stops between North tank and Home line',
    );
    expect(
      mapBanner(b, [at('North tank', 1, status: 'Low Flow')]),
      'Problem on the Home branch · Water stops between the source and North tank',
    );
    expect(mapBanner(b, [at('North tank', 1)]), isNull);
  });

  test('pipeline round trip keeps the shape the rules check', () {
    const p = Pipeline(
      name: 'Farm pipeline',
      source: source,
      branches: [
        Branch(
          id: 'b1',
          end: PipePoint('Home', 16.05, 120.33),
          deviceIds: ['A'],
        ),
      ],
    );
    final m = p.toMap();
    expect(m.keys.toSet(), {'name', 'source', 'branches'});
    final back = Pipeline.fromMap(Map<String, dynamic>.from(m))!;
    expect(back.branches.single.deviceIds, ['A']);
    expect(back.source.name, 'Main water tank');
  });

  test('effective location: a manual pin wins over GPS', () {
    const d = Device(
      id: 'x',
      nickname: 'X',
      lat: 16.1,
      lng: 120.4,
      gpsLat: 16.0,
      gpsLng: 120.3,
      manualPin: true,
    );
    expect(DeviceView(d, null).device.lat, 16.1);
    expect(DeviceView(d, null).hasGps, isTrue);
  });
}
