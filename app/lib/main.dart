import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/config.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  if (AppConfig.useEmulator) await _useEmulators();
  runApp(
    ProviderScope(
      child: kIsWeb ? const _AdminComingSoon() : const HydroSenseApp(),
    ),
  );
}

Future<void> _useEmulators() async {
  final host = kIsWeb
      ? AppConfig.emulatorHostWeb
      : AppConfig.emulatorHostAndroid;
  await FirebaseAuth.instance.useAuthEmulator(host, AppConfig.authEmulatorPort);
  FirebaseFirestore.instance.useFirestoreEmulator(
    host,
    AppConfig.firestoreEmulatorPort,
  );
  FirebaseFunctions.instanceFor(
    region: AppConfig.functionsRegion,
  ).useFunctionsEmulator(host, AppConfig.functionsEmulatorPort);
}

/// The web build is the admin website (Phase 6).
class _AdminComingSoon extends StatelessWidget {
  const _AdminComingSoon();

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(
      body: Center(
        child: Text('Hydro Sense admin website: coming in Phase 6.'),
      ),
    ),
  );
}
