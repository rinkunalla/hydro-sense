import { defineConfig } from "vitest/config";

// Integration tests; need the Auth, Firestore and Functions emulators running.
export default defineConfig({
  test: {
    // Refuses to run without the emulator hosts (the tests wipe whole databases).
    setupFiles: ["test-emulator/emulatorsOnly.ts"],
    // Endpoint tests against the Functions emulator; phase3 runs separately
    // (vitest.inprocess.config.mts) without it.
    include: ["test-emulator/device-api.test.ts"],
    testTimeout: 30000,
    hookTimeout: 30000,
    fileParallelism: false,
  },
});
