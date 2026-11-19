import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'app.dart';
import 'core/config.dart';
import 'data/live_db.dart';
import 'firebase_options.dart';

Future<void> main() async {
  // Admin website: plain paths (/setup?token=...) so emailed links open the
  // right page; Hosting rewrites every path to index.html.
  if (kIsWeb) usePathUrlStrategy();
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  if (AppConfig.useEmulator) await _useEmulators();
  if (kIsWeb) {
    // Admin website: the sign-in lasts only for this tab (a reload keeps it);
    // closing the tab or the browser signs the admin out, so a session is
    // never left open on a shared computer. Web only; the phone app keeps
    // its session so alerts keep arriving.
    await FirebaseAuth.instance.setPersistence(Persistence.SESSION);
  }
  // Phone app: every fresh start asks for the password again. The
  // phone stays registered for alerts (signing out here doesn't remove it);
  // only Sign out on the Account tab stops them.
  if (!kIsWeb && FirebaseAuth.instance.currentUser != null) {
    await FirebaseAuth.instance.signOut();
  }
  runApp(
    ProviderScope(
      // Web = admin website, Android = client app.
      child: kIsWeb ? const AdminApp() : const HydroSenseApp(),
    ),
  );
}

Future<void> _useEmulators() async {
  final host = kIsWeb
      ? AppConfig.emulatorHostWeb
      : AppConfig.emulatorHostAndroid;
  // The plugins turn 127.0.0.1 into the Android emulator's 10.0.2.2; a real
  // phone on USB (EMULATOR_HOST given, with adb reverse) must keep it.
  const map = !bool.hasEnvironment('EMULATOR_HOST');
  await FirebaseAuth.instance.useAuthEmulator(
    host,
    AppConfig.authEmulatorPort,
    automaticHostMapping: map,
  );
  FirebaseFirestore.instance.useFirestoreEmulator(
    host,
    AppConfig.firestoreEmulatorPort,
    automaticHostMapping: map,
  );
  FirebaseFunctions.instanceFor(
    region: AppConfig.functionsRegion,
  ).useFunctionsEmulator(
    host,
    AppConfig.functionsEmulatorPort,
    automaticHostMapping: map,
  );
  liveDatabase().useDatabaseEmulator(
    host,
    AppConfig.databaseEmulatorPort,
    automaticHostMapping: map,
  );
}
