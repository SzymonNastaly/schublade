export type Category =
	| "Invoice"
	| "Receipt"
	| "Contract"
	| "Tax Notice"
	| "Bank Statement"
	| "Insurance"
	| "Medical"
	| "Official Identification";

export type FieldKey =
	| "amount"
	| "currency"
	| "due_date"
	| "iban"
	| "invoice_number"
	| "policy_number"
	| "renewal_date"
	| "cancellation_period";

export type CaptureMethod = "digital" | "scanned" | "photographed";

export const householdMembers = ["Mira Wiśniewska", "Jonas Becker", "Lena Becker"] as const;
export type PersonAssignment = (typeof householdMembers)[number] | "household";

export interface PrintedValue {
	value: string | number;
	printed: string;
}

export interface DocumentSpecification {
	fileStem: string;
	captureMethod: CaptureMethod;
	pageSize: readonly [number, number];
	pageCount: number;
	language: "de" | "en";
	category: Category;
	sender: string;
	person: PersonAssignment;
	documentDate: PrintedValue;
	titleHint: string;
	isNonArchival: boolean;
	fields: Partial<Record<FieldKey, PrintedValue>>;
	render: (document: PDFKit.PDFDocument) => void;
}

export const typefaceFiles = {
	SansRegular: "@ibm/plex-sans/fonts/complete/woff/IBMPlexSans-Regular.woff",
	SansBold: "@ibm/plex-sans/fonts/complete/woff/IBMPlexSans-SemiBold.woff",
	SerifRegular: "@ibm/plex-serif/fonts/complete/woff/IBMPlexSerif-Regular.woff",
	SerifBold: "@ibm/plex-serif/fonts/complete/woff/IBMPlexSerif-SemiBold.woff",
	MonospaceRegular: "@ibm/plex-mono/fonts/complete/woff/IBMPlexMono-Regular.woff",
	MonospaceBold: "@ibm/plex-mono/fonts/complete/woff/IBMPlexMono-SemiBold.woff",
} as const;
export type Typeface = keyof typeof typefaceFiles;

export const millimetre = 72 / 25.4;
export const pageSizeA4 = [595.28, 841.89] as const;
export const leftMargin = 25 * millimetre;
export const rightEdge = pageSizeA4[0] - 20 * millimetre;
export const contentWidth = rightEdge - leftMargin;

export function formatGermanDecimal(cents: number): string {
	const sign = cents < 0 ? "-" : "";
	const absoluteCents = Math.abs(cents);
	const wholeUnits = Math.floor(absoluteCents / 100)
		.toString()
		.replace(/\B(?=(\d{3})+(?!\d))/g, ".");
	return `${sign}${wholeUnits},${String(absoluteCents % 100).padStart(2, "0")}`;
}

export const formatEuro = (cents: number): string => `${formatGermanDecimal(cents)} €`;

export function formatGermanDate(isoDate: string): string {
	const [year, month, day] = isoDate.split("-");
	return `${day}.${month}.${year}`;
}

const englishMonthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

export function formatEnglishDate(isoDate: string): string {
	const [year, month, day] = isoDate.split("-");
	return `${englishMonthNames[Number(month) - 1]} ${Number(day)}, ${year}`;
}

export const groupIban = (iban: string): string => iban.replace(/(.{4})/g, "$1 ").trim();

export function computeGermanIban(bankCode: string, accountNumber: string): string {
	const basicBankAccountNumber = bankCode + accountNumber.padStart(10, "0");
	const remainder = BigInt(`${basicBankAccountNumber}131400`) % 97n;
	return `DE${String(98n - remainder).padStart(2, "0")}${basicBankAccountNumber}`;
}

export function vatIncludedInGross(grossCents: number, ratePercent: number): { netCents: number; taxCents: number } {
	const netCents = Math.round((grossCents * 100) / (100 + ratePercent));
	return { netCents, taxCents: grossCents - netCents };
}

export const literalField = (text: string): PrintedValue => ({ value: text, printed: text });
export const euroField = (cents: number): PrintedValue => ({ value: cents / 100, printed: formatEuro(cents) });
export const germanDateField = (isoDate: string): PrintedValue => ({ value: isoDate, printed: formatGermanDate(isoDate) });
export const ibanField = (iban: string): PrintedValue => ({ value: iban, printed: groupIban(iban) });

export interface Organization {
	name: string;
	addressLines: readonly string[];
	contactLines: readonly string[];
	registrationLines: readonly string[];
	bankName: string;
	iban: string;
	accentColor: string;
	monogram?: string;
	letterheadSubtitle?: string;
}

export const letterMargins = { top: 50, bottom: 80, left: leftMargin, right: 20 * millimetre };

export interface LineBox {
	width: number;
	align?: "left" | "right" | "center";
}

// pdfkit wraps any text that is given a width, even with lineBreak disabled, so alignment is computed here and overflow is a layout error.
export function drawSingleLine(document: PDFKit.PDFDocument, text: string, left: number, top: number, box?: LineBox): void {
	const textWidth = document.widthOfString(text);
	if (box && textWidth > box.width + 0.01) throw new Error(`"${text}" is ${textWidth.toFixed(1)} pt wide but its box is ${box.width.toFixed(1)} pt`);
	const slack = box ? box.width - textWidth : 0;
	const offset = box?.align === "right" ? slack : box?.align === "center" ? slack / 2 : 0;
	document.text(text, left + offset, top, { lineBreak: false });
}

export function drawOrganizationMark(document: PDFKit.PDFDocument, organization: Pick<Organization, "name" | "accentColor" | "monogram" | "letterheadSubtitle">, top = 40): void {
	let nameLeft = leftMargin;
	if (organization.monogram) {
		document.roundedRect(leftMargin, top, 30, 30, 6).fill(organization.accentColor);
		drawSingleLine(document.fillColor("#ffffff").font("SansBold").fontSize(12), organization.monogram, leftMargin, top + 8, { width: 30, align: "center" });
		nameLeft += 40;
	}
	document.fillColor(organization.accentColor).font("SansBold").fontSize(15).text(organization.name, nameLeft, top + 6, { lineBreak: false });
	if (organization.letterheadSubtitle) {
		document.font("SansRegular").fontSize(8.5).fillColor("#555555").text(organization.letterheadSubtitle, nameLeft, top + 25, { lineBreak: false });
	}
	document.fillColor("#000000");
}

export interface LetterheadContent {
	recipientLines: readonly string[];
	referenceRows: ReadonlyArray<readonly [string, string]>;
	subject: string;
	bodyTypeface?: Typeface;
	boldTypeface?: Typeface;
}

export function drawLetterhead(document: PDFKit.PDFDocument, organization: Organization, content: LetterheadContent): number {
	const regular = content.bodyTypeface ?? "SansRegular";
	const bold = content.boldTypeface ?? "SansBold";
	drawOrganizationMark(document, organization);
	const returnAddress = [organization.name, ...organization.addressLines].join(" · ");
	document.font(regular).fontSize(6.5).fillColor("#444444").text(returnAddress, leftMargin, 132, { lineBreak: false, underline: true });
	document.fillColor("#000000").font(regular).fontSize(10);
	content.recipientLines.forEach((line, index) => document.text(line, leftMargin, 148 + index * 13, { lineBreak: false }));
	drawDefinitionList(document, content.referenceRows, { left: 112 * millimetre, top: 132, labelWidth: 82, fontSize: 8.5, typeface: regular });
	document.font(bold).fontSize(11).fillColor("#000000").text(content.subject, leftMargin, 272, { width: contentWidth });
	return document.y + 14;
}

export interface DefinitionListLayout {
	left: number;
	top: number;
	labelWidth: number;
	fontSize: number;
	typeface?: Typeface;
	rowGap?: number;
}

export function drawDefinitionList(document: PDFKit.PDFDocument, rows: ReadonlyArray<readonly [string, string]>, layout: DefinitionListLayout): number {
	const typeface = layout.typeface ?? "SansRegular";
	const rowHeight = layout.fontSize * 1.4 + (layout.rowGap ?? 2);
	let cursor = layout.top;
	for (const [label, value] of rows) {
		const valueLines = value.split("\n");
		document.font(typeface).fontSize(layout.fontSize - 1).fillColor("#555555").text(label, layout.left, cursor + 1, { lineBreak: false });
		document.fontSize(layout.fontSize).fillColor("#000000");
		valueLines.forEach((line, index) => document.text(line, layout.left + layout.labelWidth, cursor + index * layout.fontSize * 1.3, { lineBreak: false }));
		cursor += rowHeight + (valueLines.length - 1) * layout.fontSize * 1.3;
	}
	return cursor;
}

export function drawLetterFooter(document: PDFKit.PDFDocument, organization: Organization, pageLabel?: string): void {
	const bottomMargin = document.page.margins.bottom;
	document.page.margins.bottom = 0;
	const top = pageSizeA4[1] - 64;
	document.moveTo(leftMargin, top - 6).lineTo(rightEdge, top - 6).lineWidth(0.5).strokeColor("#999999").stroke();
	const columns = [
		[organization.name, ...organization.addressLines],
		organization.contactLines,
		organization.registrationLines,
		[organization.bankName, `IBAN ${groupIban(organization.iban)}`],
	];
	const columnWidth = contentWidth / columns.length;
	document.font("SansRegular").fontSize(6.5).fillColor("#555555");
	columns.forEach((lines, columnIndex) => {
		lines.forEach((line, lineIndex) => drawSingleLine(document, line, leftMargin + columnIndex * columnWidth, top + lineIndex * 8.5, { width: columnWidth - 6 }));
	});
	if (pageLabel) drawSingleLine(document, pageLabel, leftMargin, top + 40, { width: contentWidth, align: "right" });
	document.fillColor("#000000");
	document.page.margins.bottom = bottomMargin;
}

export interface TableColumn {
	header: string;
	width: number;
	align?: "left" | "right" | "center";
}

export interface TableLayout {
	left: number;
	top: number;
	columns: readonly TableColumn[];
	rows: ReadonlyArray<readonly string[]>;
	summaryRows?: ReadonlyArray<readonly string[]>;
	fontSize?: number;
	regularTypeface?: Typeface;
	boldTypeface?: Typeface;
	bandColor?: string;
}

export function drawTable(document: PDFKit.PDFDocument, table: TableLayout): number {
	const fontSize = table.fontSize ?? 9;
	const lineHeight = fontSize * 1.35;
	const regular = table.regularTypeface ?? "SansRegular";
	const bold = table.boldTypeface ?? "SansBold";
	const totalWidth = table.columns.reduce((sum, column) => sum + column.width, 0);
	const drawRow = (cells: readonly string[], top: number, typeface: Typeface): number => {
		const lineCount = Math.max(...cells.map((cell) => cell.split("\n").length));
		let columnLeft = table.left;
		table.columns.forEach((column, index) => {
			(cells[index] ?? "").split("\n").forEach((line, lineIndex) => {
				const lineTypeface = lineIndex === 0 ? typeface : regular;
				const lineColor = lineIndex === 0 ? "#000000" : "#444444";
				document.font(lineTypeface).fontSize(lineIndex === 0 ? fontSize : fontSize - 1).fillColor(lineColor);
				drawSingleLine(document, line, columnLeft + 3, top + 3 + lineIndex * lineHeight, { width: column.width - 6, align: column.align });
			});
			columnLeft += column.width;
		});
		document.fillColor("#000000");
		return top + lineCount * lineHeight + 5;
	};
	if (table.bandColor) document.rect(table.left, table.top, totalWidth, lineHeight + 5).fill(table.bandColor);
	let cursor = drawRow(table.columns.map((column) => column.header), table.top, bold);
	document.moveTo(table.left, cursor).lineTo(table.left + totalWidth, cursor).lineWidth(0.7).strokeColor("#333333").stroke();
	for (const row of table.rows) {
		cursor = drawRow(row, cursor, regular);
		document.moveTo(table.left, cursor).lineTo(table.left + totalWidth, cursor).lineWidth(0.3).strokeColor("#bbbbbb").stroke();
	}
	if (table.summaryRows) {
		document.moveTo(table.left, cursor).lineTo(table.left + totalWidth, cursor).lineWidth(0.7).strokeColor("#333333").stroke();
		table.summaryRows.forEach((row, index) => {
			cursor = drawRow(row, cursor, index === table.summaryRows!.length - 1 ? bold : regular);
		});
	}
	return cursor;
}

export interface ParagraphOptions {
	left?: number;
	top: number;
	width?: number;
	fontSize?: number;
	typeface?: Typeface;
	gap?: number;
}

export function drawParagraphs(document: PDFKit.PDFDocument, paragraphs: readonly string[], options: ParagraphOptions): number {
	document.font(options.typeface ?? "SansRegular").fontSize(options.fontSize ?? 10).fillColor("#000000");
	document.y = options.top;
	for (const paragraph of paragraphs) {
		document.text(paragraph, options.left ?? leftMargin, document.y, { width: options.width ?? contentWidth, lineGap: 1.5 });
		document.moveDown(options.gap ?? 0.6);
	}
	return document.y;
}

export interface SectionContent {
	heading: string;
	paragraphs: readonly string[];
}

export function drawSections(document: PDFKit.PDFDocument, sections: readonly SectionContent[], options: ParagraphOptions & { headingTypeface: Typeface }): number {
	let cursor = options.top;
	for (const section of sections) {
		document.font(options.headingTypeface).fontSize((options.fontSize ?? 10) + 0.5).text(section.heading, options.left ?? leftMargin, cursor, { width: options.width ?? contentWidth });
		cursor = drawParagraphs(document, section.paragraphs, { ...options, top: document.y + 3 }) + 4;
	}
	return cursor;
}
