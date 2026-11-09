import { createClientOnlyFn } from "@tanstack/react-start"
import pdfRendererUrl from "pdfjs-dist/legacy/build/pdf.renderer.min.mjs?url"
import pdfWorkerUrl from "pdfjs-dist/legacy/build/pdf.worker.min.mjs?url"
import jbig2DecoderUrl from "pdfjs-dist/wasm/jbig2.wasm?url"
import openjpegDecoderUrl from "pdfjs-dist/wasm/openjpeg.wasm?url"
import { useEffect, useRef, useState } from "react"
import { ProgressSpinner } from "./controls/progress_spinner"
import type {
	PDFDocumentLoadingTask,
	PDFDocumentProxy,
	PDFPageProxy,
	RenderTask,
} from "pdfjs-dist/legacy/build/pdf.mjs"
import type { Dispatch, SetStateAction } from "react"

/** The box that holds an original file: A4 proportions at full column width, capped at the window height from md upward. */
export const documentBoxFrame = "relative block aspect-[1/1.414] w-full bg-viewer md:max-h-[calc(100vh-8rem)]"

const MAXIMUM_DRAWING_PIXEL_RATIO = 2.5
const DRAWN_PAGES_AROUND_VISIBLE_PAGE = 1

type PdfLoadProgress = { stage: "loading" } | { stage: "failed" } | { stage: "ready"; pdf: PDFDocumentProxy }

type PdfLoadProgressSetter = Dispatch<SetStateAction<PdfLoadProgress>>

// The compiler removes this body from the server bundle, which would otherwise carry PDF.js and its workers.
const preparePdfOpener = createClientOnlyFn(async () => {
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
	return (data: ArrayBuffer) => pdfjs.getDocument({ data, BinaryDataFactory: BundledDecoderFactory })
})

function PdfPageSlot({
	pdf,
	pageNumber,
	drawingWidth,
	onProgress,
}: {
	pdf: PDFDocumentProxy
	pageNumber: number
	/** The width in CSS pixels to draw the page at, or null to hold no canvas for it. */
	drawingWidth: number | null
	onProgress: PdfLoadProgressSetter
}) {
	const slot = useRef<HTMLDivElement>(null)
	useEffect(() => {
		if (drawingWidth === null) return
		const canvas = document.createElement("canvas")
		canvas.className = "size-full object-contain"
		let released = false
		let page: PDFPageProxy | undefined
		let renderTask: RenderTask | undefined
		const draw = async () => {
			page = await pdf.getPage(pageNumber)
			if (released) return
			const pixelRatio = Math.min(window.devicePixelRatio, MAXIMUM_DRAWING_PIXEL_RATIO)
			const viewport = page.getViewport({ scale: (drawingWidth / page.getViewport({ scale: 1 }).width) * pixelRatio })
			canvas.width = Math.floor(viewport.width)
			canvas.height = Math.floor(viewport.height)
			slot.current?.appendChild(canvas)
			renderTask = page.render({ canvas, viewport })
			await renderTask.promise
		}
		draw().catch((error: unknown) => {
			if (released) return
			console.error(`Page ${pageNumber} of the PDF could not be drawn`, error)
			onProgress({ stage: "failed" })
		})
		return () => {
			released = true
			renderTask?.cancel()
			page?.cleanup()
			canvas.remove()
			canvas.width = 0
			canvas.height = 0
		}
	}, [pdf, pageNumber, drawingWidth, onProgress])
	return <div ref={slot} data-page-number={pageNumber} className="size-full flex-none snap-start" />
}

function PdfPages({ pdf, onProgress }: { pdf: PDFDocumentProxy; onProgress: PdfLoadProgressSetter }) {
	const scroller = useRef<HTMLDivElement>(null)
	const [visiblePageNumber, setVisiblePageNumber] = useState(1)
	const [boxWidth, setBoxWidth] = useState<number | null>(null)
	useEffect(() => {
		const element = scroller.current
		if (element === null) return
		const resizeObserver = new ResizeObserver(() => setBoxWidth(element.clientWidth))
		resizeObserver.observe(element)
		// Every page fills the box, so at most one page is more than half visible.
		const intersectionObserver = new IntersectionObserver(
			(entries) => {
				for (const entry of entries) {
					if (entry.isIntersecting) setVisiblePageNumber(Number(entry.target.getAttribute("data-page-number")))
				}
			},
			{ root: element, threshold: 0.5 },
		)
		for (const pageSlot of element.children) intersectionObserver.observe(pageSlot)
		return () => {
			resizeObserver.disconnect()
			intersectionObserver.disconnect()
		}
	}, [])
	return (
		<>
			<div className={documentBoxFrame}>
				{/* Sideways paging below md, because a vertical scroller there traps the finger that scrolls the page. */}
				<div
					ref={scroller}
					role="region"
					aria-label="Original document"
					tabIndex={0}
					className="absolute inset-0 flex snap-x snap-mandatory gap-1 overflow-x-auto overflow-y-hidden rounded-[inherit] md:snap-none md:flex-col md:overflow-x-hidden md:overflow-y-auto"
				>
					{Array.from({ length: pdf.numPages }, (_, index) => index + 1).map((pageNumber) => (
						<PdfPageSlot
							key={pageNumber}
							pdf={pdf}
							pageNumber={pageNumber}
							drawingWidth={
								Math.abs(pageNumber - visiblePageNumber) <= DRAWN_PAGES_AROUND_VISIBLE_PAGE ? boxWidth : null
							}
							onProgress={onProgress}
						/>
					))}
				</div>
			</div>
			{pdf.numPages > 1 && (
				<p className="border-t border-table-rule px-3 py-2 text-fine text-caption">
					Page {visiblePageNumber} of {pdf.numPages}
				</p>
			)}
		</>
	)
}

/** The pages of a PDF in one box of constant size, whose length does not grow the page around it. */
export function PdfPageBox({ url }: { url: string }) {
	const [progress, setProgress] = useState<PdfLoadProgress>({ stage: "loading" })
	useEffect(() => {
		let abandoned = false
		let loadingTask: PDFDocumentLoadingTask | undefined
		const load = async () => {
			const [openPdf, response] = await Promise.all([preparePdfOpener(), fetch(url)])
			if (!response.ok) throw new Error(`The original file returned status ${response.status}`)
			const data = await response.arrayBuffer()
			if (abandoned) return
			loadingTask = openPdf(data)
			setProgress({ stage: "ready", pdf: await loadingTask.promise })
		}
		load().catch((error: unknown) => {
			if (abandoned) return
			console.error("The PDF could not be loaded", error)
			setProgress({ stage: "failed" })
		})
		return () => {
			abandoned = true
			void loadingTask?.destroy()
		}
	}, [url])
	if (progress.stage === "ready") return <PdfPages pdf={progress.pdf} onProgress={setProgress} />
	return (
		<div className={`${documentBoxFrame} flex items-center justify-center p-4`}>
			{progress.stage === "loading" ? (
				<span role="status" aria-label="Loading the document" className="text-caption">
					<ProgressSpinner />
				</span>
			) : (
				<p className="text-caption">This PDF cannot be displayed here.</p>
			)}
		</div>
	)
}
