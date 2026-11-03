# Hydro Sense

Private water **flow status** monitor for a single client: ESP32 devices report flow and battery
to Firebase; an Android app shows the client live status; an admin website shows device health.
The specification is `CLAUDE.md`, `KICKOFF.md` and `docs/`.

## Repo layout

| Path | Contents |
|---|---|
| `firmware/` | PlatformIO project for the ESP32 (`include/config.h`, `include/secrets.h.example`) |
| `functions/` | Cloud Functions, 2nd gen, Node 22, TypeScript (`src/config.ts`) |
| `app/` | Flutter app: Android build = client, web build = admin (`lib/core/config.dart`) |
| `tools/` | Admin seeding and the device simulator |
| `docs/` | UI/UX spec, error handling, hardware notes and schematic |

## Prerequisites

* Node 22 and the Firebase CLI (`npm i -g firebase-tools`)
* **JDK 21 or newer** for the Firebase emulators. You do not need to change system Java:
  `npm run emulators` (via `scripts/emulators.mjs`) uses `HYDROSENSE_JAVA_HOME` if set,
  otherwise Android Studio's bundled JDK (`C:\Program Files\Android\Android Studio\jbr`).
  Plain `firebase emulators:start` still uses the system Java and fails below 21.
* Flutter (stable) with Android tooling
* PlatformIO Core (the VS Code extension installs it at `~/.platformio/penv/Scripts/pio`)
* For `pio test -e native` (Phase 4): a host C++ compiler on `PATH` (for example MinGW-w64 g++)

## Setup

1. `npm --prefix functions install`
2. Copy `functions/.env.example` to `functions/.env.local` (emulator) and `functions/.env` (deploy).
3. Copy `functions/.secret.local.example` to `functions/.secret.local` for the emulator.
   In the real project, set each secret with `firebase functions:secrets:set <NAME>`.
4. Copy `firmware/include/secrets.h.example` to `firmware/include/secrets.h` and fill it in.

Never commit `.env`, `.env.local`, `.secret.local` or `secrets.h` (all gitignored).

**The emulator never sends real SMS or email and never calls Gemini.** It logs `sms_dry_run` /
`email_dry_run` instead, so simulator runs cannot spend Semaphore credits. To test real
delivery on the emulator, set `HYDROSENSE_REAL_PROVIDERS=1` in `functions/.env.local`.

## Everyday commands

| Task | Command |
|---|---|
| Start all emulators | `npm run emulators` (UI at http://localhost:4000) |
| Functions tests / lint | `npm --prefix functions test`, `npm --prefix functions run lint` |
| Firestore rules tests | `npm run test:rules` (starts the Firestore emulator, runs `functions/test-rules`) |
| API integration tests | `npm run test:emulator` (Auth, Firestore, Functions emulators; `functions/test-emulator`) |
| Device simulator | `npm run simulate:emulator` (3 devices, 150 s), or `npm run simulate -- [options]` against already running emulators (options at the top of `tools/simulate-device.ts`) |
| Deploy rules and indexes | `firebase deploy --only firestore` |
| App analyze / tests | `cd app && flutter analyze && flutter test` |
| Firmware build | `cd firmware && pio run` |
| Firmware logic tests | `cd firmware && pio test -e native` |

## Firebase project

One project, `hydro-sense-dc836` (Blaze, Firestore `asia-east1`), alias `default`. Development runs
on the emulators; the real project is for short deploy checks, user testing and the client.

## Cost

To be completed in Phase 7: writes and reads per device per day, the free-tier limits, and the
Google Cloud budget alert (CLAUDE.md section 8).

## Client app (Android)

Debug builds use the emulators by default; release builds use the real project
(`--dart-define=USE_EMULATOR=false` points a debug build at the real project).

1. `npm run emulators` (leave running), then `npm run seed:emulator` once. It creates
   `client@hydrosense.test` / `hydrosense-dev` (and `admin@hydrosense.test`). Add `--temp`
   (`npm run seed:emulator -- --temp`) to test the temporary-password flow.
2. `npm run simulate -- --devices 3 --duration 600 --heartbeat 10` feeds live devices.
   In PowerShell, quote the separator so npm passes the options through:
   `npm run simulate '--' --devices 3 --duration 600 --heartbeat 10` (or call
   `node --experimental-strip-types tools/simulate-device.ts --devices 3 ...` directly).
3. `cd app && flutter run` on the Android emulator (it reaches the host at `10.0.2.2`).

Tests: `cd app && flutter test` (contrast of every color pair, fleet logic, router redirects,
Devices screen states with 1, 3 and 10 devices, 1.5x text at 360 dp).

**Android build notes (learned in Phase 5)**

* The build downloads Android and Firebase libraries from `dl.google.com`; that host must not be
  blocked (for example by a Windows Name Resolution Policy rule that blocks browser updates).
* On a machine with about 8 GB of RAM, build with the Android emulator closed, then install:
  `flutter build apk --debug`, start the emulator, then
  `adb install -r build/app/outputs/flutter-apk/app-debug.apk`. Gradle is capped at 2 GB in
  `android/gradle.properties`; stop idle daemons afterwards with `android\gradlew --stop`.
* Kotlin Gradle plugin 2.3.21 (in `android/settings.gradle.kts`) is needed because firebase-auth 25
  ships Kotlin 2.4 metadata; Kotlin 2.3 also requires the `compilerOptions` DSL used in
  `android/app/build.gradle.kts`.
* Debug builds may use plain HTTP only to the emulator hosts (`10.0.2.2`, `localhost`,
  `127.0.0.1`), via `android/app/src/debug/res/xml/network_security_config.xml`. Release builds are
  HTTPS-only.

Admins: `npm run create-admin -- --email you@example.com` (real project: prints a
password-setup link) or add `--emulator`.

## Firmware

| Task | Command |
|---|---|
| Build | `npm run fw:build` |
| Logic tests (host) | `npm run fw:test` (uses `~/mingw64/bin/g++` or `HYDROSENSE_MINGW_BIN`; see `scripts/pio.mjs`) |
| Flash over USB | `npm run fw:upload` |
| Serial monitor (115200) | `npm run fw:monitor` |

Toolchain: PlatformIO `espressif32@7.1.3` (Arduino-ESP32 core 2.0.17), C++17, `huge_app.csv`
partition (no OTA in v1). Libraries: ArduinoJson 7.4.3, TinyGPSPlus 1.1.0, WiFiManager 2.0.17.
TLS trusts only the Google roots in `firmware/include/google_roots.h` (regenerate from
`https://pki.goog/repo/certs/` if Google rotates roots).

### Before the first flash

1. Do the three wiring checks in `docs/hardware/NOTES.md` and record them in the bench log.
2. Create `firmware/include/secrets.h` (gitignored) from `secrets.h.example`. Set `PROVISIONING_KEY`
   to the real key: `firebase functions:secrets:access PROVISIONING_KEY`. Without `secrets.h` the
   build still succeeds (with a warning) but the device cannot register.
3. Add the device ID to the allowlist. Until the admin website exists (Phase 6), create the
   document by hand: Firebase console → Firestore → collection `allowed_devices` → document ID =
   the 12-character device ID (see "Reading the device ID") → one field `addedAt` (timestamp, now).

### Manual tests

**Reading the device ID.** Connect USB, run `npm run fw:monitor`, press EN (reset). The first lines
show `Hydro Sense 0.1.0  Device ID: A1B2C3D4E5F6`. The setup portal page shows the same ID.

**Captive portal (first boot, or after a BOOT reset).**
1. Power the device with no saved Wi-Fi. The onboard LED blinks fast (4 times a second).
2. On a phone, join the Wi-Fi network `HydroSense-XXXX` (the last 4 characters of the device ID).
   The setup page opens by itself; if not, browse to `http://192.168.4.1`.
3. Check the page shows "Device ID: …". Tap **Configure WiFi**, pick the network, enter the password, **Save**.
4. The LED blinks slowly while connecting, then stays on. The serial log shows `Registered`
   (first time) or `Token loaded from NVS`, and the device appears in Firestore within about a minute.
5. Portal timeout: leave the portal untouched for 10 minutes. The device reboots and retries the saved Wi-Fi.

**BOOT reset (clear Wi-Fi).**
1. With the device running (LED solid), hold the BOOT button for 5 seconds. Do not hold it while
   powering on: that enters the bootloader instead.
2. The serial log shows `BOOT held: clearing Wi-Fi settings` and the device restarts into the portal (step 1 above).

**LED meanings.** Solid: connected and uploading. Slow blink (1 Hz): connecting to Wi-Fi. Fast blink
(4 Hz): setup hotspot active. Two quick blinks every 3 s: the server is rejecting the device (for
example not on the allowlist, or removed by the admin).

## Deployment, wiring, user guide

To be completed in Phase 7.
