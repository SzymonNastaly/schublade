import { cloudflareTest } from "@cloudflare/vitest-plugin"
import { defineConfig } from "vitest/config"

export default defineConfig({
	test: {
		projects: [
			{
				test: {
					name: "node",
					include: ["src/**/*.test.ts"],
					exclude: ["src/**/*.workerd.test.ts"],
					environment: "node",
				},
			},
			{
				plugins: [
					cloudflareTest({
						// Tests never reach Workers AI, Browser Run, or AI Search, which bill per request.
						remoteBindings: false,
						miniflare: {
							compatibilityDate: "2026-11-01",
							compatibilityFlags: ["nodejs_compat"],
							modulesRules: [
								{ type: "CompiledWasm", include: ["**/*.wasm?module"] },
								{ type: "Data", include: ["**/*.pdf"] },
							],
						},
					}),
				],
				test: {
					name: "workerd",
					include: ["src/**/*.workerd.test.ts"],
				},
			},
		],
	},
})
