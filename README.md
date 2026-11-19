# Hydro Sense

**Hydro Sense: IoT-Enabled Water Flow Monitoring and Tracking System.** Solar-powered ESP32
devices measure the water flow along a supply line and report whether it is normal, low or
stopped. Firebase Cloud Functions store the readings and send alerts by push notification, SMS
and email. An Android app shows each user the live status of their own devices, a pipeline map
and a history of problems; an admin website manages users and devices.

## Repository layout

| Path | Contents |
|---|---|
| `firmware/` | ESP32 firmware (PlatformIO, Arduino framework, C++) |
| `functions/` | Firebase Cloud Functions, 2nd gen, Node 22, TypeScript |
| `app/` | Flutter project: the Android app for users and the web admin portal |
| `firestore.rules`, `database.rules.json` | Security rules: each user reads only their own devices |
| `firebase.json`, `firestore.indexes.json` | Firebase project configuration |

## Hardware

ESP32 DevKit, YF-S201 Hall-effect flow sensor, 2S 18650 battery pack with a BMS, TP5100
charger, LM2596 buck converter (5 V) and a 9 V solar panel.

## Building

* **Firmware:** copy `firmware/include/secrets.h.example` to `firmware/include/secrets.h`, fill
  it in, then run `pio run` in `firmware/` (`pio run -t upload` to flash).
* **Cloud Functions:** `npm --prefix functions ci`, then `npm --prefix functions run build` and
  `npm --prefix functions test`. Secrets go in Google Secret Manager; see
  `functions/.env.example` and `functions/.secret.local.example`.
* **App:** `cd app && flutter pub get`, then `flutter run` (Android) or
  `flutter build web` (admin portal). Build-time keys go in a copy of
  `app/dart_defines.example.json`.

No keys or passwords are stored in this repository.

## Authors

A capstone project of Bachelor of Science in Information Technology students, Mountain Province
State University.
