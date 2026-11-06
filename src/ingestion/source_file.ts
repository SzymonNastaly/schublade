import type { RecognizableImageType } from "../inference/text_recognizer"

export type SourceFile =
	| { kind: "pdf"; mediaType: "application/pdf"; extension: "pdf" }
	| { kind: "image"; mediaType: RecognizableImageType; extension: "jpg" | "png" | "webp" }

const acceptedSourceFiles: ReadonlyArray<SourceFile> = [
	{ kind: "pdf", mediaType: "application/pdf", extension: "pdf" },
	{ kind: "image", mediaType: "image/jpeg", extension: "jpg" },
	{ kind: "image", mediaType: "image/png", extension: "png" },
	{ kind: "image", mediaType: "image/webp", extension: "webp" },
]

export const acceptedMediaTypes = acceptedSourceFiles.map((sourceFile) => sourceFile.mediaType)

export function parseSourceFile(mediaType: string): SourceFile | undefined {
	return acceptedSourceFiles.find((sourceFile) => sourceFile.mediaType === mediaType)
}

// Browsers report no type for some PDFs and accept HEIC photographs, so an upload is
// identified by its leading bytes rather than by the type the browser reports.
const fileSignatures: Record<SourceFile["mediaType"], ReadonlyArray<{ offset: number; bytes: Array<number> }>> = {
	"application/pdf": [{ offset: 0, bytes: [0x25, 0x50, 0x44, 0x46, 0x2d] }],
	"image/jpeg": [{ offset: 0, bytes: [0xff, 0xd8, 0xff] }],
	"image/png": [{ offset: 0, bytes: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] }],
	"image/webp": [
		{ offset: 0, bytes: [0x52, 0x49, 0x46, 0x46] },
		{ offset: 8, bytes: [0x57, 0x45, 0x42, 0x50] },
	],
}

export function identifySourceFile(content: Uint8Array): SourceFile | undefined {
	return acceptedSourceFiles.find((sourceFile) =>
		fileSignatures[sourceFile.mediaType].every(({ offset, bytes }) =>
			bytes.every((byte, index) => content[offset + index] === byte),
		),
	)
}

/** Every R2 object of a document lies under this prefix: its original, its Markdown, or its message. */
export function documentObjectPrefix(documentId: string): string {
	return `documents/${documentId}/`
}

export function originalObjectKey(documentId: string, sourceFile: SourceFile): string {
	return `${documentObjectPrefix(documentId)}original.${sourceFile.extension}`
}

export function contentObjectKey(documentId: string): string {
	return `${documentObjectPrefix(documentId)}content.md`
}
