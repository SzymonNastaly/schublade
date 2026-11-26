import { createClientOnlyFn } from "@tanstack/react-start"
import pdfRendererUrl from "pdfjs-dist/legacy/build/pdf.renderer.min.mjs?url"
import pdfWorkerUrl from "pdfjs-dist/legacy/build/pdf.worker.min.mjs?url"
import jbig2DecoderUrl from "pdfjs-dist/wasm/jbig2.wasm?url"
import openjpegDecoderUrl from "pdfjs-dist/wasm/openjpeg.wasm?url"

// The compiler removes this body from the server bundle, which would otherwise carry PDF.js and its workers.
export const preparePdfOpener = createClientOnlyFn(async () => {
	const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs")
	pdfjs.GlobalWorkerOptions.workerSrc = pdfWorkerUrl
	pdfjs.GlobalWorkerOptions.rendererSrc = pdfRendererUrl
	const decoderUrls: Partial<Record<string, string>> = {
		"jbig2.wasm": jbig2DecoderUrl,
		"openjpeg.wasm": openjpegDecoderUrl,
	}
	// PDF.js 6 decodes CCITT, JBIG2, and JPX images, the usual encodings of scanned pages, with
	// WebAssembly files it requests by name. Vite hashes those names, so no wasmUrl directory can serve them.
	class BundledDecoderFactory {
		async fetch({ filename }: { filename: string }): Promise<Uint8Array> {
			const url = decoderUrls[filename]
			if (url === undefined) throw new Error(`Schublade does not bundle ${filename}`)
			const response = await fetch(url)
			return new Uint8Array(await response.arrayBuffer())
		}
	}
	return (data: ArrayBuffer | Uint8Array) => pdfjs.getDocument({ data, BinaryDataFactory: BundledDecoderFactory })
})
