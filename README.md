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

## Deployment, wiring, user guide

To be completed in Phases 4 and 7.
