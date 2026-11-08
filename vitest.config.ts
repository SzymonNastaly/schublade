import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin"
import { defineConfig } from "vitest/config"
import type { D1Migration } from "@cloudflare/vitest-plugin"

declare module "vitest" {
	interface ProvidedContext {
		databaseMigrations: Array<D1Migration>
	}
}

export default defineConfig({
	test: {
		projects: [
			{
				test: {
					name: "node",
					include: ["src/**/*.test.ts", "scripts/**/*.test.ts"],
					exclude: ["src/**/*.workerd.test.ts"],
					environment: "node",
				},
			},
			{
				plugins: [
					cloudflareTest({
						// Tests never reach Workers AI, Browser Run, or AI Search, which bill per request.
						remoteBindings: false,
						main: "./src/durable_objects/archive_coordinator.ts",
						miniflare: {
							compatibilityDate: "2026-11-01",
							compatibilityFlags: ["nodejs_compat"],
							modulesRules: [
								{ type: "CompiledWasm", include: ["**/*.wasm?module"] },
								{ type: "Data", include: ["**/*.pdf"] },
							],
							d1Databases: ["DATABASE"],
							r2Buckets: ["DOCUMENT_STORAGE"],
							kvNamespaces: ["OAUTH_KV"],
							durableObjects: { ARCHIVE_COORDINATOR: { className: "ArchiveCoordinator", useSQLite: true } },
						},
					}),
				],
				test: {
					name: "workerd",
					include: ["src/**/*.workerd.test.ts"],
					provide: { databaseMigrations: await readD1Migrations("drizzle") },
				},
			},
		],
	},
})
