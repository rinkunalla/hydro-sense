import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

import '../core/config.dart';

/// The Realtime Database that holds each device's live node (D48). It is not
/// the project's default-location database, so it is opened by its URL.
FirebaseDatabase liveDatabase() => FirebaseDatabase.instanceFor(
  app: Firebase.app(),
  databaseURL: AppConfig.databaseUrl,
);
