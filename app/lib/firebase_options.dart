// Firebase app settings for hydro-sense-dc836 (generated from irebase apps:sdkconfig).
// These identify the project; they are not secrets. Access is enforced by
// firestore.rules and the callables' role checks.
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

abstract final class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    if (defaultTargetPlatform == TargetPlatform.android) return android;
    throw UnsupportedError(
      'Hydro Sense supports Android (client) and web (admin) only.',
    );
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyCNUKCgBWhKnJUAzRrx-KwxRcyIN7mNmsI',
    appId: '1:970164731577:android:b47d30385ad4ba6e0ae568',
    messagingSenderId: '970164731577',
    projectId: 'hydro-sense-dc836',
    storageBucket: 'hydro-sense-dc836.firebasestorage.app',
  );

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyAC2b806A6mdi5Ufm3lSRTKHYon3k145p8',
    appId: '1:970164731577:web:3c24aee995c55f710ae568',
    messagingSenderId: '970164731577',
    projectId: 'hydro-sense-dc836',
    authDomain: 'hydro-sense-dc836.firebaseapp.com',
    storageBucket: 'hydro-sense-dc836.firebasestorage.app',
  );
}
