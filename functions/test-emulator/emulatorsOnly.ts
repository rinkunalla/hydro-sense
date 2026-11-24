// Loaded before every emulator test file (setupFiles in the vitest emulator,
// in-process and rules configs). These tests wipe whole databases between
// cases (Firestore documents, Auth accounts, the Realtime Database root), so
// without the emulator hosts the Admin SDK would reach the real project with
// the machine's Google credentials. Fail closed instead. Start the suites with
// the root `npm run test:rules`, `test:endpoints` or `test:inprocess`, which
// start the emulators and set these variables.
const missing = ["FIRESTORE_EMULATOR_HOST", "FIREBASE_DATABASE_EMULATOR_HOST"].filter(
  (v) => !process.env[v],
);

if (missing.length > 0) {
  throw new Error(
    `Emulator tests only: ${missing.join(", ")} not set. Run them with the root ` +
      "`npm run test:rules`, `npm run test:endpoints` or `npm run test:inprocess`.",
  );
}

// The rules suite starts no Auth emulator. A suite that needs one and does not
// get it then fails here on this machine instead of reaching the real accounts.
process.env.FIREBASE_AUTH_EMULATOR_HOST ??= "127.0.0.1:1";
