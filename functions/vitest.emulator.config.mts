import { defineConfig } from "vitest/config";

// Integration tests; need the Auth, Firestore and Functions emulators running.
export default defineConfig({
  test: {
    include: ["test-emulator/**/*.test.ts"],
    testTimeout: 30000,
    hookTimeout: 30000,
    fileParallelism: false,
  },
});
