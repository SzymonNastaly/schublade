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

export function originalObjectKey(documentId: string, sourceFile: SourceFile): string {
	return `documents/${documentId}/original.${sourceFile.extension}`
}

export function contentObjectKey(documentId: string): string {
	return `documents/${documentId}/content.md`
}
