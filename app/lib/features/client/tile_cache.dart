import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/config.dart';

/// Keeps map tiles on the phone so reopening the same area downloads nothing.
///
/// Google's Map Tiles API answers `Cache-Control: private, max-age=86400,
/// must-revalidate` (checked 2026-11-16), so a tile may be kept for its
/// max-age and never longer than AppConfig.tileCacheHours. A reply without a
/// max-age, or with no-store, is not kept. Only the API key is left out of
/// the cache key. The session stays in it: a Google session is what makes a
/// tile road map or satellite (the tile address is the same for both), so
/// dropping it served satellite tiles on the road map (fixed 2026-11-17).
class TileCacheClient extends http.BaseClient {
  TileCacheClient(this._inner);

  final http.Client _inner;
  Future<Directory?>? _dir;

  Future<Directory?> _folder() => _dir ??= () async {
    if (kIsWeb) return null;
    try {
      final base = await getApplicationCacheDirectory();
      // v2: the first folder may hold road map and satellite tiles mixed up.
      final old = Directory('${base.path}/map_tiles');
      if (await old.exists()) unawaited(old.delete(recursive: true));
      final d = Directory('${base.path}/map_tiles_v2');
      await d.create(recursive: true);
      unawaited(_prune(d));
      return d;
    } catch (_) {
      return null; // no cache folder: tiles still load, just uncached
    }
  }();

  /// A stable hash of the URL without session and key: two 32-bit FNV-1a
  /// hashes with different seeds (32-bit, so the code also compiles for the
  /// website, where the cache is never used).
  static String keyOf(Uri url) {
    final params = Map.of(url.queryParameters)..remove('key');
    // Built by hand: Uri.replace(queryParameters: null) would keep the old query.
    final kept = (params.keys.toList()..sort()).map((k) => '$k=${params[k]}');
    final bytes = utf8.encode(
      '${url.scheme}://${url.host}${url.path}?${kept.join('&')}',
    );
    String fnv(int seed) {
      var h = seed;
      for (final b in bytes) {
        h = ((h ^ b) * 16777619) & 0xFFFFFFFF;
      }
      return h.toRadixString(16).padLeft(8, '0');
    }

    return fnv(0x811c9dc5) + fnv(0x01000193);
  }

  /// Seconds a reply may be kept: its max-age, capped at tileCacheHours.
  static int keepSeconds(String? cacheControl) {
    final cc = (cacheControl ?? '').toLowerCase();
    if (cc.contains('no-store')) return 0;
    final m = RegExp(r'max-age=(\d+)').firstMatch(cc);
    if (m == null) return 0;
    final age = int.parse(m.group(1)!);
    const cap = AppConfig.tileCacheHours * 3600;
    return age < cap ? age : cap;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final dir = request.method == 'GET' ? await _folder() : null;
    if (dir == null) return _inner.send(request);

    // The file's modified time is set to its expiry.
    final file = File('${dir.path}/${keyOf(request.url)}');
    try {
      if (await file.exists() &&
          (await file.lastModified()).isAfter(DateTime.now())) {
        final bytes = await file.readAsBytes();
        return http.StreamedResponse(
          Stream.value(bytes),
          200,
          contentLength: bytes.length,
          request: request,
        );
      }
    } catch (_) {
      // A broken cache file: fetch the tile again.
    }

    final res = await _inner.send(request);
    final keep = keepSeconds(res.headers['cache-control']);
    if (res.statusCode != 200 || keep <= 0) return res;
    final bytes = await res.stream.toBytes();
    try {
      await file.writeAsBytes(bytes, flush: true);
      await file.setLastModified(DateTime.now().add(Duration(seconds: keep)));
    } catch (_) {
      // Full disk or similar: serve the tile anyway.
    }
    return http.StreamedResponse(
      Stream.value(bytes),
      200,
      contentLength: bytes.length,
      headers: res.headers,
      request: request,
    );
  }

  /// Deletes expired tiles, then the oldest until the folder fits the cap.
  static Future<void> _prune(Directory d) async {
    try {
      final now = DateTime.now();
      final files = <(File, DateTime, int)>[];
      await for (final e in d.list()) {
        if (e is! File) continue;
        final st = await e.stat();
        if (!st.modified.isAfter(now)) {
          await e.delete();
        } else {
          files.add((e, st.modified, st.size));
        }
      }
      var total = files.fold<int>(0, (a, f) => a + f.$3);
      const cap = AppConfig.tileCacheMaxMb * 1024 * 1024;
      files.sort((a, b) => a.$2.compareTo(b.$2)); // soonest to expire first
      for (final f in files) {
        if (total <= cap) break;
        await f.$1.delete();
        total -= f.$3;
      }
    } catch (_) {
      // Pruning is best effort.
    }
  }

  @override
  void close() => _inner.close();
}
