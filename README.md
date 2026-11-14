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
| `docs/` | UI/UX spec, error handling, hardware notes and schematic, plus the guides below |
| `scripts/` | Launchers that supply JDK 21 (emulators) and MinGW g++ (firmware tests) |

Guides: [Deployment](docs/DEPLOYMENT.md) · [User guide](docs/USER_GUIDE.md) ·
[Wiring and parts](docs/hardware/WIRING.md) · [Hardware notes and bench log](docs/hardware/NOTES.md) ·
[Final report](docs/FINAL_REPORT.md)

## Prerequisites

* Node 22 and the Firebase CLI (`npm i -g firebase-tools`)
* **JDK 21 or newer** for the Firebase emulators. You do not need to change system Java:
  `npm run emulators` (via `scripts/emulators.mjs`) uses `HYDROSENSE_JAVA_HOME` if set,
  otherwise Android Studio's bundled JDK (`C:\Program Files\Android\Android Studio\jbr`).
  Plain `firebase emulators:start` still uses the system Java and fails below 21.
* Flutter (stable) with Android tooling
* PlatformIO Core (the VS Code extension installs it at `~/.platformio/penv/Scripts/pio`)
* For the firmware logic tests: a host C++ compiler. `npm run fw:test` uses
  `HYDROSENSE_MINGW_BIN` if set, otherwise a portable WinLibs MinGW-w64 in `~/mingw64/bin`, otherwise
  `g++` on `PATH`.

## Setup

1. `npm --prefix functions ci`
2. `cd app && flutter pub get`
3. Copy `functions/.env.example` to `functions/.env.local` (emulator) and `functions/.env` (deploy).
4. Copy `functions/.secret.local.example` to `functions/.secret.local` for the emulator; only
   `PROVISIONING_KEY` must be set (any random string). The real project uses Secret Manager
   ([Deployment](docs/DEPLOYMENT.md#2-secrets-secret-manager)).
5. For a real device: copy `firmware/include/secrets.h.example` to `firmware/include/secrets.h` and
   fill it in. The firmware builds without it, but the device cannot register.

Then check everything works: `npm --prefix functions test`, `npm run test:rules`,
`npm run test:emulator`, `cd app && flutter test`, `npm run fw:test`, `npm run fw:build`.

Never commit `.env`, `.env.local`, `.secret.local` or `secrets.h` (all gitignored).

**The emulator never sends real SMS or email.** It logs `sms_dry_run` /
`email_dry_run` instead, so simulator runs cannot spend Semaphore credits. To test real
delivery on the emulator, set `HYDROSENSE_REAL_PROVIDERS=1` in `functions/.env.local`.

## Everyday commands

| Task | Command |
|---|---|
| Start all emulators | `npm run emulators` (UI at http://localhost:4000) |
| Functions tests / lint | `npm --prefix functions test`, `npm --prefix functions run lint` |
| Firestore rules tests | `npm run test:rules` (starts the Firestore emulator, runs `functions/test-rules`) |
| API integration tests | `npm run test:emulator`: endpoint tests with the Functions emulator (`test:endpoints`), then the in-process alert/calibration/admin tests with Auth + Firestore only (`test:inprocess`, so real triggers cannot race them) |
| Device simulator | `npm run simulate:emulator` (3 devices, 150 s), or `npm run simulate -- [options]` against already running emulators (options at the top of `tools/simulate-device.ts`) |
| Deploy rules and indexes | `firebase deploy --only firestore` |
| App analyze / tests | `cd app && flutter analyze && flutter test` |
| Firmware build | `npm run fw:build` |
| Firmware logic tests | `npm run fw:test` |

## Firebase project

One project, `hydro-sense-dc836` (Blaze, Firestore `asia-east1`), alias `default`. Development runs
on the emulators; the real project is for short deploy checks, user testing and the client.

## Cost

Blaze plan, pay as you go. Normal use of a few devices stays inside the free tier; the project
has a **USD 1 budget alert** (Google Cloud console -> Billing -> Budgets & alerts), which warns but
does not stop spending.

| Item | Per device per day | Free tier (per day unless noted) | Fits about |
|---|---|---|---|
| Firestore writes | about 2,000: 1,440 `device_health` (one per 60 s heartbeat), up to 288 `devices`, 288 `flow_logs`; a status change costs about 3 | 20,000 | **10 devices** (the binding limit) |
| Firestore reads | about 2,900 from `monitorDevices` (2 docs per device per minute, plus `alert_state` only for active faults), plus one read per open app listener per write | 50,000 | 15 devices |
| Function invocations | about 1,440 `deviceIngest` + about 300 trigger runs that return at once | 2 million per month | about 40 devices |
| Scheduler jobs | 2 (`monitorDevices` every minute, weekly calibration) | 3 per billing account | |
| Secret Manager | 4 secrets | 6 active versions per billing account | destroy old versions after rotating |
| SMS | at most 10 per day (daily cap), batched | Semaphore prepaid credits | 1 credit per 160-character SMS |
| Hosting, Storage | admin site only, a few MB | 10 GB storage, 360 MB/day transfer | |

Notes: build images are deleted after a day (Artifact Registry cleanup policy, set on the first
functions deploy). Past about 10 devices, Firestore writes become a few cents a month; the biggest
lever is the 60 s heartbeat (`HEARTBEAT_S`, must stay under 90 for the 3 min offline limit).

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

## Admin website (Flutter web)

* Dev against the emulators: `npm run emulators`, `npm run seed:emulator`, then
  `cd app && flutter build web --dart-define=USE_EMULATOR=true`; the Hosting emulator serves it at
  http://127.0.0.1:5000. Sign in as `admin@hydrosense.test` / `hydrosense-dev`.
  (`flutter run -d chrome` also works and uses the emulators in debug.)
* Production build: `cd app && flutter build web` (release, real project), then
  `firebase deploy --only hosting:admin`. Create real admins with `npm run create-admin -- --email ...`.
* Privacy: the admin site reads only `device_health`, `allowed_devices` and `config/system`
  (stage 2 narrows this to D24). `app/test/admin_privacy_test.dart` fails if admin code names
  `devices` or `flow_logs`, and the Firestore rules deny those reads to admins anyway.
* `error_logs` have no page: read them in the Firebase console (D29).

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

* [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md): project setup, secrets, deploy commands, accounts,
  going live.
* [docs/USER_GUIDE.md](docs/USER_GUIDE.md): for the client (screens, alerts, Wi-Fi setup, BOOT
  reset, troubleshooting).
* [docs/hardware/WIRING.md](docs/hardware/WIRING.md): parts list and connections.
* Firmware updates need a site visit with USB: there are no over-the-air updates in v1.
