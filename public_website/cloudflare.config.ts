import { defineConfig } from "cf/config"

export default defineConfig({
	worker: {
		name: "schublade-website",
		compatibilityDate: "2026-11-01",
		assets: { htmlHandling: "force-trailing-slash", notFoundHandling: "404-page" },
		domains: ["schublade.org"],
		previewUrls: false,
	},
})
