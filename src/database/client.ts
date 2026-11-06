import { env } from "cloudflare:workers"
import { drizzle } from "drizzle-orm/d1"
import * as schema from "./schema"

export function connectDatabase(binding: D1Database) {
	return drizzle(binding, { schema })
}

export type ArchiveDatabase = ReturnType<typeof connectDatabase>

// Server-only: cloudflare:workers does not exist in the browser bundle.
export const database = connectDatabase(env.DATABASE)
