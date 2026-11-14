import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where a tapped push should open (D37): a single device opens its Details; a
/// batch opens the Map centred on the problem, or Devices when there is no
/// pipeline yet.
String routeForPush(Map<String, dynamic> data, {required bool hasPipeline}) {
  final id = data['deviceId'];
  if (id is String && RegExp(r'^[0-9A-F]{12}$').hasMatch(id)) {
    return '/devices/$id';
  }
  return hasPipeline ? '/map?focus=problem' : '/devices';
}

/// Push registration (CLAUDE.md section 4 `users/{uid}/push_tokens`). firebase_messaging
/// 17 sends to the Firebase Installation ID (FID); getToken() is deprecated.
abstract class PushService {
  /// Asks for notification permission (Android 13+), registers, and keeps the
  /// FID stored under the signed-in user.
  Future<void> start(String uid);

  /// Removes this phone's FID before sign-out, so alerts stop reaching it.
  Future<void> stop(String uid);

  /// Data of tapped notifications: the one that opened the app, then later taps.
  Stream<Map<String, dynamic>> taps();
}

class FcmPushService implements PushService {
  FcmPushService(this._db, this._messaging);

  final FirebaseFirestore _db;
  final FirebaseMessaging _messaging;
  final _subs = <StreamSubscription<Object?>>[];
  String? _fid;

  DocumentReference<Map<String, dynamic>> _doc(String uid, String fid) =>
      _db.doc('users/$uid/push_tokens/$fid');

  @override
  Future<void> start(String uid) async {
    await _cancel();
    _subs.add(
      _messaging.onRegistered.listen((fid) async {
        _fid = fid;
        await _doc(uid, fid).set({
          'platform': 'android',
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }),
    );
    _subs.add(
      _messaging.onUnregistered.listen((fid) async {
        if (_fid == fid) _fid = null;
        await _doc(uid, fid).delete();
      }),
    );
    try {
      await _messaging.requestPermission();
      await _messaging.register();
    } catch (_) {
      // No Play services or permission denied: SMS and email still work.
    }
  }

  @override
  Future<void> stop(String uid) async {
    final fid = _fid;
    await _cancel();
    if (fid != null) {
      try {
        await _doc(uid, fid).delete();
      } catch (_) {}
    }
    try {
      await _messaging.unregister();
    } catch (_) {}
  }

  Future<void> _cancel() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }

  @override
  Stream<Map<String, dynamic>> taps() async* {
    final first = await _messaging.getInitialMessage();
    if (first != null) yield first.data;
    yield* FirebaseMessaging.onMessageOpenedApp.map((m) => m.data);
  }
}

final pushServiceProvider = Provider<PushService>(
  (ref) =>
      FcmPushService(FirebaseFirestore.instance, FirebaseMessaging.instance),
);
