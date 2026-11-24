# Hydro Sense

**Hydro Sense: IoT-Enabled Water Flow Monitoring and Tracking System.** Solar-powered ESP32
devices along a building's water supply line report whether the flow at each point is normal,
low or stopped, so a fault can be located: where along the line the water stops. Firebase Cloud
Functions keep the live state and the history of problems and send alerts by push notification,
SMS and email to everyone in the organization. Staff watch the live status, a pipeline map and the
History on an Android app; the building owner manages devices, staff and the pipeline on a
website.

## Repository layout

| Path | Contents |
|---|---|
| `firmware/` | ESP32 firmware (PlatformIO, Arduino framework, C++) |
| `functions/` | Firebase Cloud Functions, 2nd gen, Node 22, TypeScript |
| `app/` | Flutter project: the Android app for staff and the admin website |
| `firestore.rules`, `database.rules.json` | Security rules: active members read, only the admin and the functions write |
| `firebase.json`, `firestore.indexes.json` | Firebase project configuration |

## Hardware

ESP32 DevKit, a Hall-effect flow sensor (YF-S201, or a 2-inch ZJ-DN50 with firmware 0.4.0 or
later), 2S 18650 battery pack with a BMS, TP5100 charger, LM2596 buck converter (5 V), an on/off
switch and a 9 V solar panel.

## Building

* **Firmware:** copy `firmware/include/secrets.h.example` to `firmware/include/secrets.h`, fill
  it in, then run `pio run` in `firmware/` (`pio run -t upload` to flash, `pio test -e native` for
  the unit tests).
* **Cloud Functions:** `npm --prefix functions ci`, then `npm --prefix functions run build` and
  `npm --prefix functions test`. Secrets go in Google Secret Manager; see
  `functions/.env.example` and `functions/.secret.local.example`.
* **App:** `cd app && flutter pub get`, then `flutter run` (Android) or `flutter build web` (admin
  website; run `flutter clean` before a release web build). Build-time keys go in a copy of
  `app/dart_defines.example.json`.

Development and tests run on the Firebase Emulator Suite. No keys or passwords are stored in this
repository.

## Cost

The project runs on the Firebase Blaze plan and stays inside the free tier for a handful of
devices: live readings go to the Realtime Database (billed by download, not per write), alerts
are batched, locked for 6 hours and capped per person and per day, and alert SMS (prepaid) stop at
100 per day for the whole project. Set a Google Cloud budget alert of USD 1 to 5.

## Authors

A capstone project of Bachelor of Science in Information Technology students, Mountain Province
State University.
