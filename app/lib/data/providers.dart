import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart' hide Pipeline;
import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config.dart';
import 'models.dart';
import 'pipeline.dart';
import 'push.dart';
import 'live_db.dart';
import 'repository.dart';

final authProvider = Provider<FirebaseAuth>((ref) => FirebaseAuth.instance);

/// True while a sign-out was asked for by the person, so the app can tell it
/// apart from an expired or revoked session ("Please sign in again.").
final explicitSignOutProvider = StateProvider<bool>((ref) => false);

Future<void> signOut(WidgetRef ref) async {
  ref.read(explicitSignOutProvider.notifier).state = true;
  // A user's phone stops getting alerts first: the rules allow this only while signed in.
  final uid = ref.read(authProvider).currentUser?.uid;
  if (uid != null && ref.read(roleProvider).valueOrNull == 'user') {
    await ref.read(pushServiceProvider).stop(uid);
  }
  await ref.read(authProvider).signOut();
}

final repositoryProvider = Provider<ClientRepository>(
  (ref) => FirestoreClientRepository(
    FirebaseFirestore.instance,
    liveDatabase(),
    FirebaseFunctions.instanceFor(region: AppConfig.functionsRegion),
  ),
);

/// The signed-in user (null when signed out).
final userProvider = StreamProvider<User?>(
  (ref) => ref.watch(authProvider).idTokenChanges(),
);

/// The signed-in user's uid (null when signed out). Screens use this, not
/// FirebaseAuth directly, so widget tests can stand in for a user.
final uidProvider = Provider<String?>(
  (ref) => ref.watch(userProvider).valueOrNull?.uid,
);

/// The `role` custom claim of the signed-in user.
///
/// Keyed by the uid, not the token: a password change or the hourly refresh
/// issues a new token, and reloading the role then would send the router
/// through /loading and close whatever dialog is open.
final roleProvider = FutureProvider<String?>((ref) async {
  if (ref.watch(uidProvider) == null) return null;
  final user = ref.read(userProvider).valueOrNull;
  if (user == null) return null;
  final saved = (await user.getIdTokenResult()).claims?['role'] as String?;
  if (!needsFreshRole(saved)) return saved;
  // A token saved before a role change (v1 "client" -> "user") is still valid
  // for up to an hour; ask Firebase for a fresh one before refusing anyone.
  final fresh = await user.getIdTokenResult(true);
  return fresh.claims?['role'] as String?;
});

/// Only the roles this app knows are trusted from a saved token.
bool needsFreshRole(String? role) => role != 'user' && role != 'admin';

/// A staff member's own record (null for an admin).
final profileProvider = StreamProvider<UserProfile?>((ref) {
  final uid = ref.watch(uidProvider);
  if (uid == null || ref.watch(isAdminProvider)) return Stream.value(null);
  return ref.watch(repositoryProvider).profile(uid);
});

/// Every device of the organization (D62), for any signed-in member.
final fleetProvider = StreamProvider<Fleet>((ref) {
  final uid = ref.watch(uidProvider);
  if (uid == null) return const Stream.empty();
  return ref.watch(repositoryProvider).fleet();
});

/// The organization's one pipeline.
final pipelineProvider = StreamProvider<Pipeline?>((ref) {
  final uid = ref.watch(uidProvider);
  if (uid == null) return Stream.value(null);
  return ref.watch(repositoryProvider).pipeline();
});

/// True for an admin: only admins change devices, limits, the pipeline and
/// History (D63). Staff see the same screens without those controls.
final isAdminProvider = Provider<bool>(
  (ref) => ref.watch(roleProvider).valueOrNull == 'admin',
);

/// True when the phone has no network connection at all.
final phoneOfflineProvider = StreamProvider<bool>((ref) async* {
  bool offline(List<ConnectivityResult> r) =>
      r.every((c) => c == ConnectivityResult.none);
  final c = Connectivity();
  yield offline(await c.checkConnectivity());
  yield* c.onConnectivityChanged.map(offline);
});

/// Ticks every 10 s so "Updated 12 s ago" lines stay fresh.
final clockProvider = StreamProvider<DateTime>((ref) async* {
  yield DateTime.now();
  yield* Stream.periodic(const Duration(seconds: 10), (_) => DateTime.now());
});
