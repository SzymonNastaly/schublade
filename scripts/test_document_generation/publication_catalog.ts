import {
	contentWidth,
	drawDefinitionList,
	drawOrganizationMark,
	drawParagraphs,
	drawSections,
	drawSingleLine,
	drawTable,
	leftMargin,
	millimetre,
	pageSizeA4,
	syntheticNotice,
} from "./document_layout.ts"
import type { PageSize, PrintedMatter, SectionContent } from "./document_layout.ts"

export interface Publication extends PrintedMatter {
	publicationDate: string
}

function drawPageFooter(document: PDFKit.PDFDocument, lines: ReadonlyArray<string>, left: number, width: number): void {
	const bottomMargin = document.page.margins.bottom
	document.page.margins.bottom = 0
	document.font("SansRegular").fontSize(6.5).fillColor("#666666")
	lines.forEach((line, index) =>
		drawSingleLine(document, line, left, document.page.height - 28 - (lines.length - 1 - index) * 9, {
			width,
			align: "center",
		}),
	)
	document.fillColor("#000000")
	document.page.margins.bottom = bottomMargin
}

const nordkabelMark = { name: "Nordkabel Kommunikation GmbH", accentColor: "#0b6e6e", monogram: "NK" }

export function routerManual(): Publication {
	const sectionOptions = { headingTypeface: "SansBold", fontSize: 9.5, gap: 0.4 } as const
	const pageFooter = (page: number) => [`Nordbox 7 · Bedienungsanleitung · Seite ${page} von 3`, syntheticNotice]
	const pageSections: ReadonlyArray<ReadonlyArray<SectionContent>> = [
		[
			{
				heading: "1 Sicherheitshinweise",
				paragraphs: [
					"Stellen Sie die Nordbox 7 an einem trockenen, gut belüfteten Ort auf. Decken Sie die Lüftungsschlitze nicht ab und stellen Sie das Gerät nicht in die Nähe von Heizkörpern.",
					"Verwenden Sie ausschließlich das mitgelieferte Netzteil. Öffnen Sie das Gehäuse nicht; im Inneren befinden sich keine Teile, die Sie selbst warten können.",
					"Ziehen Sie bei Gewitter das Netzteil und das Anschlusskabel ab, um Schäden durch Überspannung zu vermeiden.",
				],
			},
			{
				heading: "2 Lieferumfang",
				paragraphs: [
					"Zum Lieferumfang gehören die Nordbox 7, ein Netzteil 12 V, ein Netzwerkkabel von 1,5 m Länge, ein Glasfaser-Anschlusskabel, diese Bedienungsanleitung sowie eine Karte mit dem WLAN-Netzwerkschlüssel und dem Gerätekennwort.",
				],
			},
			{
				heading: "3 Anschlüsse und Bedienelemente",
				paragraphs: [
					"Auf der Rückseite befinden sich der Glasfaseranschluss, vier Netzwerkanschlüsse LAN 1 bis LAN 4, ein Anschluss für analoge Telefone, ein USB-Anschluss und die Buchse für das Netzteil.",
					"Auf der Oberseite befinden sich die Tasten WLAN und Verbinden. Mit der Taste Verbinden melden Sie neue Geräte per WPS an. Halten Sie die Taste WLAN drei Sekunden lang gedrückt, um das Funknetz aus- oder einzuschalten.",
				],
			},
		],
		[
			{
				heading: "4 Inbetriebnahme",
				paragraphs: [
					"(1) Verbinden Sie den Glasfaseranschluss der Nordbox 7 mit der Glasfaser-Teilnehmeranschlussdose. Entfernen Sie dazu die Schutzkappen an beiden Enden des Kabels und berühren Sie die Stirnflächen nicht.",
					"(2) Schließen Sie das Netzteil an. Die Leuchtanzeige Power blinkt, während die Nordbox 7 startet. Der Start dauert etwa zwei Minuten.",
					"(3) Sobald die Leuchtanzeige Internet dauerhaft leuchtet, ist die Verbindung hergestellt. Ihre Zugangsdaten werden automatisch übertragen.",
				],
			},
			{
				heading: "5 WLAN einrichten",
				paragraphs: [
					"Die Nordbox 7 sendet ab Werk zwei Funknetze im 2,4-GHz- und im 5-GHz-Band unter demselben Namen. Den Namen und den Netzwerkschlüssel finden Sie auf der Unterseite des Geräts und auf der beigelegten Karte.",
					"Wählen Sie an Ihrem Computer, Telefon oder Tablet das Funknetz aus und geben Sie den Netzwerkschlüssel ein. Ändern Sie den Netzwerkschlüssel nach der Einrichtung in der Benutzeroberfläche, wenn Sie die Karte nicht sicher aufbewahren können.",
				],
			},
			{
				heading: "6 Benutzeroberfläche aufrufen",
				paragraphs: [
					"Öffnen Sie in einem Webbrowser die Adresse nordbox.box. Melden Sie sich mit dem Gerätekennwort von der Unterseite an. In der Benutzeroberfläche richten Sie Telefonie, Kindersicherung, Gastzugang und Portfreigaben ein.",
					"Aktualisierungen der Gerätesoftware installiert die Nordbox 7 nachts automatisch. Sie können die automatische Aktualisierung unter System, Aktualisierung abschalten; wir empfehlen das nicht.",
				],
			},
		],
	]
	return {
		pageSize: pageSizeA4,
		pageCount: 3,
		publicationDate: "2026-03-02",
		render(document) {
			pageSections.forEach((sections, index) => {
				document.addPage()
				if (index === 0) {
					drawOrganizationMark(document, nordkabelMark)
					document.font("SansBold").fontSize(20).fillColor("#0b6e6e").text("Nordbox 7", leftMargin, 110)
					document
						.font("SansRegular")
						.fontSize(11)
						.fillColor("#000000")
						.text("Bedienungsanleitung · WLAN-Router für Glasfaseranschlüsse · Ausgabe 03/2026", leftMargin, 140)
				}
				drawSections(document, sections, { ...sectionOptions, top: index === 0 ? 180 : 60 })
				drawPageFooter(document, pageFooter(index + 1), leftMargin, contentWidth)
			})
			document.addPage()
			document.font("SansBold").fontSize(10).text("7 Leuchtanzeigen", leftMargin, 60)
			let cursor = drawTable(document, {
				left: leftMargin,
				top: 80,
				fontSize: 8.5,
				columns: [
					{ header: "Anzeige", width: 90 },
					{ header: "Zustand", width: 110 },
					{ header: "Bedeutung", width: contentWidth - 200 },
				],
				rows: [
					["Power", "leuchtet grün", "Die Nordbox 7 ist betriebsbereit."],
					["Power", "blinkt grün", "Die Nordbox 7 startet oder aktualisiert ihre Software."],
					["Internet", "leuchtet grün", "Die Verbindung zum Internet besteht."],
					["Internet", "blinkt rot", "Kein Signal am Glasfaseranschluss."],
					["WLAN", "leuchtet grün", "Das Funknetz ist eingeschaltet."],
					["Verbinden", "blinkt grün", "Die Anmeldung per WPS läuft für zwei Minuten."],
				],
				bandColor: "#e1efee",
			})
			document
				.font("SansBold")
				.fontSize(10)
				.text("8 Technische Daten", leftMargin, cursor + 20)
			cursor = drawDefinitionList(
				document,
				[
					["Glasfaser", "GPON, SC/APC"],
					["WLAN", "Wi-Fi 7, 2,4 GHz und 5 GHz, 4 x 4"],
					["Netzwerk", "4 x Gigabit-Ethernet, davon 1 x 2,5 Gbit/s"],
					["Leistungsaufnahme", "typisch 11 W, höchstens 24 W"],
					["Abmessungen", "226 x 172 x 48 mm"],
				],
				{ left: leftMargin, top: cursor + 40, labelWidth: 120, fontSize: 9 },
			)
			drawSections(
				document,
				[
					{
						heading: "9 Entsorgung",
						paragraphs: [
							"Elektrische und elektronische Geräte gehören nicht in den Hausmüll. Geben Sie die Nordbox 7 am Ende ihrer Nutzungsdauer bei einer kommunalen Sammelstelle ab oder senden Sie sie kostenlos an Nordkabel zurück.",
						],
					},
				],
				{ ...sectionOptions, top: cursor + 16 },
			)
			drawPageFooter(document, pageFooter(3), leftMargin, contentWidth)
		},
	}
}

export function scientificPaper(): Publication {
	const serif = { headingTypeface: "SerifBold", typeface: "SerifRegular", fontSize: 9.5, gap: 0.4 } as const
	const pageFooter = (page: number) => [
		`Proceedings of the Workshop on Archival Document Engineering 2026 · ${page}`,
		syntheticNotice,
	]
	return {
		pageSize: pageSizeA4,
		pageCount: 2,
		publicationDate: "2026-09-14",
		render(document) {
			document.addPage()
			document
				.font("SerifBold")
				.fontSize(16)
				.text("Containment Estimates for Near-Duplicate Detection in Scanned Correspondence", leftMargin, 70, {
					width: contentWidth,
					align: "center",
				})
			document
				.font("SerifRegular")
				.fontSize(10.5)
				.text("Ilse Marwitz and Tomasz Kerber", leftMargin, document.y + 10, { width: contentWidth, align: "center" })
			document
				.fontSize(9)
				.text("Institute for Document Engineering, University of Hollerbeck", leftMargin, document.y + 2, {
					width: contentWidth,
					align: "center",
				})
			const cursor = drawSections(
				document,
				[
					{
						heading: "Abstract",
						paragraphs: [
							"Household archives receive the same letter as a portal download, a flatbed scan, and a telephone photograph. We estimate the containment of character 5-gram sets between renditions and show that containment, unlike Jaccard resemblance, tolerates a missing blank page and a document embedded in a combined scan. On 4,812 synthetic rendition pairs, a containment threshold of 0.62 separates renditions of one letter from consecutive monthly invoices of one sender with a precision of 0.991 and a recall of 0.874.",
						],
					},
					{
						heading: "1 Introduction",
						paragraphs: [
							"Exact hashes recognize a file seen twice, but a scanner, a camera, and a second download each change every byte. Text recognition restores the words, yet it misreads digits, and digits carry the facts that distinguish one invoice from the next. A detector must therefore tolerate recognition noise in prose while it stays strict about amounts, dates, and reference numbers.",
							"Broder defined resemblance and containment for sets of shingles. Resemblance penalizes any difference in length, so an extra page lowers it although the letter is unchanged. Containment measures how much of the shorter rendition the longer one holds, which is the question an archive asks.",
						],
					},
					{
						heading: "2 Method",
						paragraphs: [
							"We normalize each page to lowercase letters and digits, collapse whitespace, and form the set of character 5-grams. For renditions A and B with sets S(A) and S(B), the containment of A in B is the size of their intersection divided by the size of S(A). We estimate it with 256 minimum hash values per page and report the larger of the two directions.",
						],
					},
				],
				{ ...serif, top: document.y + 18 },
			)
			drawPageFooter(document, pageFooter(1), leftMargin, contentWidth)
			if (cursor > pageSizeA4[1] - 60) throw new Error("the first page of the paper overflows")

			document.addPage()
			const resultsTop = drawSections(
				document,
				[
					{
						heading: "3 Results",
						paragraphs: [
							"Table 1 lists precision and recall for each pair of rendition kinds at the threshold of 0.62. Photographs of printed pages lose the most 5-grams to recognition errors, so their recall is lowest.",
						],
					},
				],
				{ ...serif, top: 60 },
			)
			const tableBottom = drawTable(document, {
				left: leftMargin,
				top: resultsTop + 4,
				fontSize: 9,
				regularTypeface: "SerifRegular",
				boldTypeface: "SerifBold",
				columns: [
					{ header: "Rendition pair", width: 230 },
					{ header: "Pairs", width: 70, align: "right" },
					{ header: "Precision", width: 80, align: "right" },
					{ header: "Recall", width: contentWidth - 380, align: "right" },
				],
				rows: [
					["Digital and digital rewritten", "812", "1.000", "0.998"],
					["Digital and flatbed scan", "1,204", "0.995", "0.913"],
					["Flatbed scan and flatbed scan", "1,388", "0.989", "0.871"],
					["Digital and photograph", "1,408", "0.984", "0.762"],
				],
				summaryRows: [["All pairs", "4,812", "0.991", "0.874"]],
			})
			drawSections(
				document,
				[
					{
						heading: "4 Conclusion",
						paragraphs: [
							"Containment of character 5-grams is a cheap first stage. It finds candidate renditions in milliseconds over a few thousand documents, and a second stage that compares the digit-bearing tokens of both renditions decides whether they are one document.",
						],
					},
					{
						heading: "References",
						paragraphs: [
							"[1] A. Z. Broder. On the resemblance and containment of documents. Compression and Complexity of Sequences, 1997.",
							"[2] I. Marwitz. Recognition errors in digits of household correspondence. Technical report, University of Hollerbeck, 2025.",
						],
					},
				],
				{ ...serif, top: tableBottom + 14 },
			)
			drawPageFooter(document, pageFooter(2), leftMargin, contentWidth)
		},
	}
}

const bookPageSize: PageSize = [125 * millimetre, 205 * millimetre]
const bookMargin = 16 * millimetre
const bookTextWidth = bookPageSize[0] - 2 * bookMargin

export function bookExcerpt(): Publication {
	const prose = { left: bookMargin, width: bookTextWidth, typeface: "SerifRegular", fontSize: 9.5, gap: 0.5 } as const
	const noticeLines = syntheticNotice.split(/(?<=\.) /)
	const prosePages: ReadonlyArray<ReadonlyArray<string>> = [
		[
			"Die Werkstatt lag im Hof hinter der Apotheke, und wer sie finden wollte, musste durch einen Torbogen, unter dem es selbst im August nach nassem Stein roch. Agnes Hollweg hatte das Schild über der Tür nie erneuert. Es zeigte eine Taschenuhr, deren Zeiger seit dem Krieg auf zehn nach zehn standen, und die Leute in Talbrück sagten, das sei die einzige Uhr in der Stadt, die Agnes nicht reparieren wolle.",
			"An diesem Morgen lagen auf ihrer Werkbank drei Uhren nebeneinander: eine Küchenuhr mit gesprungenem Glas, ein Wecker, der zu laut tickte, und eine goldene Armbanduhr, die ihr ein Mann am Vorabend gebracht hatte, ohne seinen Namen zu nennen. Er hatte nur gesagt, sie gehe richtig, und genau das sei das Problem.",
		],
		[
			"Agnes öffnete den Deckel mit dem Messer, das ihr Vater ihr zur Gesellenprüfung geschenkt hatte. Das Werk war sauber, beinahe zu sauber für eine Uhr dieses Alters. Auf der Innenseite des Deckels stand eine Gravur, so fein, dass sie die Lupe brauchte: ein Datum, ein Ort und zwei Buchstaben, die sie kannte, weil sie dieselben Buchstaben jeden Morgen auf dem Briefkasten ihrer Mutter las.",
			"Sie legte die Uhr zurück und sah eine Weile auf den Hof hinaus, wo der Lehrling der Apotheke Kisten stapelte. Dann schrieb sie einen Zettel für die Tür, geschlossen bis Mittag, und ging zum ersten Mal seit elf Jahren den Lindenhang hinauf zu dem Haus, in dem sie aufgewachsen war.",
		],
	]
	return {
		pageSize: bookPageSize,
		pageCount: 3,
		publicationDate: "2026-08-20",
		render(document) {
			const bookPage = {
				size: [...bookPageSize],
				margins: { top: bookMargin, bottom: bookMargin, left: bookMargin, right: bookMargin },
			}
			document.addPage(bookPage)
			document
				.font("SerifRegular")
				.fontSize(11)
				.text("Henrike Albers", bookMargin, 120, { width: bookTextWidth, align: "center" })
			document
				.font("SerifBold")
				.fontSize(18)
				.text("Die Uhrmacherin von Talbrück", bookMargin, document.y + 18, { width: bookTextWidth, align: "center" })
			document
				.font("SerifRegular")
				.fontSize(11)
				.text("Roman", bookMargin, document.y + 14, { width: bookTextWidth, align: "center" })
				.text("Leseprobe", bookMargin, document.y + 40, { width: bookTextWidth, align: "center" })
				.fontSize(9)
				.text("Kranich Verlag Hollerbeck", bookMargin, 470, { width: bookTextWidth, align: "center" })
			drawPageFooter(document, noticeLines, bookMargin, bookTextWidth)
			prosePages.forEach((paragraphs, index) => {
				document.addPage(bookPage)
				const top = index === 0 ? 70 : bookMargin + 10
				if (index === 0)
					document.font("SerifBold").fontSize(12).text("Erstes Kapitel", bookMargin, 40, { width: bookTextWidth })
				const bottom = drawParagraphs(document, paragraphs, { ...prose, top })
				if (bottom > bookPageSize[1] - 40) throw new Error(`page ${index + 2} of the book excerpt overflows`)
				drawPageFooter(document, [String(index + 9), ...noticeLines], bookMargin, bookTextWidth)
			})
		},
	}
}
