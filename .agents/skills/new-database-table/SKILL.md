---
name: new-database-table
description: >
  Adds or changes a D1 table, column, or index in Schublade with Drizzle ORM.
  Use when a task asks to add a table, add or rename a column, store new data
  in D1, change src/database/schema.ts, or write a D1 migration. Covers the
  column conventions, drizzle-zod insert schemas, generating the migration
  with drizzle-kit, applying it with cf, and testing a query in workerd.
---

# Add or change a database table

`src/database/schema.ts` holds every table. `drizzle-kit` generates SQL into `drizzle/`, and `cf d1 migrations apply` applies it. Never run `drizzle-kit push` or `drizzle-kit migrate`.

## 1. Define the table

Add the table to `src/database/schema.ts`. Follow the conventions of the existing tables:

- Name tables and columns in snake_case with full words, per the naming specification in AGENTS.md. TypeScript keys are the camelCase form of the column name.
- Use `identifier()` for the primary key. It is a text column filled with `crypto.randomUUID()`.
- Use `creationTime()` for `created_at`. Other timestamps are `integer(..., { mode: "timestamp" })`.
- Store calendar dates as ISO 8601 text, such as `2026-10-05`.
- Store a closed set of values as `text(..., { enum: values })`, with `values` declared `as const` in the same file.
- Store JSON in a column whose name ends in `_json`, declared `text(..., { mode: "json" }).$type<T>()`.
- Name every index `<table>_<columns>_index`.
- D1 is SQLite. Use `text`, `integer`, `real`, and `blob` from `drizzle-orm/sqlite-core`, never PostgreSQL types.

## 2. Add the insert schema

Every table has an insert schema built with `createInsertSchema` from `drizzle-zod`, exported as `<entity>InsertSchema`. Omit the columns the database or the Worker assigns, such as `id` and `createdAt`, and refine the columns that need it:

```ts
export const senderInsertSchema = createInsertSchema(senders, {
	name: (schema) => schema.trim().min(1),
}).omit(managedColumns)
```

Parse every request body, model output, or other external input with `safeParse` against the insert schema before it reaches the database. Do not parse rows that Drizzle reads back.

## 3. Generate and apply the migration

```bash
pnpm database:generate --name <description_in_snake_case>
pnpm database:migrate:local
```

Read the generated SQL in `drizzle/` before you commit it. Check that the change landed in the local database:

```bash
cf d1 raw 00000000-0000-4000-8000-000000000000 --local --persist-to .cloudflare/state \
	--sql "select name from sqlite_master where type = 'table'"
```

The remote databases receive migrations through `cf d1 migrations apply <DATABASE_ID> --dir drizzle` without `--local`. Run that only when the user asks, with the identifier from `schublade.deploy.json`.

## 4. Query the table

Import `database` from `src/database/client.ts` in a server function or in other server-only code:

```ts
import { asc } from "drizzle-orm"
import { database } from "../database/client"
import { senders } from "../database/schema"

const rows = await database.select().from(senders).orderBy(asc(senders.normalizedName))
```

`client.ts` imports `cloudflare:workers`, so never import it from a component.

## 5. Test a query that needs D1

Test a query in the workerd project only when it carries logic, such as an authorization scope predicate. Add the binding and the migrations to the workerd project in `vitest.config.ts`:

```ts
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin"

cloudflareTest(async () => ({
	remoteBindings: false,
	miniflare: {
		compatibilityDate: "2026-11-01",
		compatibilityFlags: ["nodejs_compat"],
		d1Databases: ["DATABASE"],
		bindings: { DATABASE_MIGRATIONS: await readD1Migrations("drizzle") },
		modulesRules: [...],
	},
}))
```

Apply `DATABASE_MIGRATIONS` with `applyD1Migrations` from `cloudflare:test` before the first query, name the file `*.workerd.test.ts`, and assert literal rows. Read the current `@cloudflare/vitest-plugin` types before you rely on this shape.

## 6. Verify

```bash
pnpm database:generate   # prints "No schema changes" when the migration matches the schema
pnpm check
```

Commit the schema change and the generated files in `drizzle/` together.
