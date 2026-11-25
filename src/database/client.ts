import { env } from "cloudflare:workers"
import { drizzle } from "drizzle-orm/d1"
import * as schema from "./schema"

const createConnection = (binding: D1Database) => drizzle(binding, { schema })

export type ArchiveDatabase = ReturnType<typeof createConnection>

// Drizzle keeps no request state, so one connection per binding serves every request of the isolate.
// A Map, because the binding that cloudflare:workers hands the module scope at deploy validation is
// no valid WeakMap key there, and Cloudflare refused the upload (2026-11-25).
const connections = new Map<D1Database, ArchiveDatabase>()

export function connectDatabase(binding: D1Database): ArchiveDatabase {
	let connection = connections.get(binding)
	if (connection === undefined) {
		connection = createConnection(binding)
		connections.set(binding, connection)
	}
	return connection
}

// Server-only: cloudflare:workers does not exist in the browser bundle.
export const database = connectDatabase(env.DATABASE)
