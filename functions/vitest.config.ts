import { defineConfig } from "vitest/config";

// Unit tests only; rules tests need the emulator (vitest.rules.config.ts).
export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
  },
});
