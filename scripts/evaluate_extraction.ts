import { execFile } from "node:child_process"
import { readFile } from "node:fs/promises"
import { parseArgs, promisify } from "node:util"
import { z } from "zod"
import { normalizeTaxonomyName } from "../src/ingestion/taxonomy_resolution.ts"

// Uploads every test document to a running `VITE_ACCESS_DEVELOPMENT_EXEMPTION=true pnpm dev`
// server, waits until each is archived or failed, and compares the result with
// test_fixtures/documents/expected_extraction.json. The dev server calls the real,
// billed Workers AI models.

const commandLine = process.argv.slice(2)
// `pnpm evaluate:extraction -- --gateway-id …` passes the separator through to the script.
const { values: options } = parseArgs({
	args: commandLine[0] === "--" ? commandLine.slice(1) : commandLine,
	options: {
		"base-url": { type: "string", default: "http://localhost:3000" },
		"gateway-id": { type: "string" },
		"timeout-minutes": { type: "string", default: "20" },
	},
})
const baseUrl = options["base-url"]
const explorerUrl = `${baseUrl}/cdn-cgi/local/explorer/api`
// Keep equal to LOCAL_DATABASE_IDENTIFIER and the Workflow name in cloudflare.config.ts.
const localDatabaseIdentifier = "00000000-0000-4000-8000-000000000000"
// Local development always runs as schublade-development, see LOCAL_WORKER_NAME in cloudflare.config.ts.
const workflowName = "schublade-development-document-ingestion"
const fixtureDirectory = new URL("../test_fixtures/documents/", import.meta.url)

const expectedFieldSchema = z.object({ value: z.union([z.string(), z.number()]) })
const expectationSchema = z.object({
	household_members: z.array(z.string()),
	documents: z.array(
		z.object({
			file_name: z.string(),
			media_type: z.string(),
			category: z.string(),
			sender: z.string(),
			person: z.string(),
			document_date: z.string(),
			fields: z.record(z.string(), expectedFieldSchema),
		}),
	),
})
type ExpectedDocument = z.infer<typeof expectationSchema>["documents"][number]

const listedDocumentSchema = z.object({
	id: z.string(),
	status: z.string(),
	documentDate: z.string().nullable(),
	senderName: z.string().nullable(),
	categoryName: z.string().nullable(),
	personName: z.string().nullable(),
	fields: z.array(z.object({ fieldKey: z.string(), value: z.union([z.string(), z.number()]).nullable() })),
})
type ListedDocument = z.infer<typeof listedDocumentSchema>

const uploadResponseSchema = z.object({
	outcomes: z.array(
		z.discriminatedUnion("kind", [
			z.object({ kind: z.literal("accepted"), fileName: z.string(), documentId: z.string() }),
			z.object({ kind: z.literal("rejected"), fileName: z.string(), reason: z.string() }),
			z.object({ kind: z.literal("failed"), fileName: z.string(), reason: z.string() }),
		]),
	),
})

const workflowInstanceSchema = z.object({
	result: z.object({
		output: z.object({ classificationModel: z.string(), recognizedPageCount: z.number() }).nullable().optional(),
		error: z.object({ message: z.string() }).nullable().optional(),
		steps: z.array(z.object({ name: z.string(), start: z.string().nullable(), end: z.string().nullable() })).optional(),
	}),
})

const gatewayLogSchema = z.array(
	z.object({ created_at: z.string(), model: z.string(), cost: z.number().nullable(), success: z.boolean() }),
)

type Comparison = "match" | "mismatch" | "unscored"
type ScoredValue = string | number

const fieldComparators: Record<string, (expected: ScoredValue, actual: ScoredValue | null) => boolean> = {
	category: (expected, actual) =>
		actual !== null && normalizeTaxonomyName(String(actual)) === normalizeTaxonomyName(String(expected)),
	sender: (expected, actual) =>
		actual !== null && normalizeTaxonomyName(String(actual)) === normalizeTaxonomyName(String(expected)),
	person: (expected, actual) => actual === expected,
	document_date: (expected, actual) => actual === expected,
	amount: (expected, actual) => typeof actual === "number" && Math.abs(actual - Number(expected)) < 0.005,
	currency: (expected, actual) => actual === expected,
	iban: (expected, actual) => String(actual).replace(/\s+/g, "").toUpperCase() === expected,
	invoice_number: (expected, actual) => actual === expected,
	due_date: (expected, actual) => actual === expected,
	policy_number: (expected, actual) => actual === expected,
}
const comparedFields = Object.keys(fieldComparators)

function expectedValue(document: ExpectedDocument, field: string): ScoredValue | undefined {
	switch (field) {
		case "category":
			return document.category
		case "sender":
			return document.sender
		case "person":
			return document.person
		case "document_date":
			return document.document_date
		default:
			return document.fields[field]?.value
	}
}

function actualValue(document: ListedDocument, field: string): ScoredValue | null {
	switch (field) {
		case "category":
			return document.categoryName
		case "sender":
			return document.senderName
		case "person":
			return document.status === "archived" ? (document.personName ?? "household") : null
		case "document_date":
			return document.documentDate
		default:
			return document.fields.find((candidate) => candidate.fieldKey === field)?.value ?? null
	}
}

async function requestJson(url: string, init?: RequestInit): Promise<unknown> {
	const response = await fetch(url, init)
	if (!response.ok)
		throw new Error(`${init?.method ?? "GET"} ${url} answered ${response.status}: ${await response.text()}`)
	return response.json()
}

async function executeLocalSql(sql: string, params: Array<string>): Promise<void> {
	await requestJson(`${explorerUrl}/d1/database/${localDatabaseIdentifier}/raw`, {
		method: "POST",
		headers: { "content-type": "application/json" },
		body: JSON.stringify({ sql, params }),
	})
}

function addresseeSpellings(displayName: string): Array<string> {
	const unaccented = displayName.normalize("NFKD").replace(/\p{M}/gu, "")
	return [...new Set([displayName, unaccented])]
}

async function seedHouseholdMembers(names: Array<string>): Promise<void> {
	for (const name of names) {
		await executeLocalSql(
			"INSERT INTO household_members (id, display_name, addressee_names_json) SELECT ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM household_members WHERE display_name = ?)",
			[crypto.randomUUID(), name, JSON.stringify(addresseeSpellings(name)), name],
		)
	}
}

async function listDocuments(): Promise<Array<ListedDocument>> {
	return z.object({ documents: z.array(listedDocumentSchema) }).parse(await requestJson(`${baseUrl}/api/documents`))
		.documents
}

async function uploadDocuments(expectedDocuments: Array<ExpectedDocument>): Promise<Map<string, string>> {
	const formData = new FormData()
	for (const document of expectedDocuments) {
		const bytes = await readFile(new URL(document.file_name, fixtureDirectory))
		formData.append("files", new File([bytes], document.file_name, { type: document.media_type }))
	}
	const response = uploadResponseSchema.parse(
		await requestJson(`${baseUrl}/api/documents`, { method: "POST", body: formData }),
	)
	const documentIds = new Map<string, string>()
	for (const outcome of response.outcomes) {
		if (outcome.kind !== "accepted") throw new Error(`The server did not accept ${outcome.fileName}: ${outcome.reason}`)
		documentIds.set(outcome.fileName, outcome.documentId)
	}
	return documentIds
}

async function awaitSettlement(documentIds: Array<string>, startedAt: number, timeoutMilliseconds: number) {
	const settledAt = new Map<string, number>()
	let listing: Array<ListedDocument> = []
	while (settledAt.size < documentIds.length) {
		if (Date.now() - startedAt > timeoutMilliseconds) throw new Error("Documents did not settle before the timeout")
		await new Promise((resolve) => setTimeout(resolve, 2000))
		listing = await listDocuments()
		for (const document of listing) {
			if (
				documentIds.includes(document.id) &&
				!settledAt.has(document.id) &&
				["archived", "failed"].includes(document.status)
			) {
				settledAt.set(document.id, Date.now())
			}
		}
		process.stdout.write(`\r${settledAt.size}/${documentIds.length} documents settled`)
	}
	process.stdout.write("\n")
	return { settledAt, listing }
}

async function stepDurations(documentId: string) {
	const instance = workflowInstanceSchema.parse(
		await requestJson(`${explorerUrl}/workflows/${workflowName}/instances/${documentId}`),
	).result
	const seconds = (prefix: string) =>
		(instance.steps ?? [])
			.filter((step) => step.name.startsWith(prefix) && step.start !== null && step.end !== null)
			.reduce((total, step) => total + (Date.parse(step.end ?? "") - Date.parse(step.start ?? "")) / 1000, 0)
	return {
		model: instance.output?.classificationModel,
		errorMessage: instance.error?.message,
		recognitionSeconds: seconds("recognize page"),
		classificationSeconds: seconds("classify document"),
	}
}

async function gatewayCosts(gatewayId: string, startedAt: number, endedAt: number) {
	const execute = promisify(execFile)
	const costs = new Map<string, { requests: number; cost: number }>()
	for (let page = 1; page <= 10; page++) {
		const { stdout } = await execute("pnpm", [
			"exec",
			"cf",
			"ai-gateway",
			"logs",
			"list",
			"--gateway-id",
			gatewayId,
			"--quiet",
			"--order-by",
			"created_at",
			"--order-by-direction",
			"desc",
			"--per-page",
			"50",
			"--page",
			String(page),
		])
		const entries = gatewayLogSchema.parse(JSON.parse(stdout))
		for (const entry of entries) {
			const createdAt = Date.parse(entry.created_at)
			if (createdAt < startedAt || createdAt > endedAt) continue
			const total = costs.get(entry.model) ?? { requests: 0, cost: 0 }
			costs.set(entry.model, { requests: total.requests + 1, cost: total.cost + (entry.cost ?? 0) })
		}
		const oldest = entries.at(-1)
		if (oldest === undefined || Date.parse(oldest.created_at) < startedAt) break
	}
	return costs
}

function pad(text: string, width: number): string {
	return text.length >= width ? text.slice(0, width) : text + " ".repeat(width - text.length)
}

const expectation = expectationSchema.parse(
	JSON.parse(await readFile(new URL("expected_extraction.json", fixtureDirectory), "utf8")),
)
await seedHouseholdMembers(expectation.household_members)
const preexistingCount = (await listDocuments()).length
if (preexistingCount > 0) {
	console.log(
		`The archive already holds ${preexistingCount} documents, so their senders, categories, and tags shape this run.`,
	)
}

const startedAt = Date.now()
const documentIds = await uploadDocuments(expectation.documents)
const { settledAt, listing } = await awaitSettlement(
	[...documentIds.values()],
	startedAt,
	Number(options["timeout-minutes"]) * 60_000,
)
const endedAt = Date.now()

const nameWidth = 46
const cellWidth = 9
console.log(
	[
		pad("document", nameWidth),
		...comparedFields.map((field) => pad(field.slice(0, cellWidth - 1), cellWidth)),
		"score  ",
		"wall s",
		"ocr s",
		"llm s",
	].join(""),
)
const fieldTotals = new Map(comparedFields.map((field) => [field, { matched: 0, scored: 0 }]))
const mismatches: Array<string> = []
const failures: Array<string> = []
let model: string | undefined
for (const expected of expectation.documents) {
	const documentId = documentIds.get(expected.file_name) ?? ""
	const actual = listing.find((document) => document.id === documentId)
	if (!actual) throw new Error(`The listing lacks ${expected.file_name}`)
	const durations = await stepDurations(documentId)
	model ??= durations.model
	if (durations.errorMessage !== undefined) failures.push(`${expected.file_name}: ${durations.errorMessage}`)
	let matched = 0
	let scored = 0
	const cells = comparedFields.map((field) => {
		const expectedField = expectedValue(expected, field)
		const actualField = actualValue(actual, field)
		const comparison: Comparison =
			expectedField === undefined
				? "unscored"
				: fieldComparators[field]?.(expectedField, actualField)
					? "match"
					: "mismatch"
		const totals = fieldTotals.get(field)
		if (comparison !== "unscored" && totals) {
			totals.scored++
			scored++
			if (comparison === "match") {
				totals.matched++
				matched++
			} else {
				mismatches.push(
					`${expected.file_name} ${field}: expected ${expectedField}, received ${actualField ?? "nothing"}`,
				)
			}
		}
		return pad({ match: "ok", mismatch: "MISS", unscored: "-" }[comparison], cellWidth)
	})
	const wallSeconds = ((settledAt.get(documentId) ?? endedAt) - startedAt) / 1000
	console.log(
		[
			pad(`${expected.file_name}${actual.status === "failed" ? " FAILED" : ""}`, nameWidth),
			...cells,
			pad(`${matched}/${scored}`, 7),
			pad(wallSeconds.toFixed(0), 6),
			pad(durations.recognitionSeconds.toFixed(0), 6),
			durations.classificationSeconds.toFixed(0),
		].join(""),
	)
}
const overall = [...fieldTotals.values()].reduce(
	(total, field) => ({ matched: total.matched + field.matched, scored: total.scored + field.scored }),
	{ matched: 0, scored: 0 },
)
console.log(
	[
		pad("fields correct", nameWidth),
		...comparedFields.map((field) => {
			const totals = fieldTotals.get(field)
			return pad(totals ? `${totals.matched}/${totals.scored}` : "", cellWidth)
		}),
		`${overall.matched}/${overall.scored}`,
	].join(""),
)
console.log(`\nClassification model: ${model ?? "unknown"}`)
console.log(`Wall time for all documents: ${((endedAt - startedAt) / 1000).toFixed(0)} s, uploaded together`)
if (failures.length > 0) console.log(`\nFailures:\n${failures.join("\n")}`)
if (mismatches.length > 0) console.log(`\nMismatches:\n${mismatches.join("\n")}`)

if (options["gateway-id"] !== undefined) {
	// AI Gateway writes log entries a few seconds after each request completes.
	await new Promise((resolve) => setTimeout(resolve, 15_000))
	const costs = await gatewayCosts(options["gateway-id"], startedAt, Date.now())
	let total = 0
	console.log("\nAI Gateway cost during the run:")
	for (const [modelName, { requests, cost }] of costs) {
		total += cost
		console.log(`${pad(modelName, 46)}${pad(String(requests), 5)} requests  $${cost.toFixed(4)}`)
	}
	console.log(`Total $${total.toFixed(4)}`)
}
