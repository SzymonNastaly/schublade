// @ts-check

import { tanstackConfig } from "@tanstack/eslint-config"
import betterTailwindcss from "eslint-plugin-better-tailwindcss"

const classListLiterals = [{ match: "strings" }, { match: "objectValues" }]

export default [
	{ ignores: ["src/routeTree.gen.ts", ".cloudflare/", ".tanstack/", ".claude/worktrees/", "native_client/"] },
	...tanstackConfig,
	{
		files: ["src/interface/**/*.{ts,tsx}", "src/routes/**/*.{ts,tsx}"],
		plugins: { "better-tailwindcss": betterTailwindcss },
		settings: {
			"better-tailwindcss": {
				entryPoint: "src/styles.css",
				attributes: [["^className$", classListLiterals]],
				variables: [[".*(Classes|Cell|Row)$", classListLiterals]],
				callees: [],
			},
		},
		rules: { "better-tailwindcss/no-unknown-classes": "error" },
	},
	{
		files: ["src/**/*.{ts,tsx}", "scripts/**/*.ts"],
		rules: {
			"no-restricted-syntax": [
				"error",
				...[
					"Literal[value=/OR\\s+REPLACE|REPLACE\\s+INTO/i]",
					"TemplateElement[value.raw=/OR\\s+REPLACE|REPLACE\\s+INTO/i]",
				].map((selector) => ({
					selector,
					message:
						"REPLACE deletes the row it replaces without firing its delete trigger, because D1 runs with recursive_triggers off, so the change journal never records the deletion. Use INSERT ... ON CONFLICT DO UPDATE.",
				})),
			],
		},
	},
	{
		files: ["src/**/*.{ts,tsx}"],
		ignores: ["src/interface/controls/**"],
		rules: {
			"no-restricted-imports": [
				"error",
				{
					patterns: [
						{
							group: ["@base-ui/react", "@base-ui/react/*"],
							message: "Wrap a Base UI part in src/interface/controls, so its styling stays in one place.",
						},
					],
				},
			],
		},
	},
]
