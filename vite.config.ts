import { cloudflare } from "@cloudflare/vite-plugin"
import tailwindcss from "@tailwindcss/vite"
import { tanstackStart } from "@tanstack/react-start/plugin/vite"
import viteReact from "@vitejs/plugin-react"
import { defineConfig } from "vite"

export default defineConfig({
	// `cf dev` forwards only `--mode` to Vite, so the port is set here.
	server: { port: 3000 },
	resolve: { tsconfigPaths: true },
	plugins: [cloudflare({ viteEnvironment: { name: "ssr" } }), tailwindcss(), tanstackStart(), viteReact()],
	environments: {
		// `cf deploy` uploads the Worker source maps for readable stack traces.
		ssr: { build: { sourcemap: true } },
	},
})
