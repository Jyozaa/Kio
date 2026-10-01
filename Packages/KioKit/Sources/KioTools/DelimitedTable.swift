import Foundation
import KioCore

/// Bounded RFC-4180-style delimited text table used by CSV, TSV, and JSON workflows.
public struct DelimitedTable: Sendable, Equatable {
    public let headers: [String]
    public let rows: [[String]]

    public init(data: Data, delimiter requestedDelimiter: Character? = nil) throws {
        guard data.count <= 20 * 1_024 * 1_024,
              var text = String(data: data, encoding: .utf8) else {
            throw KioFailure.invalidInput("Choose a UTF-8 CSV, TSV, or JSON file no larger than 20 MB.")
        }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let delimiter = requestedDelimiter ?? Self.detectDelimiter(text)
        let records = try Self.parseRecords(text, delimiter: delimiter)
        guard let rawHeaders = records.first, !rawHeaders.isEmpty else {
            throw KioFailure.invalidInput("This table has no header row.")
        }
        let width = max(1, records.map(\.count).max() ?? rawHeaders.count)
        guard width <= 500, records.count <= 100_001 else {
            throw KioFailure.unsupported("Kio's local table limit is 500 columns and 100,000 data rows.")
        }
        var names: [String] = []
        var occurrences: [String: Int] = [:]
        for index in 0..<width {
            let proposed = rawHeaders.indices.contains(index) ? rawHeaders[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let base = proposed.isEmpty ? "Column \(index + 1)" : proposed
            occurrences[base, default: 0] += 1
            names.append(occurrences[base] == 1 ? base : "\(base) \(occurrences[base]!)")
        }
        headers = names
        rows = records.dropFirst().map { record in
            (0..<width).map { record.indices.contains($0) ? record[$0] : "" }
        }
    }

    init(headers: [String], rows: [[String]]) {
        self.headers = headers
        self.rows = rows.map { row in (0..<headers.count).map { row.indices.contains($0) ? row[$0] : "" } }
    }

    public static func json(data: Data) throws -> DelimitedTable {
        guard data.count <= 20 * 1_024 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw KioFailure.invalidInput("This JSON file is malformed or larger than 20 MB.")
        }
        if let records = object as? [[String: Any]], !records.isEmpty {
            let headers = Array(Set(records.flatMap(\.keys))).sorted()
            guard !headers.isEmpty else { throw KioFailure.invalidInput("This JSON array has no table columns.") }
            return DelimitedTable(headers: headers, rows: records.map { record in headers.map { Self.jsonCell(record[$0]) } })
        }
        if let table = object as? [String: Any],
           let headers = table["columns"] as? [String],
           let rows = table["rows"] as? [[Any]],
           !headers.isEmpty, headers.count <= 500, rows.count <= 100_000,
           headers.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 128 }),
           Set(headers).count == headers.count {
            return DelimitedTable(headers: headers, rows: rows.map { $0.map(Self.jsonCell) })
        }
        if let arrays = object as? [String: [Any]], !arrays.isEmpty {
            let headers = arrays.keys.sorted()
            let lengths = Set(arrays.values.map(\.count))
            guard lengths.count == 1, let count = lengths.first, count <= 100_000 else {
                throw KioFailure.invalidInput("JSON table columns must be arrays of the same length, with at most 100,000 rows.")
            }
            return DelimitedTable(headers: headers, rows: (0..<count).map { row in headers.map { Self.jsonCell(arrays[$0]?[row]) } })
        }
        if let matrix = object as? [[Any]], let headerValues = matrix.first, !headerValues.isEmpty {
            let headers = headerValues.enumerated().map { index, value in
                let name = Self.jsonCell(value).trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? "Column \(index + 1)" : name
            }
            return DelimitedTable(headers: headers, rows: matrix.dropFirst().map { $0.map(Self.jsonCell) })
        }
        if let record = object as? [String: Any], !record.isEmpty {
            let headers = record.keys.sorted()
            return DelimitedTable(headers: headers, rows: [headers.map { Self.jsonCell(record[$0]) }])
        }
        throw KioFailure.unsupported("Use a JSON array of objects, an object of equal-length arrays, or a header-and-row array.")
    }

    public func delimitedData(delimiter: Character = ",") -> Data {
        let lines = [headers] + rows
        let text = lines.map { row in row.map { Self.escape($0, delimiter: delimiter) }.joined(separator: String(delimiter)) }
            .joined(separator: "\r\n") + "\r\n"
        return Data(text.utf8)
    }

    public func jsonData() throws -> Data {
        let table: [String: Any] = ["columns": headers, "rows": rows]
        return try JSONSerialization.data(withJSONObject: table, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    }

    public func normalized() -> DelimitedTable {
        DelimitedTable(headers: headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                       rows: rows.map { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } })
    }

    public func deduplicated(columns selected: [String]? = nil) throws -> DelimitedTable {
        let indexes = try Self.columnIndexes(selected ?? headers, in: headers)
        var seen = Set<[String]>()
        return DelimitedTable(headers: headers, rows: rows.filter { row in seen.insert(indexes.map { row[$0] }).inserted })
    }

    public func sorted(column: String, ascending: Bool) throws -> DelimitedTable {
        let index = try Self.columnIndexes([column], in: headers)[0]
        return DelimitedTable(headers: headers, rows: rows.sorted { left, right in
            let comparison = left[index].localizedStandardCompare(right[index])
            if comparison == .orderedSame { return left.lexicographicallyPrecedes(right) }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        })
    }

    public func filtered(column: String, value: String) throws -> DelimitedTable {
        let index = try Self.columnIndexes([column], in: headers)[0]
        let expected = value.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return DelimitedTable(headers: headers, rows: rows.filter {
            $0[index].trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == expected
        })
    }

    public func selecting(columns selected: [String]) throws -> DelimitedTable {
        let indexes = try Self.columnIndexes(selected, in: headers)
        return DelimitedTable(headers: indexes.map { headers[$0] }, rows: rows.map { row in indexes.map { row[$0] } })
    }

    public func renamingColumn(from oldName: String, to newName: String) throws -> DelimitedTable {
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, newName.count <= 128 else {
            throw KioFailure.invalidInput("Enter a non-empty new column name of at most 128 characters.")
        }
        let index = try Self.columnIndexes([oldName], in: headers)[0]
        var result = headers
        result[index] = newName
        guard Set(result).count == result.count else { throw KioFailure.invalidInput("That column name already exists.") }
        return DelimitedTable(headers: result, rows: rows)
    }

    public func statistics() -> String {
        var output = ["Rows: \(rows.count)", "Columns: \(headers.count)", ""]
        for (index, header) in headers.enumerated() {
            let cells = rows.map { $0[index] }
            let nonempty = cells.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let unique = Set(nonempty).count
            output.append("\(header): missing \(cells.count - nonempty.count), unique \(unique)")
            let numbers = nonempty.compactMap(Double.init)
            if !nonempty.isEmpty, numbers.count == nonempty.count {
                let sorted = numbers.sorted()
                let median = sorted.count.isMultiple(of: 2) ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]
                output.append("  numeric min \(Self.number(sorted.first!)), max \(Self.number(sorted.last!)), mean \(Self.number(numbers.reduce(0, +) / Double(numbers.count))), median \(Self.number(median))")
            } else if !nonempty.isEmpty {
                var frequencyCounts: [String: Int] = [:]
                for value in nonempty { frequencyCounts[value, default: 0] += 1 }
                var frequencies = Array(frequencyCounts)
                frequencies.sort { left, right in
                    if left.value != right.value { return left.value > right.value }
                    return left.key.localizedStandardCompare(right.key) == .orderedAscending
                }
                let frequent = frequencies.prefix(5).map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
                if !frequent.isEmpty { output.append("  frequent: \(frequent)") }
            }
        }
        return output.joined(separator: "\n")
    }

    public func comparison(with other: DelimitedTable) -> String {
        let leftRows = Set(rows.map(Self.rowKey))
        let rightRows = Set(other.rows.map(Self.rowKey))
        let added = rightRows.subtracting(leftRows).count
        let removed = leftRows.subtracting(rightRows).count
        let sharedColumns = headers.filter(other.headers.contains)
        let onlyLeft = headers.filter { !other.headers.contains($0) }
        let onlyRight = other.headers.filter { !headers.contains($0) }
        return [
            "Table comparison",
            "Left: \(rows.count) rows, \(headers.count) columns",
            "Right: \(other.rows.count) rows, \(other.headers.count) columns",
            "Shared columns: \(sharedColumns.isEmpty ? "none" : sharedColumns.joined(separator: ", "))",
            "Columns only on left: \(onlyLeft.isEmpty ? "none" : onlyLeft.joined(separator: ", "))",
            "Columns only on right: \(onlyRight.isEmpty ? "none" : onlyRight.joined(separator: ", "))",
            "Rows added on right: \(added)",
            "Rows missing on right: \(removed)"
        ].joined(separator: "\n")
    }

    public static func merged(_ tables: [DelimitedTable]) throws -> DelimitedTable {
        guard let first = tables.first, tables.count >= 2, tables.allSatisfy({ $0.headers == first.headers }) else {
            throw KioFailure.invalidInput("Table merge requires at least two files with exactly matching column headers and order.")
        }
        guard tables.reduce(0, { $0 + $1.rows.count }) <= 100_000 else {
            throw KioFailure.unsupported("Merged tables are limited to 100,000 data rows.")
        }
        return DelimitedTable(headers: first.headers, rows: tables.flatMap(\.rows))
    }

    private static func detectDelimiter(_ text: String) -> Character {
        var commas = 0
        var tabs = 0
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            let next = text.index(after: index)
            if char == "\"" {
                if quoted, next < text.endIndex, text[next] == "\"" { index = text.index(after: next); continue }
                quoted.toggle()
            } else if !quoted, char == "," { commas += 1 }
            else if !quoted, char == "\t" { tabs += 1 }
            else if !quoted, Self.isLineBreak(char) { break }
            index = next
        }
        return tabs > commas ? "\t" : ","
    }

    private static func parseRecords(_ text: String, delimiter: Character) throws -> [[String]] {
        var records: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var closedQuote = false
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            let next = text.index(after: index)
            if quoted {
                if char == "\"" {
                    if next < text.endIndex, text[next] == "\"" { field.append("\""); index = text.index(after: next); continue }
                    quoted = false
                    closedQuote = true
                } else { field.append(char) }
            } else if closedQuote {
                if char == delimiter {
                    row.append(field); field = ""; closedQuote = false
                } else if Self.isLineBreak(char) {
                    row.append(field); records.append(row); row = []; field = ""; closedQuote = false
                } else {
                    throw KioFailure.invalidInput("This CSV/TSV file has data after a quoted cell.")
                }
            } else if char == "\"" && field.isEmpty {
                quoted = true
            } else if char == "\"" {
                throw KioFailure.invalidInput("This CSV/TSV file has a quote inside an unquoted cell.")
            } else if char == delimiter {
                row.append(field); field = ""
            } else if Self.isLineBreak(char) {
                row.append(field); records.append(row); row = []; field = ""
            } else {
                field.append(char)
            }
            if field.count > 1_000_000 { throw KioFailure.unsupported("A table cell exceeds Kio's 1 MB safety limit.") }
            index = next
            if records.count > 100_000 { throw KioFailure.unsupported("Kio's local table limit is 100,000 data rows.") }
        }
        guard !quoted else { throw KioFailure.invalidInput("This CSV/TSV file contains an unclosed quoted cell.") }
        if !field.isEmpty || !row.isEmpty || closedQuote { row.append(field); records.append(row) }
        return records
    }

    private static func columnIndexes(_ names: [String], in headers: [String]) throws -> [Int] {
        guard !names.isEmpty, Set(names).count == names.count else { throw KioFailure.invalidInput("Choose one or more distinct table columns.") }
        return try names.map { name in
            guard let index = headers.firstIndex(of: name) else { throw KioFailure.invalidInput("Column '\(name)' was not found. Available columns: \(headers.joined(separator: ", ")).") }
            return index
        }
    }

    private static func escape(_ value: String, delimiter: Character) -> String {
        let needsQuotes = value.contains(delimiter) || value.contains("\"") || value.contains("\r") || value.contains("\n") || value != value.trimmingCharacters(in: .whitespaces)
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func jsonCell(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let json = String(data: data, encoding: .utf8) { return json }
        return String(describing: value)
    }

    private static func rowKey(_ row: [String]) -> String { row.map { "\($0.utf8.count):\($0)" }.joined(separator: "|") }
    private static func number(_ value: Double) -> String { String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) }
    private static func isLineBreak(_ value: Character) -> Bool { value == "\n" || value == "\r" || value == "\r\n" }
}
