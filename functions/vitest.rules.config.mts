import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Refuses to run without the emulator hosts (the tests wipe whole databases).
    setupFiles: ["test-emulator/emulatorsOnly.ts"],
    include: ["test-rules/**/*.test.ts"],
    testTimeout: 20000,
    hookTimeout: 30000,
    fileParallelism: false,
  },
});
