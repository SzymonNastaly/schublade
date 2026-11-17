/// <reference types="vitest/config" />
import tailwindcss from "@tailwindcss/vite"
import react from "@vitejs/plugin-react"
import { defaultClientConditions, defineConfig } from "vite"

// `--mode stand_in` resolves `#collector_bridge` to fixed statuses for a plain browser; every other
// mode resolves it to the Tauri bridge, so the stand-in never reaches the application bundle.
export default defineConfig(({ mode }) => ({
	plugins: [react(), tailwindcss()],
	resolve: {
		conditions: mode === "stand_in" ? ["stand_in", ...defaultClientConditions] : [...defaultClientConditions],
	},
	clearScreen: false,
	server: { port: 1420, strictPort: true },
	build: { outDir: "distribution", target: "safari16" },
	test: { include: ["src/**/*.test.ts"], environment: "node" },
}))
