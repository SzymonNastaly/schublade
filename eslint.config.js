// @ts-check

import { tanstackConfig } from "@tanstack/eslint-config"
import betterTailwindcss from "eslint-plugin-better-tailwindcss"

const classListLiterals = [{ match: "strings" }, { match: "objectValues" }]

export default [
	{ ignores: ["src/routeTree.gen.ts", ".cloudflare/", ".tanstack/", ".claude/worktrees/"] },
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
