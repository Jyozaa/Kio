import CoreXLSX
import Foundation
import KioCore
import ZIPFoundation

/// Bounded XLSX reader. It imports cached cell values from a small workbook into a CSV copy;
/// it does not calculate formulas or reproduce Excel formatting, macros, or workbook behavior.
enum XLSXWorkflow {
    private static let maximumArchiveBytes = 50 * 1_024 * 1_024
    private static let maximumExpandedBytes = 64 * 1_024 * 1_024
    private static let maximumEntryBytes = 16 * 1_024 * 1_024
    private static let maximumSheets = 10
    private static let maximumRows = 100_000
    private static let maximumColumns = 256
    private static let maximumCells = 500_000
    private static let maximumCellCharacters = 20_000
    private static let maximumOutputBytes = 32 * 1_024 * 1_024

    static func importToCSV(_ input: ArtifactRef) throws -> ArtifactRef {
        guard input.kind == .table, input.fileURL.pathExtension.lowercased() == "xlsx" else {
            throw KioFailure.invalidInput("Choose one .xlsx workbook. Kio exports readable cell values to a CSV copy.")
        }
        let values = try input.fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard input.fileURL.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximumArchiveBytes else {
            throw KioFailure.invalidInput("The workbook must be a regular, non-symlink file no larger than 50 MB.")
        }
        try validateArchive(at: input.fileURL)
        guard let workbookFile = XLSXFile(filepath: input.fileURL.path, bufferSize: 128 * 1_024) else {
            throw KioFailure.invalidInput("Kio could not open this XLSX workbook. Password-protected and legacy .xls files are not supported.")
        }

        do {
            let workbooks = try workbookFile.parseWorkbooks()
            guard workbooks.count == 1, let workbook = workbooks.first else {
                throw KioFailure.unsupported("Kio imports one standard XLSX workbook at a time.")
            }
            let worksheets = try workbookFile.parseWorksheetPathsAndNames(workbook: workbook)
            guard !worksheets.isEmpty, worksheets.count <= maximumSheets else {
                throw KioFailure.unsupported("Kio can import workbooks with 1 to 10 worksheets.")
            }
            let sharedStrings = try workbookFile.parseSharedStrings()
            var sheets: [(name: String, rows: [[String]])] = []
            var cellCount = 0
            for (sheetIndex, sheet) in worksheets.enumerated() {
                let worksheet = try workbookFile.parseWorksheet(at: sheet.path)
                let sourceRows = worksheet.data?.rows ?? []
                guard sourceRows.count <= maximumRows else {
                    throw KioFailure.unsupported("Each worksheet is limited to 100,000 populated rows.")
                }
                var rows: [[String]] = []
                rows.reserveCapacity(sourceRows.count)
                for row in sourceRows.sorted(by: { $0.reference < $1.reference }) {
                    guard row.reference <= maximumRows else {
                        throw KioFailure.unsupported("A worksheet contains a row beyond Kio's 100,000-row import limit.")
                    }
                    let cells = row.cells.sorted { $0.reference.column < $1.reference.column }
                    cellCount += cells.count
                    guard cellCount <= maximumCells else {
                        throw KioFailure.unsupported("Kio imports at most 500,000 populated cells per workbook.")
                    }
                    let highestColumn = cells.map { Self.columnNumber($0.reference.column.value) }.max() ?? 0
                    guard highestColumn <= maximumColumns else {
                        throw KioFailure.unsupported("Kio imports at most 256 columns per worksheet.")
                    }
                    var values = Array(repeating: "", count: highestColumn)
                    for cell in cells {
                        let column = Self.columnNumber(cell.reference.column.value)
                        guard column > 0, column <= maximumColumns else {
                            throw KioFailure.invalidInput("The workbook contains an invalid cell reference.")
                        }
                        let value = try Self.value(for: cell, sharedStrings: sharedStrings)
                        guard value.count <= maximumCellCharacters else {
                            throw KioFailure.unsupported("A workbook cell exceeds Kio's 20,000-character limit.")
                        }
                        values[column - 1] = value
                    }
                    rows.append(values)
                }
                if !rows.isEmpty {
                    let fallback = "Sheet \(sheetIndex + 1)"
                    let name = (sheet.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
                    sheets.append((name, rows))
                }
            }
            guard let firstSheet = sheets.first, let headerRow = firstSheet.rows.first else {
                throw KioFailure.invalidInput("This workbook has no populated worksheet cells to import.")
            }
            let columnCount = min(maximumColumns, sheets.flatMap(\.rows).map(\.count).max() ?? headerRow.count)
            let headers = Self.uniqueHeaders(headerRow, width: columnCount)
            var rows: [[String]] = []
            rows.reserveCapacity(sheets.reduce(0) { $0 + max(0, $1.rows.count - 1) })
            for sheet in sheets {
                for row in sheet.rows.dropFirst() {
                    rows.append([sheet.name] + (0..<columnCount).map { row.indices.contains($0) ? row[$0] : "" })
                }
            }
            let table = DelimitedTable(headers: ["Sheet"] + headers, rows: rows)
            let data = table.delimitedData()
            guard data.count <= maximumOutputBytes else {
                throw KioFailure.unsupported("The CSV output would exceed Kio's 32 MB import limit.")
            }
            let stem = input.fileURL.deletingPathExtension().lastPathComponent
            let output = try OutputLocation.makeURL(for: [input], baseName: stem + "-Imported", fileExtension: "csv")
            let temporary = OutputLocation.temporaryURL(beside: output)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .atomic)
            try OutputLocation.commit(temporary, to: output)
            let excerpt = String(decoding: data.prefix(8_000), as: UTF8.self)
            let limitation = "Imported (sheets.count) worksheet(s) into one CSV with a Sheet column. The first populated row of the first sheet supplies column names; later sheet headers are treated as data. Formula cells use cached values when present; formulas are not recalculated. Formatting, macros, and Excel behavior are not preserved."
            return try ArtifactRef.inspect(output, parentID: input.id)
                .withVerificationNote(excerpt + "\n\n" + limitation + " Originals remain unchanged.")
        } catch let failure as KioFailure {
            throw failure
        } catch {
            throw KioFailure.invalidInput("Kio could not safely parse this XLSX workbook: \(error.localizedDescription)")
        }
    }

    private static func validateArchive(at url: URL) throws {
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) }
        catch { throw KioFailure.invalidInput("This XLSX file is not a valid ZIP-based workbook.") }
        let entries = Array(archive)
        guard !entries.isEmpty, entries.count <= 2_000,
              entries.contains(where: { URL(fileURLWithPath: $0.path).lastPathComponent == "workbook.xml" }) else {
            throw KioFailure.invalidInput("The XLSX archive is missing workbook data or has too many ZIP entries.")
        }
        var expandedTotal: UInt64 = 0
        for entry in entries {
            let size = entry.uncompressedSize
            guard size <= maximumEntryBytes else {
                throw KioFailure.unsupported("An XLSX archive entry exceeds Kio's 16 MB expanded-entry limit.")
            }
            expandedTotal += size
            guard expandedTotal <= maximumExpandedBytes else {
                throw KioFailure.unsupported("The XLSX archive expands beyond Kio's 64 MB safety limit.")
            }
            if entry.compressedSize > 0, size / entry.compressedSize > 100 {
                throw KioFailure.unsupported("The XLSX archive has an entry with an excessive compression ratio.")
            }
        }
    }

    private static func value(for cell: Cell, sharedStrings: SharedStrings?) throws -> String {
        if cell.type == .sharedString {
            guard let index = cell.value.flatMap(Int.init), let sharedStrings,
                  sharedStrings.items.indices.contains(index) else {
                throw KioFailure.invalidInput("The XLSX workbook contains a broken shared-string reference.")
            }
            let item = sharedStrings.items[index]
            return item.text ?? item.richText.compactMap(\.text).joined()
        }
        return cell.inlineString?.text ?? cell.value ?? ""
    }

    private static func columnNumber(_ name: String) -> Int {
        guard (1...2).contains(name.count) else { return Int.max }
        return name.unicodeScalars.reduce(0) { value, scalar in
            guard scalar.value >= 65, scalar.value <= 90 else { return Int.max }
            return value * 26 + Int(scalar.value - 64)
        }
    }

    private static func uniqueHeaders(_ row: [String], width: Int) -> [String] {
        var counts: [String: Int] = [:]
        return (0..<width).map { index in
            let proposed = row.indices.contains(index) ? row[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let base = String((proposed.isEmpty ? "Column \(index + 1)" : proposed).prefix(128))
            counts[base, default: 0] += 1
            return counts[base] == 1 ? base : "\(base) \(counts[base]!)"
        }
    }
}
