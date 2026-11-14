import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config.dart';
import 'models.dart';
import 'repository.dart';

final authProvider = Provider<FirebaseAuth>((ref) => FirebaseAuth.instance);

/// True while a sign-out was asked for by the person, so the app can tell it
/// apart from an expired or revoked session ("Please sign in again.").
final explicitSignOutProvider = StateProvider<bool>((ref) => false);

Future<void> signOut(WidgetRef ref) async {
  ref.read(explicitSignOutProvider.notifier).state = true;
  await ref.read(authProvider).signOut();
}

final repositoryProvider = Provider<ClientRepository>(
  (ref) => FirestoreClientRepository(
    FirebaseFirestore.instance,
    FirebaseFunctions.instanceFor(region: AppConfig.functionsRegion),
  ),
);

/// The signed-in user (null when signed out).
final userProvider = StreamProvider<User?>(
  (ref) => ref.watch(authProvider).idTokenChanges(),
);

/// The `role` custom claim of the signed-in user.
final roleProvider = FutureProvider<String?>((ref) async {
  final user = ref.watch(userProvider).valueOrNull;
  if (user == null) return null;
  final token = await user.getIdTokenResult();
  return token.claims?['role'] as String?;
});

final profileProvider = StreamProvider<UserProfile?>((ref) {
  final user = ref.watch(userProvider).valueOrNull;
  if (user == null) return Stream.value(null);
  return ref.watch(repositoryProvider).profile(user.uid);
});

final fleetProvider = StreamProvider<Fleet>((ref) {
  final user = ref.watch(userProvider).valueOrNull;
  if (user == null) return const Stream.empty();
  return ref.watch(repositoryProvider).fleet(user.uid);
});

final statusChangesProvider = StreamProvider.family<List<StatusChange>, String>(
  (ref, id) => ref.watch(repositoryProvider).statusChanges(id),
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
