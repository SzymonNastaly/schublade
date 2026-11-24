import Foundation

/// A Markdown table's rows as plain columns for a monospaced font, so a reader shows the table
/// without its pipes and with its columns aligned, however the extracted text spaced them.
public enum TableColumnLayout {
	private static let columnGap = "   "

	/// Each row's cells padded to their column's width and set apart by three spaces. A column whose
	/// cells below the head all begin with a figure, such as amounts and quantities, is set flush
	/// right, and every other column flush left.
	public static func alignedRows(_ rows: [String]) -> [String] {
		let cells = rows.map(Self.cells)
		let columnCount = cells.map(\.count).max() ?? 0
		let columns = (0 ..< columnCount).map { column in
			let entries = cells.map { column < $0.count ? $0[column] : "" }
			let body = entries.dropFirst().filter { !$0.isEmpty }
			return (
				width: entries.map(\.count).max() ?? 0,
				flushRight: !body.isEmpty && body.allSatisfy(beginsWithFigure)
			)
		}
		return cells.map { row in
			columns.enumerated().map { index, column in
				let cell = index < row.count ? row[index] : ""
				let padding = String(repeating: " ", count: column.width - cell.count)
				return column.flushRight ? padding + cell : cell + padding
			}
			.joined(separator: columnGap)
			.replacing(/\s+$/, with: "")
		}
	}

	private static func cells(of row: String) -> [String] {
		var trimmed = Substring(row.trimmingCharacters(in: .whitespaces))
		if trimmed.hasPrefix("|") {
			trimmed = trimmed.dropFirst()
		}
		if trimmed.hasSuffix("|") {
			trimmed = trimmed.dropLast()
		}
		return trimmed.split(separator: "|", omittingEmptySubsequences: false)
			.map { $0.trimmingCharacters(in: .whitespaces) }
	}

	private static func beginsWithFigure(_ cell: String) -> Bool {
		cell.first.map { $0.isNumber || "+-−€$£".contains($0) } ?? false
	}
}
