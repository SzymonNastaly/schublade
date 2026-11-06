import { execFile } from "node:child_process"
import { readFile, stat } from "node:fs/promises"
import { fileURLToPath } from "node:url"
import { parseArgs, promisify } from "node:util"
import { z } from "zod"

// Ensures the test documents are archived in a running `VITE_ACCESS_DEVELOPMENT_EXEMPTION=true
// pnpm dev` server and indexed in its AI Search instance, then runs fixed searches and compares
// the results with literal expectations. Searches and indexing call the billed AI Search
// instance schublade-development, and archiving a missing document calls Workers AI.

const commandLine = process.argv.slice(2)
const { values: options } = parseArgs({
	args: commandLine[0] === "--" ? commandLine.slice(1) : commandLine,
	options: {
		"base-url": { type: "string", default: "http://localhost:3000" },
		"timeout-minutes": { type: "string", default: "20" },
		repetitions: { type: "string", default: "3" },
	},
})
const baseUrl = options["base-url"]
const timeoutMilliseconds = Number(options["timeout-minutes"]) * 60_000
const explorerUrl = `${baseUrl}/cdn-cgi/local/explorer/api`
// Keep equal to LOCAL_DATABASE_IDENTIFIER and LOCAL_WORKER_NAME in cloudflare.config.ts. Local
// development binds SEARCH_INDEX to the instance of the same name as the local Worker.
const localDatabaseIdentifier = "00000000-0000-4000-8000-000000000000"
const localWorkerName = "schublade-development"
const fixtureDirectory = new URL("../test_fixtures/documents/", import.meta.url)
const cloudflareExecutable = fileURLToPath(new URL("../node_modules/.bin/cf", import.meta.url))

const expectationSchema = z.object({
	household_members: z.array(z.string()),
	documents: z.array(
		z.object({ file_name: z.string(), media_type: z.string(), person: z.string(), category: z.string() }),
	),
})
const rawQuerySchema = z.object({
	result: z.array(
		z.object({ results: z.object({ columns: z.array(z.string()), rows: z.array(z.array(z.unknown())) }) }),
	),
})
const retrievedDocumentsSchema = z.object({
	documents: z.array(z.object({ id: z.string(), matchingPassage: z.string().nullable() })),
})
const indexingReportSchema = z.object({ indexedDocumentIds: z.array(z.string()), remainingDocumentCount: z.number() })
const uploadResponseSchema = z.object({
	outcomes: z.array(z.object({ kind: z.string(), fileName: z.string(), documentId: z.string().optional() })),
})
const itemListSchema = z.array(z.object({ id: z.string(), key: z.string(), status: z.string() }))
const itemLogsSchema = z.array(z.object({ timestamp: z.string(), action: z.string() }))
const workflowInstanceSchema = z.object({
	result: z.object({ steps: z.array(z.object({ name: z.string(), end: z.string().nullable() })).optional() }),
})

async function requestJson(url: string, init?: RequestInit): Promise<unknown> {
	const response = await fetch(url, init)
	if (!response.ok) {
		throw new Error(`${init?.method ?? "GET"} ${url} answered ${response.status}: ${await response.text()}`)
	}
	return response.json()
}

async function queryLocalDatabase(sql: string, params: Array<string> = []) {
	const response = rawQuerySchema.parse(
		await requestJson(`${explorerUrl}/d1/database/${localDatabaseIdentifier}/raw`, {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({ sql, params }),
		}),
	)
	const { columns, rows } = response.result[0]?.results ?? { columns: [], rows: [] }
	return rows.map((row) => Object.fromEntries(columns.map((column, index) => [column, row[index]])))
}

const delay = (milliseconds: number) => new Promise((resolve) => setTimeout(resolve, milliseconds))

const expectation = expectationSchema.parse(
	JSON.parse(await readFile(new URL("expected_extraction.json", fixtureDirectory), "utf8")),
)
const fixtures = await Promise.all(
	expectation.documents.map(async (document) => ({
		...document,
		byteSize: (await stat(new URL(document.file_name, fixtureDirectory))).size,
	})),
)

// The archive does not record file names, so each fixture is recognized by its size and type.
async function archivedFixtureDocuments(): Promise<Map<string, string>> {
	const rows = await queryLocalDatabase("SELECT id, byte_size, mime_type FROM documents WHERE status = 'archived'")
	const fileNameById = new Map<string, string>()
	for (const row of rows) {
		const fixture = fixtures.find(
			(candidate) => candidate.byteSize === row.byte_size && candidate.media_type === row.mime_type,
		)
		if (fixture) fileNameById.set(String(row.id), fixture.file_name)
	}
	return fileNameById
}

for (const name of expectation.household_members) {
	await queryLocalDatabase(
		"INSERT INTO household_members (id, display_name, addressee_names_json) SELECT ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM household_members WHERE display_name = ?)",
		[
			crypto.randomUUID(),
			name,
			JSON.stringify([...new Set([name, name.normalize("NFKD").replace(/\p{M}/gu, "")])]),
			name,
		],
	)
}

const startedAt = Date.now()
let fileNameById = await archivedFixtureDocuments()
const missingFixtures = fixtures.filter((fixture) => ![...fileNameById.values()].includes(fixture.file_name))
if (missingFixtures.length > 0) {
	console.log(`Archiving ${missingFixtures.length} test documents through the ingestion workflow`)
	const formData = new FormData()
	for (const fixture of missingFixtures) {
		const bytes = await readFile(new URL(fixture.file_name, fixtureDirectory))
		formData.append("files", new File([bytes], fixture.file_name, { type: fixture.media_type }))
	}
	const { outcomes } = uploadResponseSchema.parse(
		await requestJson(`${baseUrl}/api/documents`, { method: "POST", body: formData }),
	)
	const rejected = outcomes.filter((outcome) => outcome.kind !== "accepted")
	if (rejected.length > 0) throw new Error(`The server did not accept ${rejected.map((outcome) => outcome.fileName)}`)
	while (fileNameById.size < fixtures.length) {
		if (Date.now() - startedAt > timeoutMilliseconds) throw new Error("The test documents were not archived in time")
		await delay(3000)
		fileNameById = await archivedFixtureDocuments()
		process.stdout.write(`\r${fileNameById.size}/${fixtures.length} test documents archived`)
	}
	process.stdout.write("\n")
}

// The workflow uploads each document in its last step, so that step's end is its upload time.
// The explorer appends an attempt number to each step name, such as "index document-1".
const uploadedAt = new Map<string, number>()
for (const documentId of fileNameById.keys()) {
	const instance = await requestJson(
		`${explorerUrl}/workflows/${localWorkerName}-document-ingestion/instances/${documentId}`,
	).catch(() => undefined)
	const indexStep = workflowInstanceSchema
		.safeParse(instance)
		.data?.result.steps?.findLast((step) => step.name.startsWith("index document"))
	if (indexStep?.end) uploadedAt.set(documentId, Date.parse(indexStep.end))
}

for (;;) {
	const requestedAt = Date.now()
	const report = indexingReportSchema.parse(await requestJson(`${baseUrl}/api/search_index`, { method: "POST" }))
	for (const documentId of report.indexedDocumentIds) uploadedAt.set(documentId, requestedAt)
	if (report.indexedDocumentIds.length > 0) {
		console.log(`Indexed ${report.indexedDocumentIds.length} archived documents that AI Search lacked`)
	}
	if (report.remainingDocumentCount === 0) break
}

const runCloudflare = async (args: Array<string>) =>
	JSON.parse((await promisify(execFile)(cloudflareExecutable, [...args, "--quiet"])).stdout) as unknown

async function listItems(): Promise<Map<string, { id: string; status: string }>> {
	const items = new Map<string, { id: string; status: string }>()
	for (let page = 1; ; page++) {
		const listed = itemListSchema.parse(
			await runCloudflare([
				"ai-search",
				"items",
				"list",
				"--instance-id",
				localWorkerName,
				"--source",
				"builtin",
				"--per-page",
				"50",
				"--page",
				String(page),
			]),
		)
		for (const item of listed) items.set(item.key, item)
		if (listed.length < 50) return items
	}
}

let items = await listItems()
for (;;) {
	const statusOf = (documentId: string) => items.get(`${documentId}.md`)?.status
	const failed = [...fileNameById.keys()].filter((documentId) => statusOf(documentId) === "error")
	if (failed.length > 0) throw new Error(`AI Search failed to index ${failed.map((id) => fileNameById.get(id))}`)
	const completed = [...fileNameById.keys()].filter((documentId) => statusOf(documentId) === "completed")
	process.stdout.write(`\r${completed.length}/${fileNameById.size} test documents indexed`)
	if (completed.length === fileNameById.size) break
	if (Date.now() - startedAt > timeoutMilliseconds) throw new Error("AI Search did not finish indexing in time")
	await delay(2000)
	items = await listItems()
}
process.stdout.write("\n")

// Each item log records when AI Search finished indexing an upload. The upload time comes from
// the local clock, so the latency includes any offset between that clock and Cloudflare's.
const indexingSeconds: Array<number> = []
for (const [documentId, uploaded] of uploadedAt) {
	const item = items.get(`${documentId}.md`)
	if (!item) continue
	const logs = itemLogsSchema.parse(
		await runCloudflare(["ai-search", "items", "logs", item.id, "--instance-id", localWorkerName]),
	)
	const indexedAt = logs
		.filter((log) => log.action.endsWith("indexed"))
		.map((log) => Date.parse(log.timestamp))
		.filter((timestamp) => timestamp >= uploaded - 5000)
		.sort((first, second) => first - second)[0]
	if (indexedAt !== undefined) indexingSeconds.push((indexedAt - uploaded) / 1000)
}
indexingSeconds.sort((first, second) => first - second)
if (indexingSeconds.length > 0) {
	console.log(
		`Indexing latency from upload to the indexed entry of the item log, over ${indexingSeconds.length} documents: ` +
			`minimum ${indexingSeconds[0]?.toFixed(1)} s, median ${indexingSeconds[Math.floor(indexingSeconds.length / 2)]?.toFixed(1)} s, ` +
			`maximum ${indexingSeconds.at(-1)?.toFixed(1)} s`,
	)
} else {
	console.log("No item log records the indexing of a recorded upload, so no indexing latency was measured")
}

async function identifierOf(table: "household_members" | "categories", column: string, value: string) {
	const [row] = await queryLocalDatabase(`SELECT id FROM ${table} WHERE ${column} = ?`, [value])
	if (!row) throw new Error(`The local database has no ${table} row named ${value}`)
	return String(row.id)
}

const evaluatedMember = "Jonas Becker"
const memberFixtures = fixtures
	.filter((fixture) => fixture.person === evaluatedMember)
	.map((fixture) => fixture.file_name)
const memberId = await identifierOf("household_members", "display_name", evaluatedMember)
const invoiceCategoryId = await identifierOf("categories", "name", "Invoice")

type Expectation =
	| { kind: "includes"; fileName: string }
	| { kind: "first"; fileName: string }
	| { kind: "exactly"; fileNames: Array<string> }
	| { kind: "within"; fileNames: Array<string> }

const invoiceFixtures = fixtures.filter((fixture) => fixture.category === "Invoice").map((fixture) => fixture.file_name)

const evaluations: Array<{ description: string; parameters: Record<string, string>; expected: Array<Expectation> }> = [
	{
		description: "An English query finds the German electricity invoice",
		parameters: { query: "electricity bill" },
		expected: [{ kind: "includes", fileName: "electricity_invoice_scanned.pdf" }],
	},
	{
		description: "The printed IBAN of the dental invoice finds it first",
		parameters: { query: "DE80 9701 1320 0605 1900 31" },
		expected: [{ kind: "first", fileName: "dental_invoice_scanned.pdf" }],
	},
	{
		description: `A search filtered to ${evaluatedMember} returns every document of that member and no other`,
		parameters: { query: evaluatedMember, person: memberId },
		expected: [{ kind: "exactly", fileNames: memberFixtures }],
	},
	{
		description: `The filter for ${evaluatedMember} without a query lists the same documents from D1`,
		parameters: { person: memberId },
		expected: [{ kind: "exactly", fileNames: memberFixtures }],
	},
	{
		description: "The Invoice category ranks the Nordkabel invoice first and returns only invoices",
		parameters: { query: "Nordkabel", category: invoiceCategoryId },
		expected: [
			{ kind: "first", fileName: "telecommunication_invoice_digital.pdf" },
			{ kind: "within", fileNames: invoiceFixtures },
		],
	},
	{
		description: "Without the category, the same query also finds the Nordkabel general terms",
		parameters: { query: "Nordkabel" },
		expected: [
			{ kind: "includes", fileName: "telecommunication_invoice_digital.pdf" },
			{ kind: "includes", fileName: "general_terms_and_conditions_digital.pdf" },
		],
	},
	{
		description: "A September 2026 date range keeps only the two Talbrück documents dated in it",
		parameters: { query: "Talbrück", earliestDocumentDate: "2026-09-01", latestDocumentDate: "2026-09-30" },
		expected: [
			{ kind: "exactly", fileNames: ["electricity_invoice_scanned.pdf", "income_tax_assessment_scanned.pdf"] },
		],
	},
	{
		description: "An amount range from 70 to 100 lists the three documents within it from D1",
		parameters: { minimumAmount: "70", maximumAmount: "100" },
		expected: [
			{
				kind: "exactly",
				fileNames: [
					"electricity_invoice_scanned.pdf",
					"hardware_store_receipt_scanned.pdf",
					"dental_invoice_scanned.pdf",
				],
			},
		],
	},
]

function assess(expected: Expectation, fileNames: Array<string>): boolean {
	switch (expected.kind) {
		case "includes":
			return fileNames.includes(expected.fileName)
		case "first":
			return fileNames[0] === expected.fileName
		case "exactly":
			return (
				fileNames.length === expected.fileNames.length &&
				expected.fileNames.every((fileName) => fileNames.includes(fileName))
			)
		case "within":
			return fileNames.every((fileName) => expected.fileNames.includes(fileName))
	}
}

const repetitions = Number(options.repetitions)
let failures = 0
const searchLatencies: Array<number> = []
for (const evaluation of evaluations) {
	const url = `${baseUrl}/api/documents?${new URLSearchParams(evaluation.parameters)}`
	const latencies: Array<number> = []
	let documents: z.infer<typeof retrievedDocumentsSchema>["documents"] = []
	for (let repetition = 0; repetition < repetitions; repetition++) {
		const requestedAt = performance.now()
		documents = retrievedDocumentsSchema.parse(await requestJson(url)).documents
		latencies.push(performance.now() - requestedAt)
	}
	const medianLatency = [...latencies].sort((first, second) => first - second)[Math.floor(latencies.length / 2)] ?? 0
	if (evaluation.parameters.query !== undefined) searchLatencies.push(medianLatency)
	const fileNames = documents.map((document) => fileNameById.get(document.id) ?? `unrecognized ${document.id}`)
	const passed = evaluation.expected.every((expected) => assess(expected, fileNames))
	if (!passed) failures++
	console.log(`\n${passed ? "PASS" : "FAIL"}  ${evaluation.description}`)
	console.log(
		`      ${new URLSearchParams(evaluation.parameters)}, median ${medianLatency.toFixed(0)} ms over ${repetitions} requests`,
	)
	documents.forEach((document, index) => {
		const passage = document.matchingPassage === null ? "" : `  “${document.matchingPassage.slice(0, 90)}”`
		console.log(`      ${index + 1}. ${fileNames[index]}${passage}`)
	})
}

const sortedSearchLatencies = searchLatencies.sort((first, second) => first - second)
console.log(
	`\n${evaluations.length - failures} of ${evaluations.length} searches passed. ` +
		`Median latency of the AI Search queries through the dev server: ${sortedSearchLatencies[Math.floor(sortedSearchLatencies.length / 2)]?.toFixed(0)} ms`,
)
process.exitCode = failures > 0 ? 1 : 0
