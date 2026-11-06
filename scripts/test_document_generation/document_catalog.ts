import {
	computeGermanIban,
	contentWidth,
	drawDefinitionList,
	drawLetterFooter,
	drawLetterhead,
	drawOrganizationMark,
	drawParagraphs,
	drawSections,
	drawSingleLine,
	drawTable,
	euroField,
	formatEnglishDate,
	formatEuro,
	formatGermanDate,
	formatGermanDecimal,
	germanDateField,
	groupIban,
	ibanField,
	leftMargin,
	literalField,
	millimetre,
	pageSizeA4,
	rightEdge,
	vatIncludedInGross,
} from "./document_layout.ts"
import type { DocumentSpecification, Organization, PrintedValue } from "./document_layout.ts"

const householdAddressLines = ["Am Lindenhang 7", "31846 Talbrück"]
const euroCurrency: PrintedValue = { value: "EUR", printed: "€" }
const threeMonths: PrintedValue = { value: "P3M", printed: "drei Monate" }

const banks = {
	muehlbach: { name: "Mühlbach Bank AG", code: "96051240" },
	wiesenfurt: { name: "Wiesenfurter Handelsbank AG", code: "93024580" },
	kreditverein: { name: "Kreditverein Talbrück eG", code: "97011320" },
}

const nordkabel: Organization = {
	name: "Nordkabel Kommunikation GmbH",
	addressLines: ["Kaistraße 12", "24113 Wiesenfurt"],
	contactLines: ["service@nordkabel.example", "www.nordkabel.example"],
	registrationLines: ["Geschäftsführung:", "Tobias Rehfeld, Annika Lorenzen", "Amtsgericht Wiesenfurt HRB 40718"],
	bankName: banks.wiesenfurt.name,
	iban: computeGermanIban(banks.wiesenfurt.code, "0418820037"),
	accentColor: "#0b6e6e",
	monogram: "NK",
}

const stadtwerke: Organization = {
	name: "Stadtwerke Talbrück GmbH",
	addressLines: ["Gaswerkstraße 3", "31846 Talbrück"],
	contactLines: ["service@stadtwerke.example", "Kundenzentrum:", "Mo bis Fr 8 bis 18 Uhr"],
	registrationLines: ["Geschäftsführer:", "Dr. Bernd Achterberg", "Amtsgericht Talbrück HRB 1207"],
	bankName: banks.kreditverein.name,
	iban: computeGermanIban(banks.kreditverein.code, "0300418225"),
	accentColor: "#1d4f91",
	monogram: "SW",
}

const wohnungsbau: Organization = {
	name: "Talbrücker Wohnungsbau GmbH",
	addressLines: ["Rathausplatz 9", "31846 Talbrück"],
	contactLines: ["vermietung@wohnbau.example"],
	registrationLines: ["Geschäftsführerin:", "Dorothea Kranich", "Amtsgericht Talbrück HRB 2214"],
	bankName: banks.muehlbach.name,
	iban: computeGermanIban(banks.muehlbach.code, "0220417090"),
	accentColor: "#7a4b1f",
	monogram: "TW",
}

const lindenhain: Organization = {
	name: "Lindenhain Versicherung AG",
	addressLines: ["Am Schlossgarten 14", "37120 Hollerbeck"],
	contactLines: ["service@lindenhain.example", "Schadenmeldung online", "rund um die Uhr"],
	registrationLines: [
		"Vorstand: Dr. Felix Brandauer",
		"(Vorsitz), Svenja Ohlendorf",
		"Amtsgericht Hollerbeck",
		"HRB 5531",
	],
	bankName: banks.wiesenfurt.name,
	iban: computeGermanIban(banks.wiesenfurt.code, "0773104820"),
	accentColor: "#2f6b3a",
	monogram: "LV",
}

const finanzamt: Organization = {
	name: "Finanzamt Talbrück",
	addressLines: ["Am Amtshof 2", "31846 Talbrück"],
	contactLines: ["poststelle@finanzamt.example", "Servicezentrum:", "Mo bis Fr 8 bis 12 Uhr"],
	registrationLines: ["Bitte geben Sie bei Zahlungen", "stets die Steuernummer an."],
	bankName: banks.muehlbach.name,
	iban: computeGermanIban(banks.muehlbach.code, "0031846000"),
	accentColor: "#222222",
	letterheadSubtitle: "Postanschrift: Postfach 1120, 31840 Talbrück",
}

const muehlbachBank: Organization = {
	name: "Mühlbach Bank AG",
	addressLines: ["Marktplatz 5", "31846 Talbrück"],
	contactLines: ["service@muehlbach-bank.example", "Kartensperre: siehe", "Kartenrückseite"],
	registrationLines: ["Vorstand: Henning Kalthoff,", "Mareike Sanders", "Amtsgericht Talbrück HRB 310"],
	bankName: banks.muehlbach.name,
	iban: computeGermanIban(banks.muehlbach.code, "0100500013"),
	accentColor: "#7a1f2b",
	monogram: "MB",
}

const dentalPractice: Organization = {
	name: "Zahnarztpraxis Dr. Henrike Vossberg",
	addressLines: ["Lindenallee 18", "31846 Talbrück"],
	contactLines: ["praxis@vossberg.example", "Sprechzeiten nach Vereinbarung"],
	registrationLines: ["Zahnärztin für Kinder- und", "Jugendzahnheilkunde"],
	bankName: banks.kreditverein.name,
	iban: computeGermanIban(banks.kreditverein.code, "0605190031"),
	accentColor: "#2a7da8",
	monogram: "HV",
}

const stadtTalbrueck: Organization = {
	name: "Stadt Talbrück",
	addressLines: ["Rathausplatz 1", "31846 Talbrück"],
	contactLines: ["buergeramt@talbrueck.example", "Bürgeramt:", "Mo bis Fr 8 bis 13 Uhr"],
	registrationLines: ["Der Bürgermeister", "Fachbereich Bürgerdienste"],
	bankName: banks.kreditverein.name,
	iban: computeGermanIban(banks.kreditverein.code, "0000100014"),
	accentColor: "#1f3a5f",
	letterheadSubtitle: "Der Bürgermeister · Bürgeramt",
}

const sumOf = (values: ReadonlyArray<number>): number => values.reduce((total, value) => total + value, 0)

function drawPageLabel(document: PDFKit.PDFDocument, label: string): void {
	const bottomMargin = document.page.margins.bottom
	document.page.margins.bottom = 0
	drawSingleLine(
		document.font("SansRegular").fontSize(7.5).fillColor("#555555"),
		label,
		leftMargin,
		pageSizeA4[1] - 40,
		{ width: contentWidth, align: "center" },
	)
	document.fillColor("#000000")
	document.page.margins.bottom = bottomMargin
}

function drawBankDetails(document: PDFKit.PDFDocument, organization: Organization, top: number): number {
	return drawDefinitionList(
		document,
		[
			["Empfänger", organization.name],
			["IBAN", groupIban(organization.iban)],
			["Kreditinstitut", organization.bankName],
		],
		{ left: leftMargin + 12, top, labelWidth: 80, fontSize: 10 },
	)
}

const telecommunicationInvoiceNumber = "NK-2026-1048-3391"
const telecommunicationCharges: ReadonlyArray<readonly [string, string, number]> = [
	["Glasfaser 250 (monatlicher Grundpreis)", "01.10.2026 – 31.10.2026", 3999],
	["Mobilfunktarif Allnet M (monatlicher Grundpreis)", "01.10.2026 – 31.10.2026", 1999],
	["Miete WLAN-Router Nordbox 7", "01.10.2026 – 31.10.2026", 499],
	["Verbindungen außerhalb des Inklusivvolumens", "01.09.2026 – 30.09.2026", 216],
]
const telecommunicationTotalCents = sumOf(telecommunicationCharges.map(([, , cents]) => cents))

function telecommunicationInvoice(): DocumentSpecification {
	const invoiceDate = "2026-10-05"
	const dueDate = "2026-10-20"
	const { netCents, taxCents } = vatIncludedInGross(telecommunicationTotalCents, 19)
	return {
		fileStem: "telecommunication_invoice_digital",
		captureMethod: "digital",
		pageSize: pageSizeA4,
		pageCount: 1,
		language: "de",
		category: "Invoice",
		sender: nordkabel.name,
		person: "Jonas Becker",
		documentDate: germanDateField(invoiceDate),
		titleHint: "Nordkabel Kommunikation Invoice October 2026",
		isNonArchival: false,
		fields: {
			amount: euroField(telecommunicationTotalCents),
			currency: euroCurrency,
			due_date: germanDateField(dueDate),
			iban: ibanField(nordkabel.iban),
			invoice_number: literalField(telecommunicationInvoiceNumber),
		},
		render(document) {
			document.addPage()
			let cursor = drawLetterhead(document, nordkabel, {
				recipientLines: ["Herrn", "Jonas Becker", ...householdAddressLines],
				referenceRows: [
					["Kundennummer", "4100 2738 51"],
					["Rechnungsnummer", telecommunicationInvoiceNumber],
					["Rechnungsdatum", formatGermanDate(invoiceDate)],
					["Seite", "1 von 1"],
				],
				subject: "Ihre Rechnung für Oktober 2026",
			})
			cursor = drawParagraphs(
				document,
				[
					"Sehr geehrter Herr Becker,",
					"vielen Dank, dass Sie sich für Nordkabel entschieden haben. Mit dieser Rechnung berechnen wir Ihnen die monatlichen Grundpreise für Oktober 2026 sowie die Verbindungen aus dem Vormonat.",
				],
				{ top: cursor },
			)
			cursor = drawTable(document, {
				left: leftMargin,
				top: cursor + 4,
				columns: [
					{ header: "Leistung", width: 245 },
					{ header: "Zeitraum", width: 130 },
					{ header: "Betrag", width: contentWidth - 375, align: "right" },
				],
				rows: telecommunicationCharges.map(([description, period, cents]) => [description, period, formatEuro(cents)]),
				summaryRows: [
					["Summe netto", "", formatEuro(netCents)],
					["Umsatzsteuer 19 %", "", formatEuro(taxCents)],
					["Rechnungsbetrag", "", formatEuro(telecommunicationTotalCents)],
				],
				bandColor: "#e1efee",
			})
			cursor = drawParagraphs(
				document,
				[
					`Bitte überweisen Sie den Rechnungsbetrag von ${formatEuro(telecommunicationTotalCents)} bis zum ${formatGermanDate(dueDate)} unter Angabe der Rechnungsnummer ${telecommunicationInvoiceNumber} auf das folgende Konto:`,
				],
				{ top: cursor + 18 },
			)
			cursor = drawBankDetails(document, nordkabel, cursor + 2)
			drawParagraphs(
				document,
				[
					"Den Einzelverbindungsnachweis und alle früheren Rechnungen finden Sie jederzeit in Ihrem Kundenportal unter www.nordkabel.example.",
					"Mit freundlichen Grüßen\nIhr Nordkabel Kundenservice",
				],
				{ top: cursor + 14 },
			)
			drawLetterFooter(document, nordkabel)
		},
	}
}

const electricityInvoiceNumber = "JA-2026-0381547"
const electricityConsumptionKilowattHours = 50904 - 48213
const electricityEnergyPriceHundredthsOfCent = 3142
const electricityBaseChargeCents = 1190
const electricityInstallmentCents = 9200
const electricityEnergyCents = Math.round(
	(electricityConsumptionKilowattHours * electricityEnergyPriceHundredthsOfCent) / 100,
)
const electricityNetCents = electricityEnergyCents + 12 * electricityBaseChargeCents
const electricityTaxCents = Math.round(electricityNetCents * 0.19)
const electricityGrossCents = electricityNetCents + electricityTaxCents
const electricityBalanceCents = electricityGrossCents - 12 * electricityInstallmentCents

function electricityInvoice(): DocumentSpecification {
	const invoiceDate = "2026-09-22"
	const dueDate = "2026-10-06"
	return {
		fileStem: "electricity_invoice_scanned",
		captureMethod: "scanned",
		pageSize: pageSizeA4,
		pageCount: 1,
		language: "de",
		category: "Invoice",
		sender: stadtwerke.name,
		person: "household",
		documentDate: germanDateField(invoiceDate),
		titleHint: "Stadtwerke Talbrück Electricity Annual Statement 2025-2026",
		isNonArchival: false,
		fields: {
			amount: euroField(electricityBalanceCents),
			currency: euroCurrency,
			due_date: germanDateField(dueDate),
			iban: ibanField(stadtwerke.iban),
			invoice_number: literalField(electricityInvoiceNumber),
		},
		render(document) {
			document.addPage()
			let cursor = drawLetterhead(document, stadtwerke, {
				recipientLines: ["Frau Mira Wiśniewska", "Herrn Jonas Becker", ...householdAddressLines],
				referenceRows: [
					["Vertragskonto", "300 418 225"],
					["Rechnungsnummer", electricityInvoiceNumber],
					["Rechnungsdatum", formatGermanDate(invoiceDate)],
					["Zählernummer", "1ESY 1160 4428 17"],
				],
				subject: "Jahresverbrauchsabrechnung Strom vom 01.09.2025 bis 31.08.2026",
			})
			cursor = drawParagraphs(
				document,
				[
					"Sehr geehrte Frau Wiśniewska, sehr geehrter Herr Becker,",
					"mit diesem Schreiben erhalten Sie die Abrechnung Ihres Stromverbrauchs für die Lieferstelle Am Lindenhang 7, 2. Obergeschoss links. Grundlage ist Ihr Tarif Talbrück Strom Basis.",
				],
				{ top: cursor, fontSize: 9.5 },
			)
			cursor = drawTable(document, {
				left: leftMargin,
				top: cursor + 2,
				fontSize: 8.5,
				columns: [
					{ header: "Zählernummer", width: 110 },
					{ header: "Zählerstand 31.08.2025", width: 120, align: "right" },
					{ header: "Zählerstand 31.08.2026", width: 120, align: "right" },
					{ header: "Verbrauch", width: contentWidth - 350, align: "right" },
				],
				rows: [
					[
						"1ESY 1160 4428 17",
						"48.213 kWh",
						"50.904 kWh",
						`${electricityConsumptionKilowattHours.toLocaleString("de-DE")} kWh`,
					],
				],
				bandColor: "#e3eaf5",
			})
			cursor = drawTable(document, {
				left: leftMargin,
				top: cursor + 14,
				fontSize: 8.5,
				columns: [
					{ header: "Position", width: 170 },
					{ header: "Menge", width: 100, align: "right" },
					{ header: "Preis", width: 100, align: "right" },
					{ header: "Betrag", width: contentWidth - 370, align: "right" },
				],
				rows: [
					[
						"Arbeitspreis",
						`${electricityConsumptionKilowattHours.toLocaleString("de-DE")} kWh`,
						"31,42 ct/kWh",
						formatEuro(electricityEnergyCents),
					],
					[
						"Grundpreis",
						"12 Monate",
						`${formatGermanDecimal(electricityBaseChargeCents)} €/Monat`,
						formatEuro(12 * electricityBaseChargeCents),
					],
				],
				summaryRows: [
					["Summe netto", "", "", formatEuro(electricityNetCents)],
					["Umsatzsteuer 19 %", "", "", formatEuro(electricityTaxCents)],
					["Gesamtbetrag brutto", "", "", formatEuro(electricityGrossCents)],
					[
						"abzüglich geleisteter Abschläge",
						"12 Monate",
						`${formatGermanDecimal(electricityInstallmentCents)} €`,
						formatEuro(-12 * electricityInstallmentCents),
					],
					["Nachzahlung", "", "", formatEuro(electricityBalanceCents)],
				],
				bandColor: "#e3eaf5",
			})
			cursor = drawParagraphs(
				document,
				[
					`Bitte überweisen Sie den Nachzahlungsbetrag von ${formatEuro(electricityBalanceCents)} bis zum ${formatGermanDate(dueDate)} unter Angabe der Rechnungsnummer ${electricityInvoiceNumber} auf das folgende Konto:`,
				],
				{ top: cursor + 14, fontSize: 9.5 },
			)
			cursor = drawBankDetails(document, stadtwerke, cursor + 2)
			drawParagraphs(
				document,
				[
					`Ihr monatlicher Abschlag bleibt unverändert. Stromkennzeichnung: erneuerbare Energien 68 %, Erdgas 14 %, Kohle 12 %, sonstige fossile Energieträger 6 %; CO2-Emissionen 182 g/kWh.`,
					"Mit freundlichen Grüßen\nIhre Stadtwerke Talbrück",
				],
				{ top: cursor + 10, fontSize: 8.5 },
			)
			drawLetterFooter(document, stadtwerke)
		},
	}
}

const receiptCharacterWidth = 40
const receiptRow = (left: string, right: string): string =>
	`${left.padEnd(receiptCharacterWidth - right.length)}${right}`
const receiptRule = "-".repeat(receiptCharacterWidth)

interface ReceiptLine {
	text: string
	emphasis?: boolean
	centered?: boolean
}

function drawReceiptLines(
	document: PDFKit.PDFDocument,
	lines: ReadonlyArray<ReceiptLine>,
	area: { left: number; width: number; top: number },
): void {
	const fontSize = 7.6
	const lineHeight = fontSize * 1.32
	const width = document.font("MonospaceRegular").fontSize(fontSize).widthOfString("0".repeat(receiptCharacterWidth))
	const left = area.left + (area.width - width) / 2
	const top = area.top
	lines.forEach((line, index) => {
		document.font(line.emphasis ? "MonospaceBold" : "MonospaceRegular").fontSize(fontSize)
		drawSingleLine(document, line.text, left, top + index * lineHeight, {
			width,
			align: line.centered ? "center" : "left",
		})
	})
}

interface ReceiptItem {
	description: string
	detail?: string
	cents: number
	taxRatePercent: 7 | 19
}

function receiptTaxLines(items: ReadonlyArray<ReceiptItem>): Array<ReceiptLine> {
	const rates = [
		{ letter: "A", ratePercent: 7 },
		{ letter: "B", ratePercent: 19 },
	]
	const rows = rates
		.map(({ letter, ratePercent }) => ({
			letter,
			ratePercent,
			grossCents: sumOf(items.filter((item) => item.taxRatePercent === ratePercent).map((item) => item.cents)),
		}))
		.filter((row) => row.grossCents > 0)
		.map((row) => ({ ...row, ...vatIncludedInGross(row.grossCents, row.ratePercent) }))
	const column = (text: string, width: number) => text.padStart(width)
	const format = (label: string, net: number, tax: number, gross: number) =>
		`${label.padEnd(10)}${column(formatGermanDecimal(net), 10)}${column(formatGermanDecimal(tax), 10)}${column(formatGermanDecimal(gross), 10)}`
	return [
		{ text: `${"MwSt".padEnd(10)}${column("Netto", 10)}${column("Steuer", 10)}${column("Brutto", 10)}` },
		...rows.map((row) => ({
			text: format(
				`${row.letter} ${String(row.ratePercent).padStart(2)} %`,
				row.netCents,
				row.taxCents,
				row.grossCents,
			),
		})),
		{
			text: format(
				"Gesamt",
				sumOf(rows.map((row) => row.netCents)),
				sumOf(rows.map((row) => row.taxCents)),
				sumOf(rows.map((row) => row.grossCents)),
			),
		},
	]
}

function receiptItemLines(items: ReadonlyArray<ReceiptItem>): Array<ReceiptLine> {
	const taxLetter = (item: ReceiptItem) => (item.taxRatePercent === 7 ? "A" : "B")
	return items.flatMap((item) =>
		item.detail
			? [
					{ text: item.description },
					{ text: receiptRow(`  ${item.detail}`, `${formatGermanDecimal(item.cents)} ${taxLetter(item)}`) },
				]
			: [{ text: receiptRow(item.description, `${formatGermanDecimal(item.cents)} ${taxLetter(item)}`) }],
	)
}

const supermarketItems: ReadonlyArray<ReceiptItem> = [
	{ description: "Vollmilch 3,5 % 1 l", cents: 119, taxRatePercent: 7 },
	{ description: "Bio-Eier 10 Stück", cents: 349, taxRatePercent: 7 },
	{ description: "Roggenmischbrot 750 g", cents: 279, taxRatePercent: 7 },
	{ description: "Äpfel Elstar lose", detail: "1,206 kg x 2,49 EUR/kg", cents: 300, taxRatePercent: 7 },
	{ description: "Gouda jung 400 g", cents: 329, taxRatePercent: 7 },
	{ description: "Kaffee gemahlen 500 g", cents: 699, taxRatePercent: 7 },
	{ description: "Spülmittel 500 ml", cents: 145, taxRatePercent: 19 },
	{ description: "Küchenrolle 4 Rollen", cents: 299, taxRatePercent: 19 },
	{ description: "Mineralwasser 6 x 1,5 l", cents: 294, taxRatePercent: 19 },
	{ description: "Pfand", detail: "6 x 0,25", cents: 150, taxRatePercent: 19 },
]
const supermarketTotalCents = sumOf(supermarketItems.map((item) => item.cents))
const receiptPageSize = [80 * millimetre, 172 * millimetre] as const

function supermarketReceipt(): DocumentSpecification {
	const receiptNumber = "4471"
	const purchaseDate = "2026-10-31"
	const total = formatGermanDecimal(supermarketTotalCents)
	return {
		fileStem: "supermarket_receipt_photograph",
		captureMethod: "photographed",
		pageSize: receiptPageSize,
		pageCount: 1,
		language: "de",
		category: "Receipt",
		sender: "Frischemarkt Talbrück",
		person: "household",
		documentDate: germanDateField(purchaseDate),
		titleHint: "Frischemarkt Talbrück Receipt October 2026",
		isNonArchival: false,
		fields: {
			amount: { value: supermarketTotalCents / 100, printed: total },
			currency: literalField("EUR"),
			invoice_number: literalField(receiptNumber),
		},
		render(document) {
			document.addPage({ size: [...receiptPageSize], margin: 8 })
			const lines: Array<ReceiptLine> = [
				{ text: "FRISCHEMARKT TALBRÜCK", emphasis: true, centered: true },
				{ text: "Lindenallee 3, 31846 Talbrück", centered: true },
				{ text: "Mo bis Sa 7 bis 21 Uhr", centered: true },
				{ text: "" },
				{ text: receiptRow("", "EUR") },
				...receiptItemLines(supermarketItems),
				{ text: receiptRule },
				{ text: receiptRow("SUMME", `EUR ${total}`), emphasis: true },
				{ text: receiptRule },
				{ text: receiptRow("Kartenzahlung", `EUR ${total}`) },
				{ text: "Debitkarte ************4417" },
				{ text: "Kontaktlos  Genehmigungsnr. 836107" },
				{ text: "" },
				...receiptTaxLines(supermarketItems),
				{ text: receiptRule },
				{ text: receiptRow(`${formatGermanDate(purchaseDate)} 17:42`, `Bon-Nr. ${receiptNumber}`) },
				{ text: receiptRow("Filiale 0128  Kasse 3", "Bed. 12") },
				{ text: "TSE-Transaktion:    182214" },
				{ text: "TSE-Signaturzähler: 364428" },
				{ text: "TSE-Start: 2026-10-31T17:41:58" },
				{ text: "TSE-Ende:  2026-10-31T17:42:31" },
				{ text: "TSE-Seriennr.: 7f3ac91e04b8d2a6" },
				{ text: "" },
				{ text: "Vielen Dank für Ihren Einkauf!", emphasis: true, centered: true },
				{ text: "Frischemarkt Talbrück GmbH", centered: true },
			]
			drawReceiptLines(document, lines, { left: 0, width: receiptPageSize[0], top: 14 })
		},
	}
}

const hardwareStoreItems: ReadonlyArray<ReceiptItem> = [
	{ description: "Schrauben 4,0 x 40 mm 200 St.", cents: 899, taxRatePercent: 19 },
	{ description: "Dübel 8 mm 100 St.", cents: 449, taxRatePercent: 19 },
	{ description: "Wandfarbe weiß matt 10 l", cents: 3999, taxRatePercent: 19 },
	{ description: "Abdeckfolie 4 x 5 m", cents: 349, taxRatePercent: 19 },
	{ description: "Malerrolle Set 25 cm", cents: 1295, taxRatePercent: 19 },
	{ description: "Kreppband 30 mm x 50 m", detail: "2 x 2,79", cents: 558, taxRatePercent: 19 },
]

function hardwareStoreReceipt(): DocumentSpecification {
	const receiptNumber = "118204"
	const purchaseDate = "2026-10-17"
	const totalCents = sumOf(hardwareStoreItems.map((item) => item.cents))
	const tenderedCents = 10000
	return {
		fileStem: "hardware_store_receipt_scanned",
		captureMethod: "scanned",
		pageSize: pageSizeA4,
		pageCount: 1,
		language: "de",
		category: "Receipt",
		sender: "Werkhof Baumarkt GmbH",
		person: "household",
		documentDate: germanDateField(purchaseDate),
		titleHint: "Werkhof Baumarkt Receipt October 2026",
		isNonArchival: false,
		fields: {
			amount: { value: totalCents / 100, printed: formatGermanDecimal(totalCents) },
			currency: literalField("EUR"),
			invoice_number: literalField(receiptNumber),
		},
		render(document) {
			document.addPage()
			const stripLeft = 62 * millimetre
			const stripTop = 30 * millimetre
			const stripWidth = 80 * millimetre
			const stripHeight = 150 * millimetre
			document.rect(stripLeft + 2, stripTop + 2, stripWidth, stripHeight).fill("#d6d6d6")
			document.rect(stripLeft, stripTop, stripWidth, stripHeight).fill("#f2f1ec")
			document.fillColor("#2e2e2e")
			const lines: Array<ReceiptLine> = [
				{ text: "WERKHOF BAUMARKT", emphasis: true, centered: true },
				{ text: "Industriestraße 22, 31846 Talbrück", centered: true },
				{ text: "Werkhof Baumarkt GmbH", centered: true },
				{ text: "" },
				{ text: receiptRow("", "EUR") },
				...receiptItemLines(hardwareStoreItems),
				{ text: receiptRule },
				{ text: receiptRow("SUMME", `EUR ${formatGermanDecimal(totalCents)}`), emphasis: true },
				{ text: receiptRule },
				{ text: receiptRow("Gegeben bar", `EUR ${formatGermanDecimal(tenderedCents)}`) },
				{ text: receiptRow("Rückgeld", `EUR ${formatGermanDecimal(tenderedCents - totalCents)}`) },
				{ text: "" },
				...receiptTaxLines(hardwareStoreItems),
				{ text: receiptRule },
				{ text: receiptRow(`${formatGermanDate(purchaseDate)} 10:14`, `Beleg ${receiptNumber}`) },
				{ text: receiptRow("Markt 031  Kasse 5", "Bed. 207") },
				{ text: "TSE-Transaktion:    977341" },
				{ text: "TSE-Signaturzähler: 1953120" },
				{ text: "TSE-Start: 2026-10-17T10:13:02" },
				{ text: "TSE-Ende:  2026-10-17T10:14:19" },
				{ text: "" },
				{ text: "Umtausch nur mit Kassenbon", centered: true },
				{ text: "innerhalb von 30 Tagen.", centered: true },
			]
			drawReceiptLines(document, lines, { left: stripLeft, width: stripWidth, top: stripTop + 14 })
			document.fillColor("#000000")
		},
	}
}

const rentalContractNumber = "MV-0417-2026"
const rentComponents: ReadonlyArray<readonly [string, number]> = [
	["Grundmiete", 94000],
	["Vorauszahlung Betriebskosten", 21000],
	["Vorauszahlung Heizkosten und Warmwasser", 8500],
]
const rentTotalCents = sumOf(rentComponents.map(([, cents]) => cents))

function rentalContract(): DocumentSpecification {
	const signatureDate = "2026-03-12"
	const serifSections = { headingTypeface: "SerifBold", typeface: "SerifRegular", fontSize: 10 } as const
	const pageLabel = (page: number) => `Mietvertrag ${rentalContractNumber} · Seite ${page} von 3`
	return {
		fileStem: "rental_contract_digital",
		captureMethod: "digital",
		pageSize: pageSizeA4,
		pageCount: 3,
		language: "de",
		category: "Contract",
		sender: wohnungsbau.name,
		person: "household",
		documentDate: germanDateField(signatureDate),
		titleHint: "Talbrücker Wohnungsbau Rental Contract Am Lindenhang 7",
		isNonArchival: false,
		fields: {
			policy_number: literalField(rentalContractNumber),
			cancellation_period: threeMonths,
		},
		render(document) {
			document.addPage()
			drawOrganizationMark(document, wohnungsbau)
			document
				.font("SerifBold")
				.fontSize(18)
				.text("Mietvertrag über Wohnraum", leftMargin, 110, { width: contentWidth, align: "center" })
			document
				.font("SerifRegular")
				.fontSize(10)
				.text(`Vertragsnummer: ${rentalContractNumber}`, { width: contentWidth, align: "center" })
			let cursor = drawParagraphs(
				document,
				[
					`Zwischen der ${wohnungsbau.name}, Rathausplatz 9, 31846 Talbrück, vertreten durch die Geschäftsführerin Dorothea Kranich, nachfolgend „Vermieterin“ genannt,`,
					"und Frau Mira Wiśniewska sowie Herrn Jonas Becker, nachfolgend gemeinsam „Mieter“ genannt, wird folgender Mietvertrag geschlossen:",
				],
				{ top: 160, typeface: "SerifRegular" },
			)
			cursor = drawSections(
				document,
				[
					{
						heading: "§ 1 Mietsache",
						paragraphs: [
							"(1) Die Vermieterin vermietet den Mietern zu Wohnzwecken die Wohnung im zweiten Obergeschoss links des Hauses Am Lindenhang 7, 31846 Talbrück. Die Wohnung besteht aus drei Zimmern, einer Küche, einem Bad mit WC, einem Flur und einem Balkon.",
							"(2) Die Wohnfläche beträgt 78 Quadratmeter. Zur Wohnung gehört der Kellerraum Nummer 7.",
							"(3) Den Mietern werden für die Mietzeit drei Haustürschlüssel, drei Wohnungsschlüssel und zwei Briefkastenschlüssel ausgehändigt.",
							"(4) Die Mieter sind berechtigt, den gemeinschaftlichen Fahrradraum und die Waschküche entsprechend der Hausordnung mitzubenutzen.",
						],
					},
					{
						heading: "§ 2 Mietzeit",
						paragraphs: [
							"(1) Das Mietverhältnis beginnt am 01.05.2026 und läuft auf unbestimmte Zeit.",
							"(2) Setzen die Mieter den Gebrauch der Mietsache nach Ablauf der Mietzeit fort, so gilt das Mietverhältnis nicht als verlängert. § 545 BGB findet keine Anwendung.",
						],
					},
					{
						heading: "§ 3 Miete und Betriebskosten",
						paragraphs: ["(1) Die monatliche Miete setzt sich wie folgt zusammen:"],
					},
				],
				{ ...serifSections, top: cursor + 6 },
			)
			cursor = drawTable(document, {
				left: leftMargin + 20,
				top: cursor - 4,
				regularTypeface: "SerifRegular",
				boldTypeface: "SerifBold",
				columns: [
					{ header: "Bestandteil", width: 300 },
					{ header: "Betrag", width: 110, align: "right" },
				],
				rows: rentComponents.map(([label, cents]) => [label, formatEuro(cents)]),
				summaryRows: [["Gesamtmiete monatlich", formatEuro(rentTotalCents)]],
			})
			drawParagraphs(
				document,
				[
					`(2) Die Gesamtmiete ist monatlich im Voraus, spätestens am dritten Werktag eines Monats, kostenfrei auf das Konto der Vermieterin bei der ${wohnungsbau.bankName}, IBAN ${groupIban(wohnungsbau.iban)}, zu zahlen.`,
					"(3) Über die Vorauszahlungen für Betriebskosten sowie für Heiz- und Warmwasserkosten rechnet die Vermieterin jährlich ab. Abrechnungszeitraum ist das Kalenderjahr.",
				],
				{ top: cursor + 8, typeface: "SerifRegular" },
			)
			drawPageLabel(document, pageLabel(1))

			document.addPage()
			drawSections(
				document,
				[
					{
						heading: "§ 4 Mietsicherheit",
						paragraphs: [
							`(1) Die Mieter leisten eine Mietsicherheit in Höhe von ${formatEuro(3 * rentComponents[0]![1])}. Sie sind berechtigt, die Sicherheit in drei gleichen monatlichen Teilzahlungen zu erbringen. Die erste Teilzahlung ist zu Beginn des Mietverhältnisses fällig.`,
							"(2) Die Vermieterin legt die Sicherheit getrennt von ihrem Vermögen bei einem Kreditinstitut zu dem für Spareinlagen üblichen Zinssatz an. Die Zinsen stehen den Mietern zu.",
						],
					},
					{
						heading: "§ 5 Kündigung",
						paragraphs: [
							"(1) Das Mietverhältnis kann von beiden Vertragsparteien nach den gesetzlichen Vorschriften gekündigt werden. Die Kündigung bedarf der Schriftform.",
							"(2) Die Kündigungsfrist für die Mieter beträgt drei Monate. Die Kündigung ist spätestens am dritten Werktag eines Kalendermonats zum Ablauf des übernächsten Monats zulässig.",
							"(3) Für die Vermieterin verlängert sich die Kündigungsfrist nach fünf und nach acht Jahren seit der Überlassung des Wohnraums um jeweils drei Monate.",
						],
					},
					{
						heading: "§ 6 Schönheitsreparaturen",
						paragraphs: [
							"(1) Die Wohnung wird in renoviertem Zustand übergeben. Die Mieter übernehmen die Schönheitsreparaturen während der Mietzeit, soweit sie durch ihren vertragsgemäßen Gebrauch erforderlich werden.",
							"(2) Schönheitsreparaturen umfassen das Anstreichen der Wände und Decken, das Streichen der Heizkörper und der Innentüren sowie der Fenster und Außentüren von innen.",
						],
					},
					{
						heading: "§ 7 Tierhaltung",
						paragraphs: [
							"Die Haltung von Kleintieren wie Zierfischen, Wellensittichen oder Hamstern ist ohne Erlaubnis zulässig. Für die Haltung von Hunden und Katzen ist die vorherige Zustimmung der Vermieterin erforderlich, die nur aus wichtigem Grund versagt werden darf.",
						],
					},
					{
						heading: "§ 8 Hausordnung",
						paragraphs: [
							"Die beigefügte Hausordnung ist Bestandteil dieses Vertrages. Die Mieter verpflichten sich, die Treppenhausreinigung im wöchentlichen Wechsel mit den übrigen Mietparteien ihres Geschosses durchzuführen.",
						],
					},
				],
				{ ...serifSections, top: 60 },
			)
			drawPageLabel(document, pageLabel(2))

			document.addPage()
			cursor = drawSections(
				document,
				[
					{
						heading: "§ 9 Sonstige Vereinbarungen",
						paragraphs: [
							"(1) Die Wohnung wird mit einer Einbauküche übergeben, deren Wartung der Vermieterin obliegt.",
							"(2) Die Mieter dürfen auf dem Balkon keine Satellitenempfangsanlagen anbringen. Der Anschluss an das Breitbandkabelnetz des Hauses ist vorhanden.",
							"(3) Änderungen und Ergänzungen dieses Vertrages bedürfen der Schriftform. Sollte eine Bestimmung dieses Vertrages unwirksam sein, bleibt die Wirksamkeit der übrigen Bestimmungen unberührt.",
						],
					},
				],
				{ ...serifSections, top: 60 },
			)
			const signatureTop = cursor + 40
			const signatureWidth = (contentWidth - 30) / 3
			const signatories = ["Dorothea Kranich\nfür die Vermieterin", "Mira Wiśniewska\nMieterin", "Jonas Becker\nMieter"]
			signatories.forEach((label, index) => {
				const left = leftMargin + index * (signatureWidth + 15)
				document
					.font("SerifRegular")
					.fontSize(9.5)
					.text(`Talbrück, ${formatGermanDate(signatureDate)}`, left, signatureTop, { lineBreak: false })
				document
					.moveTo(left, signatureTop + 50)
					.lineTo(left + signatureWidth, signatureTop + 50)
					.lineWidth(0.6)
					.strokeColor("#000000")
					.stroke()
				document.fontSize(8.5).text(label, left, signatureTop + 55, { width: signatureWidth })
			})
			drawPageLabel(document, pageLabel(3))
		},
	}
}

function householdContentsInsurancePolicy(): DocumentSpecification {
	const policyNumber = "HR-7731-0482-19"
	const issueDate = "2026-02-20"
	const coverageStart = "2026-03-01"
	const renewalDate = "2027-03-01"
	const netPremiumCents = 9953
	const insuranceTaxCents = Math.round(netPremiumCents * 0.19)
	const pageLabel = (page: number) => `Versicherungsschein ${policyNumber} · Seite ${page} von 2`
	return {
		fileStem: "household_contents_insurance_policy_scanned",
		captureMethod: "scanned",
		pageSize: pageSizeA4,
		pageCount: 2,
		language: "de",
		category: "Insurance",
		sender: lindenhain.name,
		person: "household",
		documentDate: germanDateField(issueDate),
		titleHint: "Lindenhain Versicherung Household Contents Insurance Policy",
		isNonArchival: false,
		fields: {
			policy_number: literalField(policyNumber),
			renewal_date: germanDateField(renewalDate),
			cancellation_period: threeMonths,
		},
		render(document) {
			document.addPage()
			let cursor = drawLetterhead(document, lindenhain, {
				recipientLines: ["Frau", "Mira Wiśniewska", ...householdAddressLines],
				referenceRows: [
					["Versicherungsnummer", policyNumber],
					["Datum", formatGermanDate(issueDate)],
					["Seite", "1 von 2"],
				],
				subject: "Versicherungsschein zur Hausratversicherung Komfort",
			})
			cursor = drawParagraphs(
				document,
				[
					"Sehr geehrte Frau Wiśniewska,",
					"vielen Dank für Ihr Vertrauen. Mit diesem Versicherungsschein dokumentieren wir den Abschluss Ihrer Hausratversicherung. Bitte prüfen Sie die folgenden Angaben und bewahren Sie dieses Dokument sorgfältig auf.",
				],
				{ top: cursor, fontSize: 9.5 },
			)
			cursor = drawDefinitionList(
				document,
				[
					["Versicherungsnehmerin", "Mira Wiśniewska"],
					["Mitversicherte Personen", "Jonas Becker, Lena Becker\n(in häuslicher Gemeinschaft lebend)"],
					["Versicherungsort", "Am Lindenhang 7, 2. Obergeschoss links, 31846 Talbrück"],
					["Wohnfläche", "78 m²"],
					["Versicherungssumme", `${formatEuro(78 * 65000)} (650 € je m² Wohnfläche)`],
					["Versicherungsbeginn", `${formatGermanDate(coverageStart)}, 0:00 Uhr`],
					["Ablauf", `${formatGermanDate(renewalDate)}, 0:00 Uhr`],
					["Vertragsdauer", "ein Jahr mit stillschweigender Verlängerung"],
					["Zahlungsweise", "jährlich per SEPA-Lastschrift"],
				],
				{ left: leftMargin, top: cursor + 6, labelWidth: 140, fontSize: 9.5, rowGap: 3 },
			)
			cursor = drawTable(document, {
				left: leftMargin,
				top: cursor + 14,
				fontSize: 9,
				columns: [
					{ header: "Beitrag", width: 330 },
					{ header: "jährlich", width: contentWidth - 330, align: "right" },
				],
				rows: [
					["Nettobeitrag Hausrat Komfort", formatEuro(netPremiumCents)],
					["Versicherungsteuer 19 %", formatEuro(insuranceTaxCents)],
				],
				summaryRows: [["Jahresbeitrag", formatEuro(netPremiumCents + insuranceTaxCents)]],
				bandColor: "#e5efe6",
			})
			drawParagraphs(
				document,
				[
					`Der Jahresbeitrag wird zum ${formatGermanDate(coverageStart)} von Ihrem Konto IBAN DE** **** **** **** **72 18 eingezogen. Mandatsreferenz: HR77310482-01.`,
				],
				{ top: cursor + 12, fontSize: 9 },
			)
			drawLetterFooter(document, lindenhain, pageLabel(1))

			document.addPage()
			document
				.font("SansBold")
				.fontSize(11)
				.text("Versicherte Gefahren und Leistungen", leftMargin, 60, { width: contentWidth })
			cursor = drawTable(document, {
				left: leftMargin,
				top: document.y + 6,
				fontSize: 9,
				columns: [
					{ header: "Gefahr oder Leistung", width: 300 },
					{ header: "Entschädigungsgrenze", width: contentWidth - 300, align: "right" },
				],
				rows: [
					["Feuer, Blitzschlag, Explosion", "Versicherungssumme"],
					["Leitungswasser", "Versicherungssumme"],
					["Sturm und Hagel", "Versicherungssumme"],
					["Einbruchdiebstahl, Raub und Vandalismus", "Versicherungssumme"],
					["Wertsachen insgesamt", "20 % der Versicherungssumme"],
					["Fahrraddiebstahl", formatEuro(100000)],
					["Überspannung durch Blitz", formatEuro(500000)],
					["Hotelkosten nach einem Versicherungsfall", "bis 100 Tage"],
				],
				bandColor: "#e5efe6",
			})
			drawSections(
				document,
				[
					{
						heading: "Selbstbeteiligung",
						paragraphs: [`Je Versicherungsfall tragen Sie eine Selbstbeteiligung von ${formatEuro(15000)}.`],
					},
					{
						heading: "Laufzeit und Kündigung",
						paragraphs: [
							`Der Vertrag beginnt am ${formatGermanDate(coverageStart)} und endet am ${formatGermanDate(renewalDate)}. Er verlängert sich jeweils um ein weiteres Jahr, wenn er nicht spätestens drei Monate vor dem jeweiligen Ablauf in Textform gekündigt wird.`,
							"Nach einem Versicherungsfall können beide Vertragsparteien den Vertrag innerhalb eines Monats nach Abschluss der Verhandlungen über die Entschädigung kündigen.",
						],
					},
					{
						heading: "Vertragsgrundlagen",
						paragraphs: [
							"Dem Vertrag liegen die Allgemeinen Hausratversicherungsbedingungen der Lindenhain Versicherung AG (VHB 2026), die Besonderen Bedingungen für den Tarif Komfort sowie die Informationen nach der VVG-Informationspflichtenverordnung zugrunde.",
						],
					},
					{
						heading: "Ihre Ansprechpartner",
						paragraphs: [
							"Schäden melden Sie bitte unverzüglich online oder schriftlich unter Angabe Ihrer Versicherungsnummer. Änderungen der Wohnfläche oder einen Umzug teilen Sie uns bitte innerhalb eines Monats mit.",
							"Mit freundlichen Grüßen\nLindenhain Versicherung AG",
						],
					},
				],
				{ headingTypeface: "SansBold", top: cursor + 14, fontSize: 9.5 },
			)
			drawLetterFooter(document, lindenhain, pageLabel(2))
		},
	}
}

const taxNumber = "31/846/04417"
const incomeTaxCents = 1147400
const withheldWageTaxCents = 1113300
const taxBalanceCents = incomeTaxCents - withheldWageTaxCents

function incomeTaxAssessment(): DocumentSpecification {
	const assessmentDate = "2026-09-08"
	const dueDate = "2026-10-14"
	const euroWhole = (euros: number) => `${euros.toLocaleString("de-DE")} €`
	return {
		fileStem: "income_tax_assessment_scanned",
		captureMethod: "scanned",
		pageSize: pageSizeA4,
		pageCount: 2,
		language: "de",
		category: "Tax Notice",
		sender: finanzamt.name,
		person: "Jonas Becker",
		documentDate: germanDateField(assessmentDate),
		titleHint: "Finanzamt Talbrück Income Tax Assessment 2025",
		isNonArchival: false,
		fields: {
			amount: euroField(taxBalanceCents),
			currency: euroCurrency,
			due_date: germanDateField(dueDate),
			iban: ibanField(finanzamt.iban),
		},
		render(document) {
			document.addPage()
			let cursor = drawLetterhead(document, finanzamt, {
				recipientLines: ["Herrn", "Jonas Becker", ...householdAddressLines],
				referenceRows: [
					["Steuernummer", taxNumber],
					["Datum", formatGermanDate(assessmentDate)],
					["Sachbereich", "Arbeitnehmerstelle 3"],
					["Seite", "1 von 2"],
				],
				subject: "Bescheid für 2025 über Einkommensteuer und Solidaritätszuschlag",
			})
			cursor = drawParagraphs(
				document,
				[
					"Dieser Bescheid ergeht aufgrund Ihrer Einkommensteuererklärung für das Kalenderjahr 2025 (Einzelveranlagung).",
				],
				{ top: cursor, fontSize: 9.5 },
			)
			cursor = drawTable(document, {
				left: leftMargin,
				top: cursor + 4,
				fontSize: 9,
				columns: [
					{ header: "Festsetzung", width: 230 },
					{ header: "Einkommensteuer", width: 120, align: "right" },
					{ header: "Solidaritätszuschlag", width: contentWidth - 350, align: "right" },
				],
				rows: [["festgesetzt werden", formatEuro(incomeTaxCents), formatEuro(0)]],
			})
			cursor = drawTable(document, {
				left: leftMargin,
				top: cursor + 14,
				fontSize: 9,
				columns: [
					{ header: "Abrechnung", width: 230 },
					{ header: "Einkommensteuer", width: 120, align: "right" },
					{ header: "Solidaritätszuschlag", width: contentWidth - 350, align: "right" },
				],
				rows: [
					["festgesetzt", formatEuro(incomeTaxCents), formatEuro(0)],
					["abzüglich Steuerabzug vom Lohn", formatEuro(-withheldWageTaxCents), formatEuro(0)],
				],
				summaryRows: [["verbleibende Beträge", formatEuro(taxBalanceCents), formatEuro(0)]],
			})
			cursor = drawParagraphs(
				document,
				[
					`Bitte zahlen Sie den Betrag von ${formatEuro(taxBalanceCents)} spätestens bis zum ${formatGermanDate(dueDate)} an die Finanzkasse des Finanzamts Talbrück. Geben Sie als Verwendungszweck bitte „${taxNumber} ESt 2025“ an.`,
				],
				{ top: cursor + 14, fontSize: 9.5 },
			)
			cursor = drawBankDetails(document, finanzamt, cursor + 2)
			drawParagraphs(
				document,
				[
					"Bei verspäteter Zahlung entstehen Säumniszuschläge. Die Besteuerungsgrundlagen, die Erläuterungen und die Rechtsbehelfsbelehrung finden Sie auf der folgenden Seite.",
				],
				{ top: cursor + 8, fontSize: 9 },
			)
			drawLetterFooter(document, finanzamt)

			document.addPage()
			document
				.font("SansBold")
				.fontSize(9)
				.text(
					`Steuernummer ${taxNumber} · Bescheid vom ${formatGermanDate(assessmentDate)} · Seite 2 von 2`,
					leftMargin,
					50,
					{ width: contentWidth, align: "right" },
				)
			document.fontSize(11).text("Ermittlung des zu versteuernden Einkommens", leftMargin, 80, { width: contentWidth })
			cursor = drawTable(document, {
				left: leftMargin,
				top: document.y + 6,
				fontSize: 9,
				columns: [
					{ header: "Besteuerungsgrundlagen", width: 330 },
					{ header: "Betrag", width: contentWidth - 330, align: "right" },
				],
				rows: [
					["Bruttoarbeitslohn", euroWhole(64800)],
					["abzüglich Werbungskosten", euroWhole(-1920)],
					["Einkünfte aus nichtselbständiger Arbeit", euroWhole(62880)],
					["abzüglich Vorsorgeaufwendungen", euroWhole(-10412)],
					["abzüglich Kinderbetreuungskosten", euroWhole(-284)],
				],
				summaryRows: [["zu versteuerndes Einkommen", euroWhole(52184)]],
			})
			drawSections(
				document,
				[
					{
						heading: "Erläuterungen",
						paragraphs: [
							"Die Werbungskosten wurden in der erklärten Höhe berücksichtigt, da sie den Arbeitnehmer-Pauschbetrag übersteigen.",
							"Die Prüfung der Freibeträge für Kinder hat ergeben, dass das Kindergeld günstiger ist. Ein Kinderfreibetrag wurde daher nicht abgezogen.",
							"Ein Solidaritätszuschlag wird nicht festgesetzt, da die maßgebende Einkommensteuer die Freigrenze nicht übersteigt.",
						],
					},
					{
						heading: "Rechtsbehelfsbelehrung",
						paragraphs: [
							"Gegen diesen Bescheid ist der Einspruch zulässig. Er ist beim Finanzamt Talbrück schriftlich einzureichen, diesem elektronisch zu übermitteln oder dort zur Niederschrift zu erklären. Die Frist für die Einlegung des Einspruchs beträgt einen Monat. Sie beginnt mit Ablauf des Tages, an dem Ihnen dieser Bescheid bekannt gegeben worden ist.",
							"Ein Einspruch hemmt die Fälligkeit des festgesetzten Betrages nicht.",
						],
					},
				],
				{ headingTypeface: "SansBold", top: cursor + 16, fontSize: 9.5 },
			)
			drawLetterFooter(document, finanzamt)
		},
	}
}

const statementAccountIban = computeGermanIban(banks.muehlbach.code, "0471128305")
const openingBalanceCents = 241837
const statementTransactions: ReadonlyArray<readonly [string, string, string, string, number]> = [
	["01.10.", "Dauerauftrag", wohnungsbau.name, `Miete Oktober 2026, ${rentalContractNumber}`, -rentTotalCents],
	["02.10.", "Überweisung", stadtwerke.name, `Nachzahlung ${electricityInvoiceNumber}`, -electricityBalanceCents],
	["02.10.", "Kartenzahlung", "Talbrücker Backstube", "Debitkarte 4417, 02.10. 07:31", -840],
	["05.10.", "Lastschrift", "Stadt Talbrück", "Hortbeitrag Oktober 2026, Lena Becker", -9500],
	["06.10.", "Kartenzahlung", "Frischemarkt Talbrück", "Debitkarte 4417, 06.10. 18:12", -5418],
	["08.10.", "Auszahlung", "Geldautomat Mühlbach Bank", "Talbrück Marktplatz, 08.10. 12:04", -10000],
	["09.10.", "Kartenzahlung", "Apotheke am Lindenhang", "Debitkarte 4417, 09.10. 16:47", -1295],
	["12.10.", "Gutschrift", "Mira Wiśniewska", "Anteil Miete Oktober 2026", Math.round(rentTotalCents / 2)],
	["13.10.", "Überweisung", finanzamt.name, `${taxNumber} ESt 2025`, -taxBalanceCents],
	["14.10.", "Kartenzahlung", "Tankstelle Talbrück Nord", "Debitkarte 4417, 14.10. 07:55", -6137],
	["16.10.", "Kartenzahlung", "Frischemarkt Talbrück", "Debitkarte 4417, 16.10. 19:03", -3862],
	["19.10.", "Überweisung", nordkabel.name, `Rechnung ${telecommunicationInvoiceNumber}`, -telecommunicationTotalCents],
	["20.10.", "Kartenzahlung", "Buchhandlung am Markt", "Debitkarte 4417, 20.10. 11:26", -2490],
	["22.10.", "Lastschrift", "TSV Talbrück 1908 e. V.", "Mitgliedsbeitrag Oktober 2026", -1500],
	["23.10.", "Kartenzahlung", "Frischemarkt Talbrück", "Debitkarte 4417, 23.10. 17:58", -4731],
	["26.10.", "Kartenzahlung", "Talbrücker Backstube", "Debitkarte 4417, 26.10. 07:28", -680],
	["27.10.", "Dauerauftrag", "Jonas Becker", "Umbuchung auf Tagesgeldkonto", -20000],
	["29.10.", "Gutschrift", "Brenner & Hollmann Ingenieure GmbH", "Gehalt Oktober 2026", 368420],
	["30.10.", "Kartenzahlung", "Tankstelle Talbrück Nord", "Debitkarte 4417, 30.10. 18:21", -5804],
	["30.10.", "Entgelt", muehlbachBank.name, "Kontoführung Oktober 2026", -490],
	["31.10.", "Kartenzahlung", "Frischemarkt Talbrück", "Debitkarte 4417, 31.10. 17:42", -supermarketTotalCents],
]

function bankStatement(): DocumentSpecification {
	const statementDate = "2026-10-31"
	const closingBalanceCents = openingBalanceCents + sumOf(statementTransactions.map(([, , , , cents]) => cents))
	const signedAmount = (cents: number) => `${cents > 0 ? "+" : ""}${formatGermanDecimal(cents)}`
	const columns = [
		{ header: "Buchung", width: 48 },
		{ header: "Wert", width: 48 },
		{ header: "Vorgang", width: 290 },
		{ header: "Betrag EUR", width: contentWidth - 386, align: "right" as const },
	]
	const transactionRows = statementTransactions.map(([date, kind, counterparty, purpose, cents]) => [
		date,
		date,
		`${kind} ${counterparty}\n${purpose}`,
		signedAmount(cents),
	])
	return {
		fileStem: "bank_statement_digital",
		captureMethod: "digital",
		pageSize: pageSizeA4,
		pageCount: 2,
		language: "de",
		category: "Bank Statement",
		sender: muehlbachBank.name,
		person: "Jonas Becker",
		documentDate: germanDateField(statementDate),
		titleHint: "Mühlbach Bank Account Statement October 2026",
		isNonArchival: false,
		fields: {
			iban: ibanField(statementAccountIban),
		},
		render(document) {
			document.addPage()
			let cursor = drawLetterhead(document, muehlbachBank, {
				recipientLines: ["Herrn", "Jonas Becker", ...householdAddressLines],
				referenceRows: [
					["Kontoinhaber", "Jonas Becker"],
					["Kontoart", "Girokonto Komfort"],
					["IBAN", groupIban(statementAccountIban)],
					["Auszugsdatum", formatGermanDate(statementDate)],
					["Zeitraum", "01.10.2026 – 31.10.2026"],
					["Seite", "1 von 2"],
				],
				subject: "Kontoauszug Nr. 10/2026",
			})
			cursor = drawTable(document, {
				left: leftMargin,
				top: cursor,
				fontSize: 8.5,
				columns,
				rows: [
					["", "", "Alter Kontostand am 30.09.2026", signedAmount(openingBalanceCents)],
					...transactionRows.slice(0, 12),
				],
				bandColor: "#f3e4e6",
			})
			drawParagraphs(document, ["Fortsetzung auf Seite 2"], { top: cursor + 6, fontSize: 8 })
			drawLetterFooter(document, muehlbachBank)

			document.addPage()
			drawOrganizationMark(document, muehlbachBank)
			document
				.font("SansRegular")
				.fontSize(8.5)
				.text(`Kontoauszug Nr. 10/2026 · IBAN ${groupIban(statementAccountIban)} · Seite 2 von 2`, leftMargin, 90, {
					width: contentWidth,
					align: "right",
				})
			cursor = drawTable(document, {
				left: leftMargin,
				top: 115,
				fontSize: 8.5,
				columns,
				rows: transactionRows.slice(12),
				summaryRows: [
					["", "", `Neuer Kontostand am ${formatGermanDate(statementDate)}`, signedAmount(closingBalanceCents)],
				],
				bandColor: "#f3e4e6",
			})
			drawParagraphs(
				document,
				[
					`Eingeräumter Dispositionskredit: ${formatEuro(300000)}. Sollzinssatz für eingeräumte Kontoüberziehungen: 9,75 % p. a.`,
					"Bitte prüfen Sie die Buchungen auf diesem Kontoauszug. Einwendungen gegen einzelne Buchungen sind unverzüglich zu erheben. Der Kontoauszug gilt als Rechnungsabschluss im Sinne unserer Allgemeinen Geschäftsbedingungen, wenn Sie nicht innerhalb von sechs Wochen nach Zugang widersprechen.",
					"Guthaben sind als Einlagen nach Maßgabe des Einlagensicherungsgesetzes geschützt.",
				],
				{ top: cursor + 16, fontSize: 8.5 },
			)
			drawLetterFooter(document, muehlbachBank)
		},
	}
}

const pointValueCents = 5.62421
const dentalProcedures: ReadonlyArray<{
	code: string
	description: string
	teeth: string
	quantity: number
	points: number
	factor: number
}> = [
	{ code: "0010", description: "Eingehende Untersuchung", teeth: "", quantity: 1, points: 100, factor: 2.3 },
	{ code: "1000", description: "Mundhygienestatus und Unterweisung", teeth: "", quantity: 1, points: 200, factor: 2.3 },
	{
		code: "2000",
		description: "Fissurenversiegelung je Zahn",
		teeth: "16, 26, 36, 46",
		quantity: 4,
		points: 90,
		factor: 2.3,
	},
	{ code: "1020", description: "Lokale Fluoridierung", teeth: "OK, UK", quantity: 1, points: 50, factor: 2.3 },
]

function dentalInvoice(): DocumentSpecification {
	const invoiceNumber = "ZA-2026-0193"
	const invoiceDate = "2026-08-27"
	const dueDate = "2026-09-26"
	const lineCents = dentalProcedures.map(
		(procedure) => procedure.quantity * Math.round(procedure.points * pointValueCents * procedure.factor),
	)
	const totalCents = sumOf(lineCents)
	return {
		fileStem: "dental_invoice_scanned",
		captureMethod: "scanned",
		pageSize: pageSizeA4,
		pageCount: 1,
		language: "de",
		category: "Medical",
		sender: dentalPractice.name,
		person: "Lena Becker",
		documentDate: germanDateField(invoiceDate),
		titleHint: "Zahnarztpraxis Vossberg Dental Invoice Lena Becker August 2026",
		isNonArchival: false,
		fields: {
			amount: euroField(totalCents),
			currency: euroCurrency,
			due_date: germanDateField(dueDate),
			iban: ibanField(dentalPractice.iban),
			invoice_number: literalField(invoiceNumber),
		},
		render(document) {
			document.addPage()
			let cursor = drawLetterhead(document, dentalPractice, {
				recipientLines: ["Frau", "Mira Wiśniewska", ...householdAddressLines],
				referenceRows: [
					["Rechnungsnummer", invoiceNumber],
					["Rechnungsdatum", formatGermanDate(invoiceDate)],
					["Patientin", "Lena Becker"],
					["geboren am", "09.05.2019"],
				],
				subject: "Rechnung für zahnärztliche Leistungen nach der GOZ",
				bodyTypeface: "SerifRegular",
				boldTypeface: "SerifBold",
			})
			cursor = drawParagraphs(
				document,
				[
					"Sehr geehrte Frau Wiśniewska,",
					"für die Behandlung Ihrer Tochter Lena Becker am 18.08.2026 berechne ich Ihnen die folgenden Leistungen nach der Gebührenordnung für Zahnärzte (GOZ):",
				],
				{ top: cursor, typeface: "SerifRegular", fontSize: 10 },
			)
			cursor = drawTable(document, {
				left: leftMargin,
				top: cursor + 4,
				fontSize: 8.5,
				regularTypeface: "SerifRegular",
				boldTypeface: "SerifBold",
				columns: [
					{ header: "Datum", width: 52 },
					{ header: "GOZ", width: 30 },
					{ header: "Leistung", width: 178 },
					{ header: "Zahn", width: 64 },
					{ header: "Anzahl", width: 36, align: "right" },
					{ header: "Faktor", width: 36, align: "right" },
					{ header: "Betrag", width: contentWidth - 396, align: "right" },
				],
				rows: dentalProcedures.map((procedure, index) => [
					"18.08.2026",
					procedure.code,
					procedure.description,
					procedure.teeth,
					String(procedure.quantity),
					procedure.factor.toLocaleString("de-DE", { minimumFractionDigits: 1 }),
					formatEuro(lineCents[index]!),
				]),
				summaryRows: [["", "", "Rechnungsbetrag", "", "", "", formatEuro(totalCents)]],
				bandColor: "#e2eff6",
			})
			cursor = drawParagraphs(
				document,
				[
					"Punktwert: 5,62421 Cent. Zahnärztliche Heilbehandlungen sind nach § 4 Nr. 14 UStG von der Umsatzsteuer befreit.",
					`Bitte überweisen Sie den Rechnungsbetrag von ${formatEuro(totalCents)} bis zum ${formatGermanDate(dueDate)} unter Angabe der Rechnungsnummer ${invoiceNumber} auf das folgende Konto:`,
				],
				{ top: cursor + 14, typeface: "SerifRegular", fontSize: 9.5 },
			)
			cursor = drawBankDetails(document, dentalPractice, cursor + 2)
			drawParagraphs(document, ["Mit freundlichen Grüßen", "Dr. Henrike Vossberg"], {
				top: cursor + 12,
				typeface: "SerifRegular",
				fontSize: 10,
				gap: 0.2,
			})
			drawLetterFooter(document, dentalPractice)
		},
	}
}

function residenceRegistrationCertificate(): DocumentSpecification {
	const issueDate = "2026-05-04"
	return {
		fileStem: "residence_registration_certificate_scanned",
		captureMethod: "scanned",
		pageSize: pageSizeA4,
		pageCount: 1,
		language: "de",
		category: "Official Identification",
		sender: stadtTalbrueck.name,
		person: "Mira Wiśniewska",
		documentDate: germanDateField(issueDate),
		titleHint: "Stadt Talbrück Residence Registration Certificate Mira Wiśniewska",
		isNonArchival: false,
		fields: {},
		render(document) {
			document.addPage()
			drawOrganizationMark(document, stadtTalbrueck)
			document.font("SansRegular").fontSize(8.5).fillColor("#333333")
			document.text("Aktenzeichen: 33.10-2026-04812", leftMargin, 50, { width: contentWidth, align: "right" })
			document
				.fillColor("#000000")
				.font("SansBold")
				.fontSize(20)
				.text("Meldebescheinigung", leftMargin, 130, { width: contentWidth })
			document
				.font("SansRegular")
				.fontSize(9.5)
				.text(
					"Einfache Meldebescheinigung nach § 18 Absatz 1 des Bundesmeldegesetzes (BMG)",
					leftMargin,
					document.y + 4,
					{ width: contentWidth },
				)
			let cursor = drawParagraphs(
				document,
				["Für die nachstehend bezeichnete Person sind im Melderegister der Stadt Talbrück folgende Daten gespeichert:"],
				{ top: document.y + 22, fontSize: 10 },
			)
			cursor = drawDefinitionList(
				document,
				[
					["Familienname", "Wiśniewska"],
					["Vornamen", "Mira"],
					["Geburtsdatum", "14.03.1989"],
					["Geburtsort", "Kraków, Polen"],
					["Staatsangehörigkeit", "polnisch"],
					["Anschrift", "Am Lindenhang 7, 31846 Talbrück"],
					["Wohnungsstatus", "alleinige Wohnung"],
					["Einzugsdatum", "01.05.2026"],
				],
				{ left: leftMargin + 10, top: cursor + 8, labelWidth: 150, fontSize: 11, rowGap: 6 },
			)
			cursor = drawParagraphs(
				document,
				[
					"Die vorstehenden Angaben entsprechen dem Inhalt des Melderegisters am Tag der Ausstellung. Diese Bescheinigung ersetzt keinen Pass oder Personalausweis.",
					`Talbrück, ${formatGermanDate(issueDate)}`,
					"Im Auftrag",
				],
				{ top: cursor + 20, fontSize: 10 },
			)
			const sealCenterX = rightEdge - 80
			const sealCenterY = cursor + 20
			document.circle(sealCenterX, sealCenterY, 42).lineWidth(1.5).strokeColor("#1f3a5f").stroke()
			document.circle(sealCenterX, sealCenterY, 34).lineWidth(0.6).stroke()
			drawSingleLine(
				document.font("SansBold").fontSize(7.5).fillColor("#1f3a5f"),
				"STADT TALBRÜCK",
				sealCenterX - 34,
				sealCenterY - 9,
				{ width: 68, align: "center" },
			)
			drawSingleLine(document.font("SansRegular").fontSize(6.5), "Dienstsiegel", sealCenterX - 34, sealCenterY + 2, {
				width: 68,
				align: "center",
			})
			document
				.fillColor("#000000")
				.font("SansRegular")
				.fontSize(10)
				.text("Keller", leftMargin, cursor + 28, { lineBreak: false })
			document
				.moveTo(leftMargin, cursor + 42)
				.lineTo(leftMargin + 160, cursor + 42)
				.lineWidth(0.6)
				.strokeColor("#000000")
				.stroke()
			document.fontSize(8).text("Sachbearbeitung Bürgeramt", leftMargin, cursor + 46, { lineBreak: false })
			drawLetterFooter(document, stadtTalbrueck)

			document.save()
			document.rotate(-38, { origin: [pageSizeA4[0] / 2, pageSizeA4[1] / 2] })
			document.font("SansBold").fontSize(140).fillColor("#808080").fillOpacity(0.3)
			const watermarkWidth = document.widthOfString("MUSTER")
			document.text("MUSTER", pageSizeA4[0] / 2 - watermarkWidth / 2, pageSizeA4[1] / 2 - 80, { lineBreak: false })
			document.restore()
		},
	}
}

function softwareSubscriptionInvoice(): DocumentSpecification {
	const invoiceNumber = "PLK-2026-004817"
	const issueDate = "2026-10-03"
	const dueDate = "2026-10-17"
	const seats = 3
	const seatPriceCents = 1200
	const subtotalCents = seats * seatPriceCents
	const taxCents = Math.round(subtotalCents * 0.19)
	const totalCents = subtotalCents + taxCents
	const dollars = (cents: number) => `$${(cents / 100).toFixed(2)}`
	const paperlark = {
		name: "Paperlark Software Ltd.",
		addressLines: ["41 Weaver Lane", "Larkhaven LK4 2PQ", "United Kingdom", "billing@paperlark.example"],
		accentColor: "#5b3fd1",
		monogram: "PL",
	}
	return {
		fileStem: "software_subscription_invoice_digital",
		captureMethod: "digital",
		pageSize: pageSizeA4,
		pageCount: 1,
		language: "en",
		category: "Invoice",
		sender: paperlark.name,
		person: "Mira Wiśniewska",
		documentDate: { value: issueDate, printed: formatEnglishDate(issueDate) },
		titleHint: "Paperlark Software Invoice October 2026",
		isNonArchival: false,
		fields: {
			amount: { value: totalCents / 100, printed: dollars(totalCents) },
			currency: literalField("USD"),
			due_date: { value: dueDate, printed: formatEnglishDate(dueDate) },
			invoice_number: literalField(invoiceNumber),
		},
		render(document) {
			document.addPage()
			drawOrganizationMark(document, paperlark)
			document.font("SansBold").fontSize(22).fillColor("#000000").text("Invoice", leftMargin, 100)
			let cursor = drawDefinitionList(
				document,
				[
					["Invoice number", invoiceNumber],
					["Date of issue", formatEnglishDate(issueDate)],
					["Date due", formatEnglishDate(dueDate)],
				],
				{ left: leftMargin, top: 138, labelWidth: 100, fontSize: 9.5 },
			)
			const columnTop = cursor + 16
			document.font("SansBold").fontSize(9.5).text(paperlark.name, leftMargin, columnTop)
			document.font("SansRegular").text(paperlark.addressLines.join("\n"), leftMargin, document.y)
			document.font("SansBold").text("Bill to", leftMargin + 240, columnTop)
			document
				.font("SansRegular")
				.text(
					["Mira Wiśniewska", ...householdAddressLines, "Germany", "mira.wisniewska@household.example"].join("\n"),
					leftMargin + 240,
					document.y,
				)
			cursor = columnTop + 90
			document
				.font("SansBold")
				.fontSize(15)
				.text(`${dollars(totalCents)} USD due ${formatEnglishDate(dueDate)}`, leftMargin, cursor)
			document
				.font("SansRegular")
				.fontSize(9.5)
				.fillColor("#5b3fd1")
				.text("Pay online at billing.paperlark.example/pay", leftMargin, document.y + 4)
			document.fillColor("#000000")
			cursor = drawTable(document, {
				left: leftMargin,
				top: document.y + 22,
				fontSize: 9.5,
				columns: [
					{ header: "Description", width: 250 },
					{ header: "Qty", width: 50, align: "right" },
					{ header: "Unit price", width: 80, align: "right" },
					{ header: "Amount", width: contentWidth - 380, align: "right" },
				],
				rows: [
					[
						"Paperlark Team plan, monthly\nOct 3 – Nov 2, 2026",
						String(seats),
						dollars(seatPriceCents),
						dollars(subtotalCents),
					],
				],
				summaryRows: [
					["Subtotal", "", "", dollars(subtotalCents)],
					[`VAT Germany (19% on ${dollars(subtotalCents)})`, "", "", dollars(taxCents)],
					["Total", "", "", dollars(totalCents)],
					["Amount due", "", "", `${dollars(totalCents)} USD`],
				],
				bandColor: "#ece8fb",
			})
			drawParagraphs(
				document,
				[
					"Your card on file will be charged automatically on the due date. Questions about this invoice? Contact billing@paperlark.example and quote the invoice number.",
					"Paperlark Software Ltd. is registered in England and Wales. VAT for German customers is charged under the non-Union OSS scheme.",
				],
				{ top: cursor + 24, fontSize: 8.5 },
			)
		},
	}
}

function generalTermsAndConditions(): DocumentSpecification {
	const effectiveDate = "2026-07-01"
	const sectionOptions = { headingTypeface: "SansBold", fontSize: 9, gap: 0.35 } as const
	return {
		fileStem: "general_terms_and_conditions_digital",
		captureMethod: "digital",
		pageSize: pageSizeA4,
		pageCount: 2,
		language: "de",
		category: "Contract",
		sender: nordkabel.name,
		person: "household",
		documentDate: germanDateField(effectiveDate),
		titleHint: "Nordkabel Kommunikation General Terms and Conditions July 2026",
		isNonArchival: true,
		fields: {},
		render(document) {
			document.addPage()
			drawOrganizationMark(document, nordkabel)
			document
				.font("SansBold")
				.fontSize(15)
				.text("Allgemeine Geschäftsbedingungen für Telekommunikationsdienste", leftMargin, 100, { width: contentWidth })
			document
				.font("SansRegular")
				.fontSize(9.5)
				.text(`${nordkabel.name} · Stand: ${formatGermanDate(effectiveDate)}`, leftMargin, document.y + 4)
			drawSections(
				document,
				[
					{
						heading: "§ 1 Geltungsbereich",
						paragraphs: [
							"(1) Diese Allgemeinen Geschäftsbedingungen gelten für alle Verträge über Internet-, Telefon- und Mobilfunkdienste, die Verbraucherinnen und Verbraucher mit der Nordkabel Kommunikation GmbH (nachfolgend „Nordkabel“) schließen.",
							"(2) Abweichende Bedingungen der Kundin oder des Kunden werden nicht Vertragsbestandteil, auch wenn Nordkabel ihnen nicht ausdrücklich widerspricht.",
						],
					},
					{
						heading: "§ 2 Vertragsschluss",
						paragraphs: [
							"Der Vertrag kommt durch die Auftragsbestätigung von Nordkabel in Textform oder durch die Bereitstellung der Leistung zustande. Vor Vertragsschluss erhält die Kundin oder der Kunde eine Vertragszusammenfassung.",
						],
					},
					{
						heading: "§ 3 Leistungsumfang",
						paragraphs: [
							"(1) Der Umfang der Leistungen ergibt sich aus der Leistungsbeschreibung und der Preisliste des gewählten Tarifs.",
							"(2) Die angegebenen Bandbreiten sind Maximalwerte. Die tatsächlich erreichbare Geschwindigkeit hängt unter anderem von der Netzauslastung und der Hausverkabelung ab.",
							"(3) Nordkabel ist berechtigt, Wartungsarbeiten durchzuführen, die nach Möglichkeit in verkehrsarmen Nachtstunden erfolgen.",
						],
					},
					{
						heading: "§ 4 Pflichten der Kundin oder des Kunden",
						paragraphs: [
							"Die Kundin oder der Kunde ist verpflichtet, die Dienste nicht missbräuchlich zu nutzen, Zugangsdaten geheim zu halten und Nordkabel Änderungen des Namens, der Anschrift und der Bankverbindung unverzüglich mitzuteilen.",
						],
					},
					{
						heading: "§ 5 Preise und Zahlung",
						paragraphs: [
							"(1) Es gelten die Preise der jeweils gültigen Preisliste. Alle Preise enthalten die gesetzliche Umsatzsteuer.",
							"(2) Monatliche Grundpreise werden im Voraus, nutzungsabhängige Entgelte nach Ablauf des Abrechnungsmonats berechnet.",
							"(3) Der Rechnungsbetrag ist innerhalb von 14 Tagen nach Zugang der Rechnung fällig.",
						],
					},
					{
						heading: "§ 6 Vertragslaufzeit und Kündigung",
						paragraphs: [
							"(1) Die Mindestvertragslaufzeit beträgt 24 Monate.",
							"(2) Nach Ablauf der Mindestvertragslaufzeit verlängert sich der Vertrag auf unbestimmte Zeit und kann jederzeit mit einer Frist von einem Monat gekündigt werden.",
							"(3) Das Recht zur außerordentlichen Kündigung aus wichtigem Grund bleibt unberührt.",
						],
					},
				],
				{ ...sectionOptions, top: document.y + 14 },
			)
			drawPageLabel(document, `${nordkabel.name} · Allgemeine Geschäftsbedingungen · Seite 1 von 2`)

			document.addPage()
			drawSections(
				document,
				[
					{
						heading: "§ 7 Störungen",
						paragraphs: [
							"Störungen können rund um die Uhr über das Kundenportal gemeldet werden. Nordkabel beseitigt Störungen im Rahmen der technischen und betrieblichen Möglichkeiten unverzüglich. Bei einem vollständigen Ausfall des Dienstes für mehr als zwei Kalendertage steht der Kundin oder dem Kunden eine Entschädigung nach den gesetzlichen Vorschriften zu.",
						],
					},
					{
						heading: "§ 8 Haftung",
						paragraphs: [
							"(1) Nordkabel haftet unbeschränkt für Vorsatz und grobe Fahrlässigkeit sowie für Schäden aus der Verletzung des Lebens, des Körpers oder der Gesundheit.",
							"(2) Für Vermögensschäden, die nicht vorsätzlich verursacht wurden, ist die Haftung gegenüber Endnutzern auf 12.500 Euro je Endnutzer begrenzt.",
						],
					},
					{
						heading: "§ 9 Datenschutz",
						paragraphs: [
							"Nordkabel verarbeitet personenbezogene Daten ausschließlich nach Maßgabe der geltenden datenschutzrechtlichen Vorschriften. Einzelheiten enthält das Datenschutzmerkblatt, das unter www.nordkabel.example abrufbar ist.",
						],
					},
					{
						heading: "§ 10 Streitbeilegung",
						paragraphs: [
							"Zur Beilegung von Streitigkeiten kann die Kundin oder der Kunde ein Schlichtungsverfahren bei der zuständigen Schlichtungsstelle für Telekommunikation beantragen. Nordkabel ist zur Teilnahme an diesem Verfahren bereit.",
						],
					},
					{
						heading: "§ 11 Schlussbestimmungen",
						paragraphs: [
							"Es gilt das Recht der Bundesrepublik Deutschland. Sollten einzelne Bestimmungen dieser Geschäftsbedingungen unwirksam sein, bleibt die Wirksamkeit der übrigen Bestimmungen unberührt.",
						],
					},
				],
				{ ...sectionOptions, top: 60 },
			)
			drawPageLabel(document, `${nordkabel.name} · Allgemeine Geschäftsbedingungen · Seite 2 von 2`)
		},
	}
}

export const documentCatalog: ReadonlyArray<DocumentSpecification> = [
	telecommunicationInvoice(),
	electricityInvoice(),
	supermarketReceipt(),
	hardwareStoreReceipt(),
	rentalContract(),
	householdContentsInsurancePolicy(),
	incomeTaxAssessment(),
	bankStatement(),
	dentalInvoice(),
	residenceRegistrationCertificate(),
	softwareSubscriptionInvoice(),
	generalTermsAndConditions(),
]
