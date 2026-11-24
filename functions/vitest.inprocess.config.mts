import { defineConfig } from "vitest/config";

// In-process tests (phase3): Auth and Firestore emulators only. The Functions
// emulator must NOT be running: its real triggers would race these tests.
export default defineConfig({
  test: {
    // Refuses to run without the emulator hosts (the tests wipe whole databases).
    setupFiles: ["test-emulator/emulatorsOnly.ts"],
    include: ["test-emulator/phase3.test.ts", "test-emulator/auth.test.ts"],
    testTimeout: 30000,
    hookTimeout: 30000,
    fileParallelism: false,
  },
});
