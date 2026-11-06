const TEXT_RECOGNITION_MODEL = "@cf/moondream/moondream3.1-9B-A2B"

type RecognizableImageType = "image/png" | "image/jpeg" | "image/webp"

/** @public */
export interface RecognizableImage {
	mediaType: RecognizableImageType
	bytes: Uint8Array
}

/** @public */
export interface TextRecognizer {
	transcribe: (image: RecognizableImage) => Promise<string>
}

const TRANSCRIPTION_QUESTION =
	"Transcribe all text on this document page exactly as printed, line by line, preserving numbers, dates, amounts, and IBANs. Output only the transcription."

interface MoondreamAnswer {
	answer?: string | null
}

interface MoondreamStreamEvent {
	chunk?: MoondreamAnswer
}

// The binding answers with a server-sent event stream even when `stream` is
// false. Every chunk repeats the full answer so far, so the last chunk wins.
export function parseMoondreamEventStream(eventStream: string): string {
	let answer: string | undefined
	for (const line of eventStream.split("\n")) {
		if (!line.startsWith("data: ")) continue
		const payload = line.slice("data: ".length).trim()
		if (payload === "[DONE]") continue
		let event: MoondreamStreamEvent
		try {
			event = JSON.parse(payload) as MoondreamStreamEvent
		} catch {
			continue
		}
		if (typeof event.chunk?.answer === "string") answer = event.chunk.answer
	}
	if (answer === undefined) throw new Error("Moondream returned no answer")
	return answer.trim()
}

async function readMoondreamResult(result: unknown): Promise<string> {
	if (result instanceof ReadableStream) return parseMoondreamEventStream(await new Response(result).text())
	const answer = (result as MoondreamAnswer | null)?.answer
	if (typeof answer !== "string") throw new Error("Moondream returned no answer")
	return answer.trim()
}

function encodeDataUri(image: RecognizableImage): string {
	let binary = ""
	const blockSize = 0x8000
	for (let offset = 0; offset < image.bytes.length; offset += blockSize) {
		binary += String.fromCharCode(...image.bytes.subarray(offset, offset + blockSize))
	}
	return `data:${image.mediaType};base64,${btoa(binary)}`
}

/** @public */
export function createMoondreamRecognizer(runtime: Ai, gatewayIdentifier: string): TextRecognizer {
	return {
		async transcribe(image) {
			const result: unknown = await runtime.run(
				TEXT_RECOGNITION_MODEL as Parameters<Ai["run"]>[0],
				{
					task: "query",
					image: encodeDataUri(image),
					question: TRANSCRIPTION_QUESTION,
					reasoning: false,
					temperature: 0,
					max_tokens: 4096,
				} as never,
				{ gateway: { id: gatewayIdentifier } },
			)
			return readMoondreamResult(result)
		},
	}
}
