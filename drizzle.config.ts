import { defineConfig } from "drizzle-kit"

// drizzle-kit only generates migrations. `cf d1 migrations apply` applies them.
export default defineConfig({
	schema: "./src/database/schema.ts",
	out: "./drizzle",
	dialect: "sqlite",
})
