import { defineConfig } from "vitest/config"

export default defineConfig({
	test: {
		projects: [
			{
				test: {
					name: "node",
					include: ["src/**/*.test.ts"],
					environment: "node",
				},
			},
		],
	},
})
