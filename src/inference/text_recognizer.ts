import type { QuarterTurns } from "../database/schema"

const TEXT_RECOGNITION_MODEL = "@cf/moondream/moondream3.1-9B-A2B"

// Upright pages used at most 597 tokens. A page Moondream cannot read repeats text until this limit.
const MAXIMUM_OUTPUT_TOKENS = 2048

const LONGEST_EDGE_PIXELS = 1600
const JPEG_QUALITY = 90
const DEGREES_OF_QUARTER_TURNS = [0, 90, 180, 270] as const

export type RecognizableImageType = "image/png" | "image/jpeg" | "image/webp"

interface RecognizableImage {
	mediaType: RecognizableImageType
	bytes: Uint8Array
}

export type TextRecognition = { kind: "transcribed"; text: string } | { kind: "token_limit_reached" }

const WORD_SEGMENTER = new Intl.Segmenter(undefined, { granularity: "word" })

/**
 * Compares readings of one page at different rotations. A wrong rotation can yield as many
 * characters as the right one, but it repeats itself. Segmenting works in scripts without spaces.
 */
export function countDistinctWords(text: string): number {
	const words = new Set<string>()
	for (const { segment, isWordLike } of WORD_SEGMENTER.segment(text.toLowerCase())) {
		if (isWordLike) words.add(segment)
	}
	return words.size
}

interface TextRecognizer {
	transcribe: (image: RecognizableImage) => Promise<TextRecognition>
}

const TRANSCRIPTION_QUESTION =
	"Transcribe all text on this document page exactly as printed, line by line, preserving numbers, dates, amounts, and IBANs. Output only the transcription."

interface MoondreamStreamEvent {
	chunk?: { answer?: string | null; finish_reason?: string | null }
}

// The Moondream service returns the euro sign, which UTF-8 encodes in three bytes, as
// U+FFFD, while ä, ß, and ś usually survive. The en dash of a date range, the degree sign,
// and the superscript two of m² also stand beside digits, so only a U+FFFD directly before
// or after a monetary amount, optionally separated by one space, is taken for €. Moondream
// writes amounts with a decimal comma or a decimal point and always two decimal places.
// Every other U+FFFD stays, and the classification prompt tells the model what it means.
const MONETARY_AMOUNT = String.raw`-?\d+(?:[.,]\d{3})*[.,]\d{2}(?![.,]?\d)`
const REPLACEMENT_CHARACTER_BESIDE_AMOUNT = new RegExp(
	String.raw`\uFFFD(?= ?${MONETARY_AMOUNT})|(?<=\d[.,]\d{2} ?)\uFFFD`,
	"gu",
)

export function restoreEuroSigns(transcription: string): string {
	return transcription.replace(REPLACEMENT_CHARACTER_BESIDE_AMOUNT, "€")
}

// The binding answers with a server-sent event stream even when `stream` is
// false. Every chunk repeats the full answer so far, so the last chunk wins. A page at the token
// limit streams megabytes, so the stream is read line by line and only the latest event is kept.
export async function parseMoondreamEventStream(eventStream: ReadableStream<Uint8Array>): Promise<TextRecognition> {
	let answer: string | undefined
	let finishReason: string | null | undefined
	const readLine = (line: string) => {
		if (!line.startsWith("data: ")) return
		const payload = line.slice("data: ".length).trim()
		if (payload === "[DONE]") return
		let event: MoondreamStreamEvent
		try {
			event = JSON.parse(payload) as MoondreamStreamEvent
		} catch {
			return
		}
		if (typeof event.chunk?.answer === "string") answer = event.chunk.answer
		if (event.chunk?.finish_reason) finishReason = event.chunk.finish_reason
	}
	const decoder = new TextDecoder()
	let partialLine = ""
	for await (const bytes of eventStream) {
		const lines = (partialLine + decoder.decode(bytes, { stream: true })).split("\n")
		partialLine = lines.pop() ?? ""
		lines.forEach(readLine)
	}
	readLine(partialLine + decoder.decode())
	if (answer === undefined) throw new Error("Moondream returned no answer")
	return finishReason === "length" ? { kind: "token_limit_reached" } : { kind: "transcribed", text: answer.trim() }
}

/**
 * Moondream reads the stored pixels and ignores the EXIF orientation of a photograph, which then
 * reaches it sideways. Cloudflare Images applies the orientation. Without a stated background,
 * transparent pixels came back as black, which hid black text.
 */
export async function normalizeRecognitionImage(
	transformer: ImagesBinding,
	bytes: Uint8Array<ArrayBuffer>,
	quarterTurns: QuarterTurns,
): Promise<RecognizableImage> {
	const result = await transformer
		.input(new Blob([bytes]).stream())
		.transform({
			width: LONGEST_EDGE_PIXELS,
			height: LONGEST_EDGE_PIXELS,
			fit: "scale-down",
			rotate: DEGREES_OF_QUARTER_TURNS[quarterTurns],
		})
		.output({ format: "image/jpeg", quality: JPEG_QUALITY, background: "#FFFFFF" })
	return { mediaType: "image/jpeg", bytes: new Uint8Array(await result.response().arrayBuffer()) }
}

function encodeDataUri(image: RecognizableImage): string {
	let binary = ""
	const blockSize = 0x8000
	for (let offset = 0; offset < image.bytes.length; offset += blockSize) {
		binary += String.fromCharCode(...image.bytes.subarray(offset, offset + blockSize))
	}
	return `data:${image.mediaType};base64,${btoa(binary)}`
}

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
					max_tokens: MAXIMUM_OUTPUT_TOKENS,
				} as never,
				{ gateway: { id: gatewayIdentifier, skipCache: true } },
			)
			const recognition = await parseMoondreamEventStream(result as ReadableStream<Uint8Array>)
			return recognition.kind === "transcribed"
				? { kind: "transcribed", text: restoreEuroSigns(recognition.text) }
				: recognition
		},
	}
}
