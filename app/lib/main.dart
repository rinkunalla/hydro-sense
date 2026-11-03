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
      // Web = admin website, Android = client app (CLAUDE.md section 9).
      child: kIsWeb ? const AdminApp() : const HydroSenseApp(),
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
