import Foundation
import KioCore

enum TableWorkflow {
    static func execute(_ operation: ToolOperation, arguments: ToolArguments, inputs: [ArtifactRef]) throws -> ArtifactRef {
        if operation == .importXLSX {
            guard inputs.count == 1, let input = inputs.first else {
                throw KioFailure.invalidInput("Import one XLSX workbook at a time.")
            }
            return try XLSXWorkflow.importToCSV(input)
        }
        guard !inputs.isEmpty, inputs.count <= 16,
              inputs.allSatisfy({ $0.kind == .csv || $0.kind == .table }),
              inputs.reduce(Int64(0), { $0 + $1.sizeBytes }) <= 40 * 1_024 * 1_024 else {
            throw KioFailure.invalidInput("Choose up to 16 CSV, TSV, or JSON table files totaling no more than 40 MB.")
        }

        let tables = try inputs.map(read)
        let result: DelimitedTable?
        let text: String?
        let fileExtension: String
        let label: String
        switch operation {
        case .inspectData, .dataStatistics:
            guard tables.count == 1 else { throw KioFailure.invalidInput("Inspect one table at a time.") }
            result = nil
            text = tables[0].statistics()
            fileExtension = "md"
            label = "Statistics"
        case .compareData:
            guard tables.count == 2 else { throw KioFailure.invalidInput("Choose two tables to compare.") }
            result = nil
            text = tables[0].comparison(with: tables[1])
            fileExtension = "md"
            label = "Comparison"
        case .mergeData:
            result = try DelimitedTable.merged(tables)
            text = nil
            fileExtension = "csv"
            label = "Merged"
        case .deduplicateData:
            let combined = tables.count == 1 ? tables[0] : try DelimitedTable.merged(tables)
            result = try combined.deduplicated()
            text = nil
            fileExtension = "csv"
            label = "Deduplicated"
        case .sortData:
            guard tables.count == 1, case .tableSort(let column, let ascending) = arguments else {
                throw KioFailure.invalidInput("Choose one table and a column to sort by.")
            }
            result = try tables[0].sorted(column: column, ascending: ascending)
            text = nil
            fileExtension = "csv"
            label = "Sorted"
        case .filterData:
            guard tables.count == 1, case .tableFilter(let column, let value) = arguments else {
                throw KioFailure.invalidInput("Choose one table and a column/value filter.")
            }
            result = try tables[0].filtered(column: column, value: value)
            text = nil
            fileExtension = "csv"
            label = "Filtered"
        case .selectColumns, .reorderColumns:
            guard tables.count == 1, case .tableColumns(let columns) = arguments else {
                throw KioFailure.invalidInput("Choose one table and the columns to keep, in the requested order.")
            }
            result = try tables[0].selecting(columns: columns)
            text = nil
            fileExtension = "csv"
            label = operation == .selectColumns ? "Selected-Columns" : "Reordered-Columns"
        case .renameColumns:
            guard tables.count == 1, case .tableRenameColumn(let from, let to) = arguments else {
                throw KioFailure.invalidInput("Choose one table and a source/new column name.")
            }
            result = try tables[0].renamingColumn(from: from, to: to)
            text = nil
            fileExtension = "csv"
            label = "Renamed-Columns"
        case .csvToJSON:
            guard tables.count == 1, inputs[0].fileURL.pathExtension.lowercased() != "json" else {
                throw KioFailure.invalidInput("Choose one CSV or TSV file to convert to JSON.")
            }
            result = tables[0]
            text = nil
            fileExtension = "json"
            label = "JSON"
        case .jsonToCSV:
            guard tables.count == 1, inputs[0].fileURL.pathExtension.lowercased() == "json" else {
                throw KioFailure.invalidInput("Choose one JSON table file to convert to CSV.")
            }
            result = tables[0]
            text = nil
            fileExtension = "csv"
            label = "CSV"
        case .normalizeData:
            guard tables.count == 1 else { throw KioFailure.invalidInput("Normalize one table at a time.") }
            result = tables[0].normalized()
            text = nil
            fileExtension = "csv"
            label = "Normalized"
        default:
            throw KioFailure.unsupported("Table does not support that operation.")
        }

        let first = inputs[0]
        let stem = URL(fileURLWithPath: first.displayName).deletingPathExtension().lastPathComponent
        let output = try OutputLocation.makeURL(for: inputs, baseName: "\(stem)-\(label)", fileExtension: fileExtension)
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let data: Data
        if let text {
            data = Data(("# \(label)\n\n" + text + "\n").utf8)
        } else if fileExtension == "json" {
            data = try result!.jsonData()
        } else {
            data = result!.delimitedData()
        }
        try data.write(to: temporary, options: .atomic)
        try OutputLocation.commit(temporary, to: output)
        let excerpt = String(decoding: data.prefix(12_000), as: UTF8.self)
        return try ArtifactRef.inspect(output, parentID: first.id)
            .withVerificationNote(excerpt + (data.count > 12_000 ? "\n\nFull result: \(output.lastPathComponent). Originals remain unchanged." : "\n\nOriginals remain unchanged."))
    }

    private static func read(_ input: ArtifactRef) throws -> DelimitedTable {
        let values = try input.fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard input.fileURL.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 20 * 1_024 * 1_024,
              let data = try? Data(contentsOf: input.fileURL, options: [.mappedIfSafe]) else {
            throw KioFailure.invalidInput("\(input.displayName) is unavailable, is not a regular file, or exceeds the 20 MB table limit.")
        }
        if input.fileURL.pathExtension.lowercased() == "json" { return try DelimitedTable.json(data: data) }
        return try DelimitedTable(data: data, delimiter: input.fileURL.pathExtension.lowercased() == "tsv" ? "\t" : nil)
    }
}
