import CZlib
import Foundation
import KioCore

/// A bounded ZIP reader that only writes regular files and directories beneath a new Kio folder.
/// It rejects Zip64, encryption, symlinks, special files, duplicate names, and unsafe paths.
enum SafeZipExtractor {
    private static let maximumArchiveBytes: Int64 = 512 * 1_024 * 1_024
    private static let maximumEntryBytes: UInt64 = 512 * 1_024 * 1_024
    private static let maximumExpandedBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024
    private static let maximumEntryCount = 10_000
    private static let maximumExpansionRatio: UInt64 = 2_000

    private struct Entry {
        let path: String
        let components: [String]
        let isDirectory: Bool
        let method: UInt16
        let flags: UInt16
        let crc: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
        let centralDirectoryOffset: UInt32
        let nameBytes: Data
    }

    static func extract(_ input: ArtifactRef) throws -> ArtifactRef {
        guard input.fileURL.pathExtension.lowercased() == "zip",
              input.sizeBytes > 0, input.sizeBytes <= maximumArchiveBytes else {
            throw KioFailure.invalidInput("Choose a readable ZIP file smaller than 512 MB.")
        }
        let data = try Data(contentsOf: input.fileURL, options: .mappedIfSafe)
        guard Int64(data.count) <= maximumArchiveBytes else { throw unsupportedArchive() }
        let entries = try parse(data)
        let expanded = entries.reduce(UInt64(0)) { $0 + UInt64($1.uncompressedSize) }
        guard expanded <= maximumExpandedBytes else {
            throw KioFailure.unsupported("This ZIP expands beyond Kio's safe 2 GB extraction limit.")
        }
        try validateTree(entries)

        let output = try OutputLocation.makeDirectoryURL(
            for: [input], baseName: URL(fileURLWithPath: input.displayName).deletingPathExtension().lastPathComponent + "-Extracted"
        )
        let staging = output.deletingLastPathComponent().appendingPathComponent(".kio-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            for entry in entries {
                try Task.checkCancellation()
                let destination = entry.components.reduce(staging) { $0.appendingPathComponent($1, isDirectory: false) }
                if entry.isDirectory {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                } else {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try extract(entry, from: data, to: destination)
                }
            }
            try Task.checkCancellation()
            guard !FileManager.default.fileExists(atPath: output.path) else {
                throw KioFailure.processing("A folder with that name appeared while Kio was extracting the ZIP. Please retry.")
            }
            try FileManager.default.moveItem(at: staging, to: output)
            return try ArtifactRef.inspect(output, parentID: input.id)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private static func parse(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw unsupportedArchive() }
        let lower = max(0, data.count - 65_557)
        var endRecord: Int?
        for offset in stride(from: data.count - 22, through: lower, by: -1) {
            guard data.readLE(UInt32.self, at: offset) == 0x06054b50,
                  let commentLength = data.readLE(UInt16.self, at: offset + 20),
                  offset + 22 + Int(commentLength) == data.count else { continue }
            endRecord = offset
            break
        }
        guard let endRecord,
              data.readLE(UInt16.self, at: endRecord + 4) == 0,
              data.readLE(UInt16.self, at: endRecord + 6) == 0,
              let diskEntries = data.readLE(UInt16.self, at: endRecord + 8),
              let entryCount = data.readLE(UInt16.self, at: endRecord + 10),
              diskEntries == entryCount, Int(entryCount) <= maximumEntryCount,
              let centralSize = data.readLE(UInt32.self, at: endRecord + 12),
              let centralOffset = data.readLE(UInt32.self, at: endRecord + 16),
              centralSize != .max, centralOffset != .max else { throw unsupportedArchive() }
        let start = Int(centralOffset)
        let end = start + Int(centralSize)
        guard start >= 0, end >= start, end == endRecord else { throw unsupportedArchive() }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(entryCount))
        var cursor = start
        for _ in 0..<Int(entryCount) {
            guard cursor + 46 <= end, data.readLE(UInt32.self, at: cursor) == 0x02014b50,
                  let flags = data.readLE(UInt16.self, at: cursor + 8),
                  let method = data.readLE(UInt16.self, at: cursor + 10),
                  let crc = data.readLE(UInt32.self, at: cursor + 16),
                  let compressedSize = data.readLE(UInt32.self, at: cursor + 20),
                  let uncompressedSize = data.readLE(UInt32.self, at: cursor + 24),
                  let nameLength = data.readLE(UInt16.self, at: cursor + 28),
                  let extraLength = data.readLE(UInt16.self, at: cursor + 30),
                  let commentLength = data.readLE(UInt16.self, at: cursor + 32),
                  let diskStart = data.readLE(UInt16.self, at: cursor + 34),
                  let externalAttributes = data.readLE(UInt32.self, at: cursor + 38),
                  let localHeaderOffset = data.readLE(UInt32.self, at: cursor + 42) else { throw unsupportedArchive() }
            let next = cursor + 46 + Int(nameLength) + Int(extraLength) + Int(commentLength)
            guard next <= end, diskStart == 0,
                  compressedSize != .max, uncompressedSize != .max, localHeaderOffset != .max,
                  flags & ~UInt16(0x080e) == 0, flags & 0x0001 == 0,
                  method == 0 || method == 8 else { throw unsupportedArchive() }

            let nameBytes = data.subdata(in: (cursor + 46)..<(cursor + 46 + Int(nameLength)))
            guard let rawPath = String(data: nameBytes, encoding: .utf8),
                  let (path, components, isDirectory) = safePath(rawPath) else { throw unsafeArchive() }
            let unixType = UInt16(truncatingIfNeeded: externalAttributes >> 16) & 0xf000
            guard unixType != 0xa000, unixType == 0 || unixType == 0x8000 || unixType == 0x4000 else {
                throw unsafeArchive()
            }
            guard uncompressedSize <= maximumEntryBytes,
                  UInt64(uncompressedSize) <= max(UInt64(1), UInt64(compressedSize)) * maximumExpansionRatio,
                  (!isDirectory || (compressedSize == 0 && uncompressedSize == 0)) else { throw unsafeArchive() }
            entries.append(Entry(path: path, components: components, isDirectory: isDirectory,
                                 method: method, flags: flags, crc: crc, compressedSize: compressedSize,
                                 uncompressedSize: uncompressedSize, localHeaderOffset: localHeaderOffset,
                                 centralDirectoryOffset: centralOffset,
                                 nameBytes: nameBytes))
            cursor = next
        }
        guard cursor == end else { throw unsupportedArchive() }
        return entries
    }

    private static func safePath(_ path: String) -> (String, [String], Bool)? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\"),
              !path.contains("\\"), !path.contains(":"), !path.contains("\0"),
              path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let isDirectory = path.hasSuffix("/")
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let usable = isDirectory ? Array(components.dropLast()) : components
        guard !usable.isEmpty, usable.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return (usable.joined(separator: "/"), usable, isDirectory)
    }

    private static func validateTree(_ entries: [Entry]) throws {
        var paths: [String: Bool] = [:]
        for entry in entries {
            let key = entry.path.precomposedStringWithCanonicalMapping.lowercased()
            guard paths[key] == nil else { throw unsafeArchive() }
            paths[key] = entry.isDirectory
        }
        for entry in entries where !entry.isDirectory {
            for length in 1..<entry.components.count {
                let parent = entry.components.prefix(length).joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()
                if paths[parent] == false { throw unsafeArchive() }
            }
        }
        for entry in entries where entry.isDirectory {
            for length in 1..<entry.components.count {
                let parent = entry.components.prefix(length).joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()
                if paths[parent] == false { throw unsafeArchive() }
            }
        }
    }

    private static func extract(_ entry: Entry, from data: Data, to destination: URL) throws {
        let local = Int(entry.localHeaderOffset)
        guard local + 30 <= data.count, data.readLE(UInt32.self, at: local) == 0x04034b50,
              let localFlags = data.readLE(UInt16.self, at: local + 6),
              let localMethod = data.readLE(UInt16.self, at: local + 8),
              let localNameLength = data.readLE(UInt16.self, at: local + 26),
              let localExtraLength = data.readLE(UInt16.self, at: local + 28),
              localFlags == entry.flags, localMethod == entry.method,
              Int(localNameLength) == entry.nameBytes.count else { throw unsupportedArchive() }
        let localNameStart = local + 30
        let localNameEnd = localNameStart + Int(localNameLength)
        let dataStart = localNameEnd + Int(localExtraLength)
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard localNameEnd <= data.count, dataEnd >= dataStart, dataEnd <= data.count,
              dataEnd <= Int(entry.centralDirectoryOffset),
              data.subdata(in: localNameStart..<localNameEnd) == entry.nameBytes else { throw unsupportedArchive() }

        guard FileManager.default.createFile(atPath: destination.path, contents: Data()) else { throw unsafeArchive() }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var outputSize: UInt64 = 0
        var crc: uLong = 0

        func write(_ chunk: Data) throws {
            outputSize += UInt64(chunk.count)
            guard outputSize <= maximumEntryBytes,
                  outputSize <= maximumExpandedBytes else { throw unsafeArchive() }
            chunk.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress {
                    crc = crc32(crc, base.assumingMemoryBound(to: Bytef.self), uInt(chunk.count))
                }
            }
            try handle.write(contentsOf: chunk)
        }

        if entry.method == 0 {
            guard entry.compressedSize == entry.uncompressedSize else { throw unsupportedArchive() }
            var cursor = dataStart
            while cursor < dataEnd {
                try Task.checkCancellation()
                let next = min(dataEnd, cursor + 65_536)
                try write(data.subdata(in: cursor..<next))
                cursor = next
            }
        } else if entry.compressedSize > 0 {
            var stream = z_stream()
            let initialized = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard initialized == Z_OK else { throw KioFailure.processing("Kio could not start safe ZIP decompression.") }
            defer { inflateEnd(&stream) }
            var compressedOffset = dataStart
            var remaining = dataEnd - dataStart
            var ended = false
            while !ended {
                try Task.checkCancellation()
                if stream.avail_in == 0, remaining > 0 {
                    let amount = min(remaining, 65_536)
                    data.withUnsafeBytes { bytes in
                        let base = bytes.baseAddress!.advanced(by: compressedOffset)
                        stream.next_in = UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: Bytef.self))
                    }
                    stream.avail_in = uInt(amount)
                    compressedOffset += amount
                    remaining -= amount
                }
                var output = [UInt8](repeating: 0, count: 65_536)
                let result = output.withUnsafeMutableBufferPointer { buffer -> (Int32, Data) in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    let written = buffer.count - Int(stream.avail_out)
                    return (status, Data(bytes: buffer.baseAddress!, count: written))
                }
                if !result.1.isEmpty { try write(result.1) }
                if result.0 == Z_STREAM_END { ended = true }
                else if result.0 != Z_OK || (result.1.isEmpty && stream.avail_in == 0 && remaining == 0) {
                    throw KioFailure.verification("ZIP entry \(entry.path) did not decompress cleanly.")
                }
            }
            guard ended, remaining == 0, stream.avail_in == 0 else { throw unsupportedArchive() }
        }
        try handle.synchronize()
        guard outputSize == UInt64(entry.uncompressedSize), UInt32(truncatingIfNeeded: crc) == entry.crc else {
            throw KioFailure.verification("ZIP entry \(entry.path) failed its size or checksum check.")
        }
    }

    private static func unsupportedArchive() -> KioFailure { .unsupported("This ZIP uses an unsupported or malformed format.") }
    private static func unsafeArchive() -> KioFailure { .invalidInput("This ZIP contains an unsafe path, link, duplicate, or oversized entry, so Kio did not extract it.") }
}

private extension Data {
    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T? {
        guard offset >= 0, offset + MemoryLayout<T>.size <= count else { return nil }
        return withUnsafeBytes { bytes in bytes.loadUnaligned(fromByteOffset: offset, as: T.self).littleEndian }
    }
}
