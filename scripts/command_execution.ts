/**
 * The processes the provisioning and deployment scripts start: git, pnpm, and cf from
 * node_modules, and the parsing of cf's JSON answers.
 */
import { spawn } from "node:child_process"
import { basename } from "node:path"
import { fileURLToPath } from "node:url"
import { z } from "zod"

const cloudflareExecutable = fileURLToPath(new URL("../node_modules/.bin/cf", import.meta.url))

function describeCommand(executable: string, commandArguments: Array<string>): string {
	return [basename(executable), ...commandArguments].join(" ")
}

/** Runs a command with its output captured, and resolves with its exit code whatever it is. */
export function runCommandForExitCode(executable: string, commandArguments: Array<string>) {
	return new Promise<{ exitCode: number | null; standardOutput: string; standardError: string }>((resolve, reject) => {
		const child = spawn(executable, commandArguments, { stdio: ["ignore", "pipe", "pipe"] })
		let standardOutput = ""
		let standardError = ""
		child.stdout.on("data", (chunk: Buffer) => (standardOutput += chunk.toString()))
		child.stderr.on("data", (chunk: Buffer) => (standardError += chunk.toString()))
		child.on("error", reject)
		child.on("close", (exitCode) => resolve({ exitCode, standardOutput, standardError }))
	})
}

export async function runCommand(executable: string, commandArguments: Array<string>) {
	const { exitCode, standardOutput, standardError } = await runCommandForExitCode(executable, commandArguments)
	if (exitCode === 0) return { standardOutput, standardError }
	const output = `${standardOutput}\n${standardError}`.trim().split("\n").slice(-40).join("\n")
	throw new Error(`\`${describeCommand(executable, commandArguments)}\` exited with ${exitCode}:\n${output}`)
}

/** Runs a command on this process's terminal, so that a person can answer its questions. */
function runCommandInTerminal(executable: string, commandArguments: Array<string>) {
	return new Promise<void>((resolve, reject) => {
		const child = spawn(executable, commandArguments, { stdio: "inherit" })
		child.on("error", reject)
		child.on("close", (exitCode) => {
			if (exitCode === 0) resolve()
			else reject(new Error(`\`${describeCommand(executable, commandArguments)}\` exited with ${exitCode}.`))
		})
	})
}

export function runCloudflare(commandArguments: Array<string>) {
	return runCommand(cloudflareExecutable, commandArguments)
}

export function runCloudflareInTerminal(commandArguments: Array<string>) {
	return runCommandInTerminal(cloudflareExecutable, commandArguments)
}

// List commands print a `result_info: {...}` line before the JSON document.
function parseJsonDocument(standardOutput: string): unknown {
	const start = standardOutput.search(/^[[{]/m)
	if (start === -1) throw new Error(`cf printed no JSON document:\n${standardOutput}`)
	return JSON.parse(standardOutput.slice(start))
}

export async function queryCloudflare<TOutput>(
	schema: z.ZodType<TOutput>,
	commandArguments: Array<string>,
): Promise<TOutput> {
	const { standardOutput } = await runCloudflare(commandArguments)
	return schema.parse(parseJsonDocument(standardOutput))
}

export async function findCloudflareResource<TOutput>(
	schema: z.ZodType<TOutput>,
	commandArguments: Array<string>,
): Promise<TOutput | undefined> {
	try {
		return await queryCloudflare(schema, commandArguments)
	} catch (error) {
		if (error instanceof Error && /\b404 Not Found\b/.test(error.message)) return undefined
		throw error
	}
}

const resultInformationSchema = z.object({ total_count: z.number() })

export async function listCloudflareResources<TItem>(
	itemSchema: z.ZodType<TItem>,
	commandArguments: Array<string>,
): Promise<Array<TItem>> {
	const items: Array<TItem> = []
	for (let page = 1; ; page += 1) {
		const { standardOutput } = await runCloudflare([...commandArguments, "--page", String(page)])
		const pageItems = z.array(itemSchema).parse(parseJsonDocument(standardOutput))
		items.push(...pageItems)
		const resultInformation = /^result_info: (.+)$/m.exec(standardOutput)?.[1]
		const totalCount =
			resultInformation === undefined
				? items.length
				: resultInformationSchema.parse(JSON.parse(resultInformation)).total_count
		if (pageItems.length === 0 || items.length >= totalCount) return items
	}
}
