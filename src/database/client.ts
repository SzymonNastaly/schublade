import { env } from "cloudflare:workers"
import { drizzle } from "drizzle-orm/d1"
import * as schema from "./schema"

// Server-only: cloudflare:workers does not exist in the browser bundle.
export const database = drizzle(env.DATABASE, { schema })
