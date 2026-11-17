import {
	bankStatement,
	dentalInvoice,
	electricityInvoice,
	generalTermsAndConditions,
	heatingEngineerInvoice,
	householdContentsInsurancePolicy,
	incomeTaxAssessment,
	rentalContract,
	residenceRegistrationCertificate,
	softwareSubscriptionInvoice,
	supermarketReceipt,
	telecommunicationInvoice,
} from "./document_catalog.ts"
import { pageSizeA4, syntheticNotice } from "./document_layout.ts"
import { bookExcerpt, routerManual, scientificPaper } from "./publication_catalog.ts"
import type { ServiceInvoice } from "./document_catalog.ts"
import type { DocumentSpecification, PageSize } from "./document_layout.ts"
import type { Publication } from "./publication_catalog.ts"

export type CorpusSource = DocumentSpecification | Publication

type ScannedSheet = { kind: "page"; source: CorpusSource; pageIndex: number } | { kind: "blank"; pageSize: PageSize }

export type FileCapture =
	| { kind: "digital"; source: CorpusSource }
	| { kind: "digital_rewritten"; source: CorpusSource; creationDate: string }
	| { kind: "flatbed_scan"; sheets: ReadonlyArray<ScannedSheet>; dotsPerInch: number; quarterTurns: 0 | 1 | 2 | 3 }
	| { kind: "page_photograph"; source: CorpusSource }
	| { kind: "receipt_photograph"; source: CorpusSource }
	| { kind: "partial_download"; completeFile: FileCapture; retainedFraction: number }
	| { kind: "text_content"; text: string }

export type CollectionOutcome =
	| { kind: "archived"; document_key: string }
	| { kind: "set_aside" }
	| { kind: "ignored"; reason: "incomplete_download" | "empty_file" | "unrecognized_content" }
	| { kind: "unspecified"; reason: "several_documents_in_one_scan" }

interface CorpusDocument {
	key: string
	specification: DocumentSpecification
	displayedPath: string
	relatedDocuments?: ReadonlyArray<{ relation: "corrects"; documentKey: string }>
}

interface CorpusFile {
	path: string
	capture: FileCapture
	outcome: CollectionOutcome
}

export interface CorpusCase {
	key: string
	documents: ReadonlyArray<CorpusDocument>
	files: ReadonlyArray<CorpusFile>
}

const archived = (document: CorpusDocument): CollectionOutcome => ({ kind: "archived", document_key: document.key })
const setAside: CollectionOutcome = { kind: "set_aside" }
const incompleteDownload: CollectionOutcome = { kind: "ignored", reason: "incomplete_download" }

const pagesOf = (
	source: CorpusSource,
	pageOrder = Array.from({ length: source.pageCount }, (_, index) => index),
): Array<ScannedSheet> => pageOrder.map((pageIndex) => ({ kind: "page", source, pageIndex }))

const flatbedScan = (
	sheets: ReadonlyArray<ScannedSheet>,
	options: { dotsPerInch?: number; quarterTurns?: 0 | 1 | 2 | 3 } = {},
): FileCapture => ({
	kind: "flatbed_scan",
	sheets,
	dotsPerInch: options.dotsPerInch ?? 150,
	quarterTurns: options.quarterTurns ?? 0,
})

function identicalFileInThreeFolders(): CorpusCase {
	const invoice: CorpusDocument = {
		key: "paperlark_invoice_2026_10",
		specification: softwareSubscriptionInvoice(),
		displayedPath: "Downloads/Invoice-PLK-2026-004817.pdf",
	}
	const capture: FileCapture = { kind: "digital", source: invoice.specification }
	return {
		key: "identical_file_in_three_folders",
		documents: [invoice],
		files: [
			"Downloads/Invoice-PLK-2026-004817.pdf",
			"Desktop/Invoice-PLK-2026-004817.pdf",
			"Cloud Storage/Rechnungen/Invoice-PLK-2026-004817.pdf",
		].map((path) => ({ path, capture, outcome: archived(invoice) })),
	}
}

function rewrittenDigitalDocument(): CorpusCase {
	const terms: CorpusDocument = {
		key: "nordkabel_terms_2026_07",
		specification: generalTermsAndConditions(),
		displayedPath: "Downloads/AGB_Nordkabel.pdf",
	}
	return {
		key: "rewritten_digital_document",
		documents: [terms],
		files: [
			{
				path: "Downloads/AGB_Nordkabel.pdf",
				capture: { kind: "digital", source: terms.specification },
				outcome: archived(terms),
			},
			{
				path: "Cloud Storage/Verträge/Nordkabel AGB.pdf",
				capture: { kind: "digital_rewritten", source: terms.specification, creationDate: "2026-11-12T19:42:00Z" },
				outcome: archived(terms),
			},
		],
	}
}

function digitalDocumentAndFlatbedScan(): CorpusCase {
	const statement: CorpusDocument = {
		key: "stadtwerke_annual_statement_2026",
		specification: electricityInvoice(),
		displayedPath: "Downloads/Jahresabrechnung_Strom_2026.pdf",
	}
	return {
		key: "digital_document_and_flatbed_scan",
		documents: [statement],
		files: [
			{
				path: "Downloads/Jahresabrechnung_Strom_2026.pdf",
				capture: { kind: "digital", source: statement.specification },
				outcome: archived(statement),
			},
			{
				path: "Documents/Scans/scan_0011.pdf",
				capture: flatbedScan(pagesOf(statement.specification)),
				outcome: archived(statement),
			},
		],
	}
}

function digitalDocumentAndPhotograph(): CorpusCase {
	const invoice: CorpusDocument = {
		key: "vossberg_dental_invoice_2026_08",
		specification: dentalInvoice(),
		displayedPath: "Downloads/Rechnung_ZA-2026-0193.pdf",
	}
	return {
		key: "digital_document_and_photograph",
		documents: [invoice],
		files: [
			{
				path: "Downloads/Rechnung_ZA-2026-0193.pdf",
				capture: { kind: "digital", source: invoice.specification },
				outcome: archived(invoice),
			},
			{
				path: "Desktop/IMG_4821.jpg",
				capture: { kind: "page_photograph", source: invoice.specification },
				outcome: archived(invoice),
			},
		],
	}
}

function twoFlatbedScansOfOneDocument(): CorpusCase {
	const assessment: CorpusDocument = {
		key: "income_tax_assessment_2025",
		specification: incomeTaxAssessment(),
		displayedPath: "Documents/Scans/scan_0016.pdf",
	}
	return {
		key: "two_flatbed_scans_of_one_document",
		documents: [assessment],
		files: [
			{
				path: "Documents/Scans/scan_0003.pdf",
				capture: flatbedScan(pagesOf(assessment.specification), { dotsPerInch: 110 }),
				outcome: archived(assessment),
			},
			{
				path: "Documents/Scans/scan_0016.pdf",
				capture: flatbedScan(pagesOf(assessment.specification), { dotsPerInch: 150 }),
				outcome: archived(assessment),
			},
		],
	}
}

function duplexScanWithBlankReverseSide(): CorpusCase {
	const certificate: CorpusDocument = {
		key: "residence_registration_certificate_2026",
		specification: residenceRegistrationCertificate(),
		displayedPath: "Downloads/Meldebescheinigung.pdf",
	}
	return {
		key: "duplex_scan_with_blank_reverse_side",
		documents: [certificate],
		files: [
			{
				path: "Downloads/Meldebescheinigung.pdf",
				capture: { kind: "digital", source: certificate.specification },
				outcome: archived(certificate),
			},
			{
				path: "Documents/Scans/scan_0008.pdf",
				capture: flatbedScan([...pagesOf(certificate.specification), { kind: "blank", pageSize: pageSizeA4 }]),
				outcome: archived(certificate),
			},
		],
	}
}

function scanWithReorderedPages(): CorpusCase {
	const contract: CorpusDocument = {
		key: "wohnungsbau_rental_contract_2026",
		specification: rentalContract(),
		displayedPath: "Cloud Storage/Verträge/Mietvertrag_Am_Lindenhang_7.pdf",
	}
	return {
		key: "scan_with_reordered_pages",
		documents: [contract],
		files: [
			{
				path: "Cloud Storage/Verträge/Mietvertrag_Am_Lindenhang_7.pdf",
				capture: { kind: "digital", source: contract.specification },
				outcome: archived(contract),
			},
			{
				path: "Documents/Scans/scan_0014.pdf",
				capture: flatbedScan(pagesOf(contract.specification, [2, 0, 1])),
				outcome: archived(contract),
			},
		],
	}
}

function rotatedScans(): CorpusCase {
	const policy: CorpusDocument = {
		key: "lindenhain_household_contents_policy_2026",
		specification: householdContentsInsurancePolicy(),
		displayedPath: "Downloads/Versicherungsschein_Hausrat.pdf",
	}
	const receipt: CorpusDocument = {
		key: "frischemarkt_receipt_2026_10_31",
		specification: supermarketReceipt(),
		displayedPath: "Documents/Scans/scan_0012.pdf",
	}
	return {
		key: "rotated_scans",
		documents: [policy, receipt],
		files: [
			{
				path: "Downloads/Versicherungsschein_Hausrat.pdf",
				capture: { kind: "digital", source: policy.specification },
				outcome: archived(policy),
			},
			{
				path: "Documents/Scans/scan_0006.pdf",
				capture: flatbedScan(pagesOf(policy.specification), { quarterTurns: 1 }),
				outcome: archived(policy),
			},
			{
				path: "Cloud Storage/Kamera-Uploads/IMG_5307.jpg",
				capture: { kind: "receipt_photograph", source: receipt.specification },
				outcome: archived(receipt),
			},
			{
				path: "Documents/Scans/scan_0012.pdf",
				capture: flatbedScan(pagesOf(receipt.specification), { quarterTurns: 2 }),
				outcome: archived(receipt),
			},
		],
	}
}

function monthlyInvoiceSeries(): CorpusCase {
	const billingMonths = ["2026-05", "2026-06", "2026-07", "2026-08", "2026-09", "2026-10"] as const
	const browserDownloadNames = billingMonths.map((_, index) =>
		index === 0 ? "Downloads/Rechnung.pdf" : `Downloads/Rechnung (${index}).pdf`,
	)
	const invoices = billingMonths.map((billingMonth, index): CorpusDocument => ({
		key: `nordkabel_invoice_${billingMonth.replace("-", "_")}`,
		specification: telecommunicationInvoice(billingMonth),
		displayedPath: browserDownloadNames[index]!,
	}))
	return {
		key: "monthly_invoice_series",
		documents: invoices,
		files: invoices.map((invoice) => ({
			path: invoice.displayedPath,
			capture: { kind: "digital", source: invoice.specification },
			outcome: archived(invoice),
		})),
	}
}

const ostermannMaintenanceItems = (materialCents: number): ServiceInvoice["items"] => [
	{ description: "Anfahrtspauschale", quantity: 1, unit: "Pausch.", unitCents: 4641 },
	{ description: "Arbeitszeit Monteur", quantity: 1.5, unit: "Std.", unitCents: 8568 },
	{ description: "Material laut Lieferschein", quantity: 1, unit: "Pausch.", unitCents: materialCents },
]

function invoicesDifferingInOneDigit(): CorpusCase {
	const maintenance = { invoiceDate: "2026-11-04", orderDate: "2026-10-27", serviceDate: "2026-11-02" } as const
	const work = "die Wartung der Gas-Brennwerttherme"
	const invoices = [
		{ invoiceNumber: "HT-2026-0871", materialCents: 3980, path: "Documents/Scans/scan_0019.pdf" },
		{ invoiceNumber: "HT-2026-0872", materialCents: 6980, path: "Documents/Scans/scan_0020.pdf" },
	].map(({ invoiceNumber, materialCents, path }) => ({
		path,
		document: {
			key: `ostermann_invoice_${invoiceNumber.slice(3).replace("-", "_")}`,
			specification: heatingEngineerInvoice({
				invoiceNumber,
				...maintenance,
				work,
				items: ostermannMaintenanceItems(materialCents),
			}),
			displayedPath: path,
		} satisfies CorpusDocument,
	}))
	return {
		key: "invoices_differing_in_one_digit",
		documents: invoices.map(({ document }) => document),
		files: invoices.map(({ path, document }) => ({
			path,
			capture: flatbedScan(pagesOf(document.specification)),
			outcome: archived(document),
		})),
	}
}

function invoiceAndCorrectedInvoice(): CorpusCase {
	const repair = { orderDate: "2026-09-08", serviceDate: "2026-09-11", work: "den Austausch der Küchenarmatur" }
	const repairItems = (fittingCents: number): ServiceInvoice["items"] => [
		{ description: "Anfahrtspauschale", quantity: 1, unit: "Pausch.", unitCents: 4641 },
		{ description: "Arbeitszeit Monteur", quantity: 1, unit: "Std.", unitCents: 8568 },
		{ description: "Einhebelmischer Küche", quantity: 1, unit: "Stk.", unitCents: fittingCents },
		{ description: "Kleinmaterial", quantity: 1, unit: "Pausch.", unitCents: 1240 },
	]
	const original: CorpusDocument = {
		key: "ostermann_invoice_2026_0655",
		specification: heatingEngineerInvoice({
			invoiceNumber: "HT-2026-0655",
			invoiceDate: "2026-09-15",
			...repair,
			items: repairItems(14900),
		}),
		displayedPath: "Downloads/Ostermann_Rechnung_HT-2026-0655.pdf",
	}
	const correction: CorpusDocument = {
		key: "ostermann_invoice_2026_0679",
		specification: heatingEngineerInvoice({
			invoiceNumber: "HT-2026-0679",
			invoiceDate: "2026-09-22",
			...repair,
			items: repairItems(12900),
			replacedInvoice: {
				invoiceNumber: "HT-2026-0655",
				invoiceDate: "2026-09-15",
				reason: "Für den Einhebelmischer war dort ein falscher Preis angegeben.",
			},
		}),
		displayedPath: "Downloads/Ostermann_Rechnung_HT-2026-0679.pdf",
		relatedDocuments: [{ relation: "corrects", documentKey: original.key }],
	}
	return {
		key: "invoice_and_corrected_invoice",
		documents: [original, correction],
		files: [original, correction].map((document) => ({
			path: document.displayedPath,
			capture: { kind: "digital", source: document.specification },
			outcome: archived(document),
		})),
	}
}

function consecutiveBankStatements(): CorpusCase {
	const statements = (["2026-09", "2026-10"] as const).map((month): CorpusDocument => ({
		key: `muehlbach_statement_${month.replace("-", "_")}`,
		specification: bankStatement(month),
		displayedPath: `Cloud Storage/Bank/Kontoauszug_0471128305_${month.replace("-", "")}.pdf`,
	}))
	return {
		key: "consecutive_bank_statements",
		documents: statements,
		files: statements.map((statement) => ({
			path: statement.displayedPath,
			capture: { kind: "digital", source: statement.specification },
			outcome: archived(statement),
		})),
	}
}

function publicationsOutsideTheHousehold(): CorpusCase {
	const publications: ReadonlyArray<readonly [string, Publication]> = [
		["Downloads/Nordbox_7_Bedienungsanleitung.pdf", routerManual()],
		["Downloads/marwitz_kerber_2026.pdf", scientificPaper()],
		["Desktop/Leseprobe_Die_Uhrmacherin_von_Talbrueck.pdf", bookExcerpt()],
	]
	return {
		key: "publications_outside_the_household",
		documents: [],
		files: publications.map(([path, source]) => ({ path, capture: { kind: "digital", source }, outcome: setAside })),
	}
}

function incompleteDownloads(): CorpusCase {
	const safariBundle = "Downloads/Kontoauszug_0471128305_202610.pdf.download"
	return {
		key: "incomplete_downloads",
		documents: [],
		files: [
			{
				path: "Downloads/Unconfirmed 418273.crdownload",
				capture: {
					kind: "partial_download",
					completeFile: { kind: "digital", source: scientificPaper() },
					retainedFraction: 0.4,
				},
				outcome: incompleteDownload,
			},
			{
				path: `${safariBundle}/Kontoauszug_0471128305_202610.pdf`,
				capture: {
					kind: "partial_download",
					completeFile: { kind: "digital", source: bankStatement("2026-10") },
					retainedFraction: 0.25,
				},
				outcome: incompleteDownload,
			},
			{
				path: `${safariBundle}/Info.plist`,
				capture: {
					kind: "text_content",
					text: [
						'<?xml version="1.0" encoding="UTF-8"?>',
						'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
						'<plist version="1.0">',
						"<dict>",
						"\t<key>DownloadEntryIdentifier</key>",
						"\t<string>5C1E0B7A-3D42-4F0E-9A61-2B8D7C4E1F93</string>",
						"\t<key>DownloadEntryPath</key>",
						`\t<string>~/${safariBundle}/Kontoauszug_0471128305_202610.pdf</string>`,
						"\t<key>DownloadEntryURL</key>",
						"\t<string>https://banking.muehlbach-bank.example/postbox/statements/2026-10.pdf</string>",
						"</dict>",
						"</plist>",
						"",
					].join("\n"),
				},
				outcome: incompleteDownload,
			},
		],
	}
}

function emptyAndMislabeledFiles(): CorpusCase {
	return {
		key: "empty_and_mislabeled_files",
		documents: [],
		files: [
			{
				path: "Desktop/Unbenannt.pdf",
				capture: { kind: "text_content", text: "" },
				outcome: { kind: "ignored", reason: "empty_file" },
			},
			{
				path: "Downloads/Rechnungsadresse.pdf",
				capture: {
					kind: "text_content",
					text: `Rechnungsadresse für Bestellungen\n\nJonas Becker\nAm Lindenhang 7\n31846 Talbrück\n\n${syntheticNotice}\n`,
				},
				outcome: { kind: "ignored", reason: "unrecognized_content" },
			},
		],
	}
}

function twoDocumentsInOneStackScan(): CorpusCase {
	const descaling = heatingEngineerInvoice({
		invoiceNumber: "HT-2026-0538",
		invoiceDate: "2026-06-10",
		orderDate: "2026-06-01",
		serviceDate: "2026-06-05",
		work: "die Entkalkung des Durchlauferhitzers",
		items: [
			{ description: "Anfahrtspauschale", quantity: 1, unit: "Pausch.", unitCents: 4641 },
			{ description: "Arbeitszeit Monteur", quantity: 0.75, unit: "Std.", unitCents: 8568 },
			{ description: "Entkalkungsmittel", quantity: 1, unit: "Stk.", unitCents: 1890 },
		],
	})
	return {
		key: "two_documents_in_one_stack_scan",
		documents: [],
		files: [
			{
				path: "Documents/Scans/scan_0009.pdf",
				capture: flatbedScan([...pagesOf(descaling), ...pagesOf(telecommunicationInvoice("2026-04"))]),
				outcome: { kind: "unspecified", reason: "several_documents_in_one_scan" },
			},
		],
	}
}

export const corpusCases: ReadonlyArray<CorpusCase> = [
	identicalFileInThreeFolders(),
	rewrittenDigitalDocument(),
	digitalDocumentAndFlatbedScan(),
	digitalDocumentAndPhotograph(),
	twoFlatbedScansOfOneDocument(),
	duplexScanWithBlankReverseSide(),
	scanWithReorderedPages(),
	rotatedScans(),
	monthlyInvoiceSeries(),
	invoicesDifferingInOneDigit(),
	invoiceAndCorrectedInvoice(),
	consecutiveBankStatements(),
	publicationsOutsideTheHousehold(),
	incompleteDownloads(),
	emptyAndMislabeledFiles(),
	twoDocumentsInOneStackScan(),
]
