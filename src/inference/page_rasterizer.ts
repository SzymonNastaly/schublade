import { init } from "@embedpdf/pdfium"
import pdfiumModule from "@embedpdf/pdfium/pdfium.wasm?module"
import { encode } from "fast-png"

type PdfiumLibrary = Awaited<ReturnType<typeof init>>

export interface PageInspection {
	pageIndex: number
	textCharacterCount: number
	/** The text layer as PDFium extracts it, with lines separated by line feeds. */
	text: string
}

export interface RasterizedPage {
	pageIndex: number
	widthPixels: number
	heightPixels: number
	pngBytes: Uint8Array
}

const BITMAP_FORMAT_BGRA = 4
const RENDER_ANNOTATIONS = 0x01
const POINTS_PER_INCH = 72
const OPAQUE_WHITE = 0xffffffff

let libraryPromise: Promise<PdfiumLibrary> | undefined

// Workers forbid compiling WebAssembly from bytes at runtime, so the module
// arrives precompiled through the bundler and is instantiated by hand.
function loadLibrary(): Promise<PdfiumLibrary> {
	libraryPromise ??= init({
		instantiateWasm(
			imports: WebAssembly.Imports,
			receiveInstance: (instance: WebAssembly.Instance, module: WebAssembly.Module) => void,
		) {
			const instance = new WebAssembly.Instance(pdfiumModule, imports)
			receiveInstance(instance, pdfiumModule)
			return instance.exports
		},
	}).then((library) => {
		library.PDFiumExt_Init()
		return library
	})
	return libraryPromise
}

async function withDocument<TResult>(
	pdfBytes: Uint8Array,
	operate: (library: PdfiumLibrary, documentHandle: number) => TResult,
): Promise<TResult> {
	const library = await loadLibrary()
	const runtime = library.pdfium
	const bufferPointer = runtime.wasmExports.malloc(pdfBytes.length)
	runtime.HEAPU8.set(pdfBytes, bufferPointer)
	const documentHandle = library.FPDF_LoadMemDocument(bufferPointer, pdfBytes.length, "")
	try {
		if (!documentHandle) {
			throw new Error(`PDFium could not open the document, error code ${library.FPDF_GetLastError()}`)
		}
		return operate(library, documentHandle)
	} finally {
		if (documentHandle) library.FPDF_CloseDocument(documentHandle)
		runtime.wasmExports.free(bufferPointer)
	}
}

export function inspectPages(pdfBytes: Uint8Array): Promise<Array<PageInspection>> {
	return withDocument(pdfBytes, (library, documentHandle) => {
		const pageCount = library.FPDF_GetPageCount(documentHandle)
		const pages: Array<PageInspection> = []
		for (let pageIndex = 0; pageIndex < pageCount; pageIndex++) {
			const pageHandle = library.FPDF_LoadPage(documentHandle, pageIndex)
			const textPageHandle = library.FPDFText_LoadPage(pageHandle)
			const textCharacterCount = library.FPDFText_CountChars(textPageHandle)
			pages.push({ pageIndex, textCharacterCount, text: readPageText(library, textPageHandle, textCharacterCount) })
			library.FPDFText_ClosePage(textPageHandle)
			library.FPDF_ClosePage(pageHandle)
		}
		return pages
	})
}

function readPageText(library: PdfiumLibrary, textPageHandle: number, characterCount: number): string {
	const runtime = library.pdfium
	const bufferPointer = runtime.wasmExports.malloc((characterCount + 1) * 2)
	try {
		// The returned count of UTF-16 code units includes the terminator, and is 0 without characters,
		// so the buffer holds no terminator to read up to.
		const textUnits = library.FPDFText_GetText(textPageHandle, 0, characterCount, bufferPointer) - 1
		const textBytes = runtime.HEAPU8.subarray(bufferPointer, bufferPointer + textUnits * 2)
		return new TextDecoder("utf-16le").decode(textBytes).replaceAll("\r\n", "\n")
	} finally {
		runtime.wasmExports.free(bufferPointer)
	}
}

export function rasterizePage(pdfBytes: Uint8Array, pageIndex: number, dotsPerInch = 150): Promise<RasterizedPage> {
	return withDocument(pdfBytes, (library, documentHandle) => {
		const pageHandle = library.FPDF_LoadPage(documentHandle, pageIndex)
		if (!pageHandle) throw new Error(`PDFium could not load page ${pageIndex}`)
		const scale = dotsPerInch / POINTS_PER_INCH
		const widthPixels = Math.round(library.FPDF_GetPageWidthF(pageHandle) * scale)
		const heightPixels = Math.round(library.FPDF_GetPageHeightF(pageHandle) * scale)
		const bitmapHandle = library.FPDFBitmap_CreateEx(widthPixels, heightPixels, BITMAP_FORMAT_BGRA, 0, 0)
		try {
			library.FPDFBitmap_FillRect(bitmapHandle, 0, 0, widthPixels, heightPixels, OPAQUE_WHITE)
			library.FPDF_RenderPageBitmap(bitmapHandle, pageHandle, 0, 0, widthPixels, heightPixels, 0, RENDER_ANNOTATIONS)
			const grayscale = toGrayscale(
				library.pdfium.HEAPU8,
				library.FPDFBitmap_GetBuffer(bitmapHandle),
				library.FPDFBitmap_GetStride(bitmapHandle),
				widthPixels,
				heightPixels,
			)
			return {
				pageIndex,
				widthPixels,
				heightPixels,
				pngBytes: encode({ width: widthPixels, height: heightPixels, data: grayscale, channels: 1, depth: 8 }),
			}
		} finally {
			library.FPDFBitmap_Destroy(bitmapHandle)
			library.FPDF_ClosePage(pageHandle)
		}
	})
}

function toGrayscale(
	heap: Uint8Array,
	bufferPointer: number,
	strideBytes: number,
	widthPixels: number,
	heightPixels: number,
): Uint8Array {
	const grayscale = new Uint8Array(widthPixels * heightPixels)
	for (let row = 0; row < heightPixels; row++) {
		const rowPointer = bufferPointer + row * strideBytes
		for (let column = 0; column < widthPixels; column++) {
			const pixelPointer = rowPointer + column * 4
			const blue = heap[pixelPointer] ?? 0
			const green = heap[pixelPointer + 1] ?? 0
			const red = heap[pixelPointer + 2] ?? 0
			grayscale[row * widthPixels + column] = (blue * 29 + green * 150 + red * 77) >> 8
		}
	}
	return grayscale
}
