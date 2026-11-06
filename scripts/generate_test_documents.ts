import { readFileSync } from "node:fs";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { init as initializePdfium } from "@embedpdf/pdfium";
import jpeg from "jpeg-js";
import PDFDocument from "pdfkit";
import { type ColorRaster, type GrayscaleRaster, createRandomSource, simulateFlatbedScan, simulateReceiptPhotograph } from "./test_document_generation/capture_simulation.ts";
import { documentCatalog } from "./test_document_generation/document_catalog.ts";
import { type CaptureMethod, type DocumentSpecification, householdMembers, letterMargins, typefaceFiles } from "./test_document_generation/document_layout.ts";

const outputDirectory = fileURLToPath(new URL("../test_fixtures/documents/", import.meta.url));
const syntheticNotice = "Synthetic test document for Schublade. Every person, organization, address, and account number in it is fictional.";
const scanResolutionDotsPerInch = 150;
const photographResolutionDotsPerInch = 190;

const captureFormats = {
	digital: { extension: "pdf", mediaType: "application/pdf", hasTextLayer: true },
	scanned: { extension: "pdf", mediaType: "application/pdf", hasTextLayer: false },
	photographed: { extension: "jpg", mediaType: "image/jpeg", hasTextLayer: false },
} as const satisfies Record<CaptureMethod, { extension: string; mediaType: string; hasTextLayer: boolean }>;

type Pdfium = Awaited<ReturnType<typeof initializePdfium>>;

async function loadPdfium(): Promise<Pdfium> {
	const pdfium = await initializePdfium({ wasmBinary: Uint8Array.from(readFileSync(fileURLToPath(import.meta.resolve("@embedpdf/pdfium/pdfium.wasm")))).buffer });
	pdfium.PDFiumExt_Init();
	return pdfium;
}

function withLoadedPdf<Result>(pdfium: Pdfium, bytes: Uint8Array, inspect: (documentHandle: number) => Result): Result {
	const runtime = pdfium.pdfium;
	const pointer = runtime.wasmExports.malloc(bytes.length);
	runtime.HEAPU8.set(bytes, pointer);
	const documentHandle = pdfium.FPDF_LoadMemDocument(pointer, bytes.length, "");
	try {
		if (!documentHandle) throw new Error(`PDFium could not load the document (error ${pdfium.FPDF_GetLastError()})`);
		return inspect(documentHandle);
	} finally {
		if (documentHandle) pdfium.FPDF_CloseDocument(documentHandle);
		runtime.wasmExports.free(pointer);
	}
}

function extractPageTexts(pdfium: Pdfium, bytes: Uint8Array): string[] {
	return withLoadedPdf(pdfium, bytes, (documentHandle) =>
		Array.from({ length: pdfium.FPDF_GetPageCount(documentHandle) }, (_, pageIndex) => {
			const page = pdfium.FPDF_LoadPage(documentHandle, pageIndex);
			const textPage = pdfium.FPDFText_LoadPage(page);
			const characterCount = pdfium.FPDFText_CountChars(textPage);
			const buffer = pdfium.pdfium.wasmExports.malloc((characterCount + 1) * 2);
			pdfium.FPDFText_GetText(textPage, 0, characterCount, buffer);
			const text = characterCount > 0 ? pdfium.pdfium.UTF16ToString(buffer) : "";
			pdfium.pdfium.wasmExports.free(buffer);
			pdfium.FPDFText_ClosePage(textPage);
			pdfium.FPDF_ClosePage(page);
			return text;
		}),
	);
}

function rasterizePages(pdfium: Pdfium, bytes: Uint8Array, dotsPerInch: number): GrayscaleRaster[] {
	const bitmapFormatBlueGreenRedAlpha = 4;
	return withLoadedPdf(pdfium, bytes, (documentHandle) =>
		Array.from({ length: pdfium.FPDF_GetPageCount(documentHandle) }, (_, pageIndex) => {
			const page = pdfium.FPDF_LoadPage(documentHandle, pageIndex);
			const width = Math.round((pdfium.FPDF_GetPageWidthF(page) * dotsPerInch) / 72);
			const height = Math.round((pdfium.FPDF_GetPageHeightF(page) * dotsPerInch) / 72);
			const bitmap = pdfium.FPDFBitmap_CreateEx(width, height, bitmapFormatBlueGreenRedAlpha, 0, 0);
			pdfium.FPDFBitmap_FillRect(bitmap, 0, 0, width, height, 0xffffffff);
			pdfium.FPDF_RenderPageBitmap(bitmap, page, 0, 0, width, height, 0, 0);
			const bufferPointer = pdfium.FPDFBitmap_GetBuffer(bitmap);
			const stride = pdfium.FPDFBitmap_GetStride(bitmap);
			const heap = pdfium.pdfium.HEAPU8;
			const luminance = new Uint8Array(width * height);
			for (let y = 0; y < height; y++) {
				for (let x = 0; x < width; x++) {
					const pixel = bufferPointer + y * stride + x * 4;
					luminance[y * width + x] = (heap[pixel] * 29 + heap[pixel + 1] * 150 + heap[pixel + 2] * 77) >> 8;
				}
			}
			pdfium.FPDFBitmap_Destroy(bitmap);
			pdfium.FPDF_ClosePage(page);
			return { width, height, luminance };
		}),
	);
}

function documentInformation(specification: DocumentSpecification): PDFKit.DocumentInfo {
	const timestamp = new Date(`${specification.documentDate.value}T09:30:00Z`);
	return {
		Title: "Synthetic test document",
		Subject: syntheticNotice,
		Keywords: "synthetic, fictional, test fixture",
		Creator: "scripts/generate_test_documents.ts",
		Producer: "Schublade synthetic test document generator",
		CreationDate: timestamp,
		ModDate: timestamp,
	};
}

function collectPdf(document: PDFKit.PDFDocument): Promise<Buffer> {
	return new Promise((resolve, reject) => {
		const chunks: Buffer[] = [];
		document.on("data", (chunk: Buffer) => chunks.push(chunk));
		document.on("end", () => resolve(Buffer.concat(chunks)));
		document.on("error", reject);
		document.end();
	});
}

function renderSourcePdf(specification: DocumentSpecification): Promise<Buffer> {
	const document = new PDFDocument({
		autoFirstPage: false,
		size: [...specification.pageSize],
		margins: letterMargins,
		compress: false,
		info: documentInformation(specification),
	});
	for (const [name, modulePath] of Object.entries(typefaceFiles)) {
		document.registerFont(name, fileURLToPath(import.meta.resolve(modulePath)));
	}
	specification.render(document);
	return collectPdf(document);
}

function composeImagePdf(specification: DocumentSpecification, jpegPages: readonly Buffer[]): Promise<Buffer> {
	const [pageWidth, pageHeight] = specification.pageSize;
	const document = new PDFDocument({ autoFirstPage: false, compress: false, info: documentInformation(specification) });
	for (const jpegPage of jpegPages) {
		document.addPage({ size: [pageWidth, pageHeight], margin: 0 });
		document.image(jpegPage, 0, 0, { width: pageWidth, height: pageHeight });
	}
	return collectPdf(document);
}

const encodeJpeg = (raster: ColorRaster, quality: number): Buffer => jpeg.encode({ width: raster.width, height: raster.height, data: raster.rgba, comments: [syntheticNotice] }, quality).data;

async function captureDocument(pdfium: Pdfium, specification: DocumentSpecification, sourcePdf: Buffer): Promise<Buffer> {
	const random = createRandomSource(specification.fileStem);
	switch (specification.captureMethod) {
		case "digital":
			return sourcePdf;
		case "scanned": {
			const pages = rasterizePages(pdfium, sourcePdf, scanResolutionDotsPerInch).map((page) => encodeJpeg(simulateFlatbedScan(page, random), 68));
			return composeImagePdf(specification, pages);
		}
		case "photographed": {
			const [receipt] = rasterizePages(pdfium, sourcePdf, photographResolutionDotsPerInch);
			return encodeJpeg(simulateReceiptPhotograph(receipt, random), 80);
		}
	}
}

function hasValidIbanChecksum(iban: string): boolean {
	const compact = iban.replace(/ /g, "");
	const digits = `${compact.slice(4)}${compact.slice(0, 4)}`.replace(/[A-Z]/g, (letter) => String(letter.charCodeAt(0) - 55));
	return BigInt(digits) % 97n === 1n;
}

function verifySourcePdf(specification: DocumentSpecification, pageTexts: readonly string[]): void {
	const failures: string[] = [];
	if (pageTexts.length !== specification.pageCount) failures.push(`declares ${specification.pageCount} pages but renders ${pageTexts.length}`);
	const text = pageTexts.join(" ").replace(/\s+/g, " ");
	const printedValues: Array<[string, string]> = [
		["sender", specification.sender],
		["document_date", specification.documentDate.printed],
		...Object.entries(specification.fields).map(([key, field]): [string, string] => [key, field.printed]),
	];
	if (specification.person !== "household") printedValues.push(...specification.person.split(" ").map((namePart): [string, string] => ["person", namePart]));
	for (const [label, printed] of printedValues) {
		if (!text.includes(printed)) failures.push(`${label} "${printed}" is not printed`);
	}
	for (const [printedIban] of text.matchAll(/\b[A-Z]{2}\d{2}(?: ?[0-9A-Z]{4}){3,7}(?: ?[0-9A-Z]{1,3})?\b/g)) {
		if (!hasValidIbanChecksum(printedIban)) failures.push(`IBAN "${printedIban}" fails the ISO 13616 checksum`);
	}
	if (failures.length > 0) throw new Error(`${specification.fileStem}: ${failures.join("; ")}`);
}

function verifyCapturedDocument(pdfium: Pdfium, specification: DocumentSpecification, bytes: Buffer): void {
	const format = captureFormats[specification.captureMethod];
	if (format.mediaType === "image/jpeg") {
		if (bytes[0] !== 0xff || bytes[1] !== 0xd8) throw new Error(`${specification.fileStem}: output is not a JPEG stream`);
		return;
	}
	const characterCounts = extractPageTexts(pdfium, bytes).map((text) => text.replace(/\s/g, "").length);
	if (characterCounts.length !== specification.pageCount) throw new Error(`${specification.fileStem}: output has ${characterCounts.length} pages`);
	const textLayerMatches = format.hasTextLayer ? characterCounts.every((count) => count > 0) : characterCounts.every((count) => count === 0);
	if (!textLayerMatches) throw new Error(`${specification.fileStem}: text characters per page ${characterCounts.join(", ")} contradict has_text_layer ${format.hasTextLayer}`);
}

function describeExpectedExtraction(specification: DocumentSpecification) {
	const format = captureFormats[specification.captureMethod];
	return {
		file_name: `${specification.fileStem}.${format.extension}`,
		media_type: format.mediaType,
		capture_method: specification.captureMethod,
		has_text_layer: format.hasTextLayer,
		page_count: specification.pageCount,
		language: specification.language,
		category: specification.category,
		sender: specification.sender,
		person: specification.person,
		document_date: specification.documentDate.value,
		title_hint: specification.titleHint,
		is_non_archival: specification.isNonArchival,
		fields: specification.fields,
	};
}

const pdfium = await loadPdfium();
const generatedFiles: Array<{ fileName: string; bytes: Buffer }> = [];
const expectations = [];
for (const specification of documentCatalog) {
	const sourcePdf = await renderSourcePdf(specification);
	verifySourcePdf(specification, extractPageTexts(pdfium, sourcePdf));
	const captured = await captureDocument(pdfium, specification, sourcePdf);
	verifyCapturedDocument(pdfium, specification, captured);
	const expectation = describeExpectedExtraction(specification);
	generatedFiles.push({ fileName: expectation.file_name, bytes: captured });
	expectations.push(expectation);
}
const manifest = { household_members: householdMembers, documents: expectations };
generatedFiles.push({ fileName: "expected_extraction.json", bytes: Buffer.from(`${JSON.stringify(manifest, null, "\t")}\n`) });

await rm(outputDirectory, { recursive: true, force: true });
await mkdir(outputDirectory, { recursive: true });
for (const { fileName, bytes } of generatedFiles) {
	await writeFile(join(outputDirectory, fileName), bytes);
	console.log(`${fileName.padEnd(48)} ${(bytes.length / 1024).toFixed(0).padStart(5)} KiB`);
}
const totalBytes = generatedFiles.reduce((total, file) => total + file.bytes.length, 0);
console.log(`${generatedFiles.length} files, ${(totalBytes / 1024 / 1024).toFixed(2)} MiB in ${outputDirectory}`);
