// @ts-check

import { tanstackConfig } from "@tanstack/eslint-config"
import betterTailwindcss from "eslint-plugin-better-tailwindcss"

const classListLiterals = [{ match: "strings" }, { match: "objectValues" }]

export default [
	{ ignores: ["distribution/"] },
	...tanstackConfig,
	{
		files: ["src/**/*.{ts,tsx}"],
		plugins: { "better-tailwindcss": betterTailwindcss },
		settings: {
			"better-tailwindcss": {
				entryPoint: "src/styles.css",
				attributes: [["^className$", classListLiterals]],
				variables: [[".*Classes$", classListLiterals]],
				callees: [],
			},
		},
		rules: { "better-tailwindcss/no-unknown-classes": "error" },
	},
]
