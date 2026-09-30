import AVFoundation
import AppKit
import CZlib
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import KioCore

public struct ToolExecutor: Sendable {
    public init() {}

    public func execute(_ step: TaskStep, inputs: [ArtifactRef]) async throws -> [ArtifactRef] {
        try Task.checkCancellation()
        guard !inputs.isEmpty else { throw KioFailure.invalidInput("Add a file for this operation.") }
        switch step.operation {
        case .mergePDFs:
            guard inputs.count >= 2, inputs.allSatisfy({ $0.kind == .pdf }) else { throw KioFailure.invalidInput("Pip can merge two or more PDFs.") }
            return [try mergePDFs(inputs)]
        case .removePDFPages:
            guard let input = inputs.first, input.kind == .pdf,
                  case .removePages(let indices) = step.arguments else { throw KioFailure.invalidInput("Choose a PDF and page numbers to remove.") }
            return [try removePDFPages(input, indices: indices)]
        case .imagesToPDF:
            guard inputs.allSatisfy({ $0.kind == .image }) else { throw KioFailure.invalidInput("Add image files to create a PDF.") }
            return [try imagesToPDF(inputs)]
        case .resizeImage:
            guard let input = inputs.first, input.kind == .image,
                  case .imageResize(let width) = step.arguments, (1...20_000).contains(width) else {
                throw KioFailure.invalidInput("Choose an image and a width from 1 to 20,000 pixels.")
            }
            return [try resizeImage(input, width: width)]
        case .convertImage:
            guard let input = inputs.first, input.kind == .image,
                  case .imageConvert(let format) = step.arguments, ["png", "jpeg"].contains(format) else {
                throw KioFailure.invalidInput("Choose an image and PNG or JPEG as the output format.")
            }
            return [try convertImage(input, format: format)]
        case .batchRename:
            guard case .rename(let prefix) = step.arguments, !prefix.isEmpty, prefix.count <= 64 else {
                throw KioFailure.invalidInput("Choose a short name prefix for the copies.")
            }
            return try batchRename(inputs, prefix: prefix)
        case .createArchive:
            return [try createZip(inputs)]
        case .compressPDF:
            guard let input = inputs.first, input.kind == .pdf,
                  case .pdfCompression(let maxBytes) = step.arguments else {
                throw KioFailure.invalidInput("Choose a PDF to compress.")
            }
            return [try compressPDF(input, maxBytes: maxBytes)]
        case .extractAudio:
            guard let input = inputs.first, input.kind == .video else { throw KioFailure.invalidInput("Add a video to extract its audio.") }
            return [try await extractAudio(input)]
        }
    }

    private func mergePDFs(_ inputs: [ArtifactRef]) throws -> ArtifactRef {
        let output = try OutputLocation.makeURL(for: inputs, baseName: Self.base(inputs[0].displayName) + "-Merged", fileExtension: "pdf")
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let merged = PDFDocument()
        for input in inputs {
            guard let document = PDFDocument(url: input.fileURL), document.pageCount > 0 else { throw KioFailure.invalidInput("\(input.displayName) could not be opened as a PDF.") }
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { throw KioFailure.processing("A page in \(input.displayName) could not be read.") }
                merged.insert(page, at: merged.pageCount)
            }
        }
        guard merged.pageCount > 0, merged.write(to: temporary),
              let verified = PDFDocument(url: temporary), verified.pageCount == merged.pageCount else {
            throw KioFailure.verification("The merged PDF could not be verified.")
        }
        try OutputLocation.commit(temporary, to: output)
        return try ArtifactRef.inspect(output, parentID: inputs.first?.id)
    }

    private func removePDFPages(_ input: ArtifactRef, indices: [Int]) throws -> ArtifactRef {
        guard let document = PDFDocument(url: input.fileURL), document.pageCount > 0 else { throw KioFailure.invalidInput("This PDF could not be opened.") }
        let pages = Set(indices.filter { (1...document.pageCount).contains($0) })
        guard !pages.isEmpty, pages.count < document.pageCount else { throw KioFailure.invalidInput("Choose valid pages and leave at least one page in the PDF.") }
        let output = try OutputLocation.makeURL(for: [input], baseName: Self.base(input.displayName) + "-Edited", fileExtension: "pdf")
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for index in pages.sorted(by: >) { document.removePage(at: index - 1) }
        guard document.write(to: temporary), let verified = PDFDocument(url: temporary), verified.pageCount == document.pageCount else {
            throw KioFailure.verification("The edited PDF could not be verified.")
        }
        try OutputLocation.commit(temporary, to: output)
        return try ArtifactRef.inspect(output, parentID: input.id)
    }

    private func compressPDF(_ input: ArtifactRef, maxBytes: Int64?) throws -> ArtifactRef {
        if let maxBytes, maxBytes <= 0 { throw KioFailure.invalidInput("Choose a size greater than zero bytes.") }
        guard let original = PDFDocument(url: input.fileURL), original.pageCount > 0 else { throw KioFailure.invalidInput("This PDF could not be opened.") }
        let output = try OutputLocation.makeURL(for: [input], baseName: Self.base(input.displayName) + "-Compressed", fileExtension: "pdf")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("KioPDF-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let strategies: [(dpi: CGFloat, quality: CGFloat)] = [(180, 0.84), (150, 0.77), (120, 0.68)]
        var best: (url: URL, size: Int64)?
        var reachedTarget = false
        for (index, strategy) in strategies.enumerated() {
            try Task.checkCancellation()
            let candidate = work.appendingPathComponent("candidate-\(index).pdf")
            try renderCompressedPDF(original, dpi: strategy.dpi, quality: strategy.quality, to: candidate)
            guard let verified = PDFDocument(url: candidate), verified.pageCount == original.pageCount else {
                throw KioFailure.verification("The compressed PDF failed its page-count check.")
            }
            let size = Int64(try candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            if best == nil || size < best!.size { best = (candidate, size) }
            if let maxBytes, size <= maxBytes {
                best = (candidate, size)
                reachedTarget = true
                break
            }
            if maxBytes == nil, size < Int64(Double(input.sizeBytes) * 0.97) {
                best = (candidate, size)
                break
            }
        }
        guard let best, best.size > 0 else { throw KioFailure.verification("Kio could not create a compressed PDF.") }
        guard best.size < input.sizeBytes else { throw KioFailure.processing("This PDF did not get smaller without lowering readability further.") }
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: best.url, to: temporary)
        try OutputLocation.commit(temporary, to: output)
        let preservationNote = "Pages in this compressed copy are flattened images, so text and links may no longer be selectable. The original remains unchanged."
        let note: String
        if let maxBytes, !reachedTarget {
            note = "I made a smaller copy at \(ByteCountFormatter.string(fromByteCount: best.size, countStyle: .file)), but could not reach \(ByteCountFormatter.string(fromByteCount: maxBytes, countStyle: .file)) without making the pages harder to read. \(preservationNote)"
        } else {
            note = "Done. The PDF copy was compressed. \(preservationNote)"
        }
        return try ArtifactRef.inspect(output, parentID: input.id).withVerificationNote(note)
    }

    private func renderCompressedPDF(_ source: PDFDocument, dpi: CGFloat, quality: CGFloat, to url: URL) throws {
        let result = PDFDocument()
        for index in 0..<source.pageCount {
            try Task.checkCancellation()
            guard let page = source.page(at: index) else { throw KioFailure.processing("A PDF page could not be read.") }
            let bounds = page.bounds(for: .mediaBox)
            let pixelSize = CGSize(width: max(1, bounds.width * dpi / 72), height: max(1, bounds.height * dpi / 72))
            let thumbnail = page.thumbnail(of: pixelSize, for: .mediaBox)
            var proposed = CGRect(origin: .zero, size: thumbnail.size)
            guard let cgImage = thumbnail.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
                throw KioFailure.processing("A PDF page could not be rendered for compression.")
            }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw KioFailure.processing("Kio could not prepare a compressed page image.")
            }
            CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination), let image = NSImage(data: data as Data), let outputPage = PDFPage(image: image) else {
                throw KioFailure.processing("A compressed page image could not be embedded.")
            }
            result.insert(outputPage, at: result.pageCount)
        }
        guard result.pageCount == source.pageCount, result.write(to: url) else {
            throw KioFailure.verification("The compressed PDF could not be written.")
        }
    }

    private func imagesToPDF(_ inputs: [ArtifactRef]) throws -> ArtifactRef {
        let output = try OutputLocation.makeURL(for: inputs, baseName: Self.base(inputs[0].displayName) + "-Images", fileExtension: "pdf")
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let document = PDFDocument()
        for input in inputs {
            guard let source = CGImageSourceCreateWithURL(input.fileURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let page = PDFPage(image: NSImage(cgImage: image, size: .zero)) else {
                throw KioFailure.invalidInput("\(input.displayName) could not be opened as an image.")
            }
            document.insert(page, at: document.pageCount)
        }
        guard document.pageCount == inputs.count, document.write(to: temporary),
              let verified = PDFDocument(url: temporary), verified.pageCount == inputs.count else {
            throw KioFailure.verification("The image PDF could not be verified.")
        }
        try OutputLocation.commit(temporary, to: output)
        return try ArtifactRef.inspect(output, parentID: inputs.first?.id)
    }

    private func resizeImage(_ input: ArtifactRef, width: Int) throws -> ArtifactRef {
        guard let source = CGImageSourceCreateWithURL(input.fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw KioFailure.invalidInput("This image could not be opened.") }
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        let output = try OutputLocation.makeURL(for: [input], baseName: Self.base(input.displayName) + "-Resized", fileExtension: Self.imageExtension(for: input.fileURL) ?? "png")
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = CGImageDestinationCreateWithURL(temporary as CFURL, Self.imageUTI(for: output.pathExtension), 1, nil) else {
            throw KioFailure.processing("Kio could not create the resized image.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { throw KioFailure.processing("Kio could not render the resized image.") }
        CGImageDestinationAddImage(destination, resized, nil)
        guard CGImageDestinationFinalize(destination),
              let check = CGImageSourceCreateWithURL(temporary as CFURL, nil),
              let verified = CGImageSourceCreateImageAtIndex(check, 0, nil), verified.width == width, verified.height == height else {
            throw KioFailure.verification("The resized image dimensions could not be verified.")
        }
        try OutputLocation.commit(temporary, to: output)
        return try ArtifactRef.inspect(output, parentID: input.id)
    }

    private func convertImage(_ input: ArtifactRef, format: String) throws -> ArtifactRef {
        guard let source = CGImageSourceCreateWithURL(input.fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw KioFailure.invalidInput("This image could not be opened.") }
        let ext = format == "jpeg" ? "jpg" : "png"
        let output = try OutputLocation.makeURL(for: [input], baseName: Self.base(input.displayName), fileExtension: ext)
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, Self.imageUTI(for: ext), 1, nil) else {
            throw KioFailure.processing("Kio could not create the converted image.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination),
              let check = CGImageSourceCreateWithURL(temporary as CFURL, nil),
              CGImageSourceGetCount(check) == 1 else { throw KioFailure.verification("The converted image could not be verified.") }
        try OutputLocation.commit(temporary, to: output)
        return try ArtifactRef.inspect(output, parentID: input.id)
    }

    private func batchRename(_ inputs: [ArtifactRef], prefix: String) throws -> [ArtifactRef] {
        var created: [ArtifactRef] = []
        do {
            for (index, input) in inputs.enumerated() {
                try Task.checkCancellation()
                let stem = String(format: "%@-%03d", prefix, index + 1)
                let output = try OutputLocation.makeURL(for: [input], baseName: stem + "-" + Self.base(input.displayName), fileExtension: input.fileURL.pathExtension)
                try FileManager.default.copyItem(at: input.fileURL, to: output)
                let result = try ArtifactRef.inspect(output, parentID: input.id)
                guard result.sizeBytes == input.sizeBytes else { throw KioFailure.verification("The copy of \(input.displayName) did not verify.") }
                created.append(result)
            }
            return created
        } catch {
            for output in created { try? FileManager.default.removeItem(at: output.fileURL) }
            throw error
        }
    }

    private func createZip(_ inputs: [ArtifactRef]) throws -> ArtifactRef {
        let output = try OutputLocation.makeURL(for: inputs, baseName: Self.base(inputs[0].displayName) + "-Archive", fileExtension: "zip")
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("KioZip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var entries: [ZipEntry] = []
        var occupied = Set<String>()
        for input in inputs {
            try Task.checkCancellation()
            if input.kind == .folder {
                let root = input.fileURL
                guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
                    throw KioFailure.invalidInput("The folder \(input.displayName) could not be read.")
                }
                for case let fileURL as URL in enumerator {
                    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true else { continue }
                    guard values.isRegularFile == true else { continue }
                    let relative = String(fileURL.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    try Self.appendZipEntry(fileURL, path: Self.safeZipPath("\(root.lastPathComponent)/\(relative)"), staging: staging, to: &entries, occupied: &occupied)
                }
            } else {
                try Self.appendZipEntry(input.fileURL, path: Self.safeZipPath(input.displayName), staging: staging, to: &entries, occupied: &occupied)
            }
        }
        guard !entries.isEmpty, entries.count < Int(UInt16.max) else { throw KioFailure.invalidInput("Choose files or folders with fewer than 65,535 files.") }
        guard entries.allSatisfy({ $0.size <= UInt32.max && $0.compressedSize <= UInt32.max }) else { throw KioFailure.unsupported("This ZIP format supports files up to 4 GB in this build.") }
        let handle = try FileHandle(forWritingTo: Self.createEmptyFile(at: temporary))
        defer { try? handle.close() }
        var central: [(ZipEntry, UInt32)] = []
        for entry in entries {
            try Task.checkCancellation()
            let offset = try handle.offset()
            guard offset <= UInt32.max else { throw KioFailure.unsupported("This ZIP would exceed the classic ZIP size limit.") }
            central.append((entry, UInt32(offset)))
            try Self.writeLocalHeader(entry, to: handle)
            let source = try FileHandle(forReadingFrom: entry.compressedURL)
            defer { try? source.close() }
            while true {
                try Task.checkCancellation()
                let chunk = try source.read(upToCount: 1_048_576) ?? Data()
                if chunk.isEmpty { break }
                try handle.write(contentsOf: chunk)
            }
        }
        let centralStart = try handle.offset()
        for (entry, offset) in central { try Self.writeCentralHeader(entry, offset: offset, to: handle) }
        let centralEnd = try handle.offset()
        guard centralStart <= UInt32.max, centralEnd - centralStart <= UInt32.max else { throw KioFailure.unsupported("This ZIP would exceed the classic ZIP size limit.") }
        try Self.writeEndRecord(count: UInt16(central.count), centralSize: UInt32(centralEnd - centralStart), centralOffset: UInt32(centralStart), to: handle)
        try handle.synchronize()
        try handle.close()
        guard try Self.verifyZip(at: temporary) == entries.count else { throw KioFailure.verification("The ZIP archive could not be verified.") }
        try OutputLocation.commit(temporary, to: output)
        return try ArtifactRef.inspect(output, parentID: inputs.first?.id)
    }

    private struct ZipEntry {
        let compressedURL: URL
        let path: String
        let name: Data
        let size: UInt64
        let compressedSize: UInt64
        let crc: UInt32
    }

    private static func appendZipEntry(_ url: URL, path: String, staging: URL, to entries: inout [ZipEntry], occupied: inout Set<String>) throws {
        var uniquePath = path
        var suffix = 2
        while occupied.contains(uniquePath) {
            let item = URL(fileURLWithPath: path)
            uniquePath = item.deletingPathExtension().lastPathComponent + "-\(suffix)" + (item.pathExtension.isEmpty ? "" : ".\(item.pathExtension)")
            suffix += 1
        }
        occupied.insert(uniquePath)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { return }
        let compressedURL = staging.appendingPathComponent("entry-\(entries.count).deflate")
        guard FileManager.default.createFile(atPath: compressedURL.path, contents: Data()) else {
            throw KioFailure.processing("Kio could not prepare the temporary archive data.")
        }
        let source = try FileHandle(forReadingFrom: url)
        let destination = try FileHandle(forWritingTo: compressedURL)
        defer { try? source.close(); try? destination.close() }
        var stream = z_stream()
        let initialized = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw KioFailure.processing("Kio could not start ZIP compression.") }
        defer { deflateEnd(&stream) }
        var crc: UInt32 = 0xffff_ffff
        var totalSize: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try source.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            totalSize += UInt64(chunk.count)
            for byte in chunk {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
            }
            try chunk.withUnsafeBytes { input in
                guard let inputBase = input.baseAddress else { return }
                stream.next_in = UnsafeMutablePointer(mutating: inputBase.assumingMemoryBound(to: Bytef.self))
                stream.avail_in = uInt(chunk.count)
                var shouldDrain = true
                while stream.avail_in > 0 || shouldDrain {
                    var outputBytes = [UInt8](repeating: 0, count: 65_536)
                    let result = outputBytes.withUnsafeMutableBufferPointer { output in
                        stream.next_out = output.baseAddress
                        stream.avail_out = uInt(output.count)
                        let code = deflate(&stream, Z_NO_FLUSH)
                        let written = output.count - Int(stream.avail_out)
                        return (code, Data(bytes: output.baseAddress!, count: written), stream.avail_out == 0)
                    }
                    guard result.0 == Z_OK else { throw KioFailure.processing("ZIP compression failed.") }
                    if !result.1.isEmpty { try destination.write(contentsOf: result.1) }
                    shouldDrain = result.2
                }
            }
        }
        while true {
            try Task.checkCancellation()
            var outputBytes = [UInt8](repeating: 0, count: 65_536)
            let result = outputBytes.withUnsafeMutableBufferPointer { output in
                stream.next_out = output.baseAddress
                stream.avail_out = uInt(output.count)
                let code = deflate(&stream, Z_FINISH)
                let written = output.count - Int(stream.avail_out)
                return (code, Data(bytes: output.baseAddress!, count: written))
            }
            if !result.1.isEmpty { try destination.write(contentsOf: result.1) }
            if result.0 == Z_STREAM_END { break }
            guard result.0 == Z_OK else { throw KioFailure.processing("ZIP compression could not finish.") }
        }
        try destination.synchronize()
        let compressedSize = UInt64(try compressedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        entries.append(ZipEntry(compressedURL: compressedURL, path: uniquePath, name: Data(uniquePath.utf8), size: totalSize,
                                compressedSize: compressedSize, crc: crc ^ 0xffff_ffff))
    }

    private static func safeZipPath(_ path: String) -> String {
        path.split(separator: "/").filter { !$0.isEmpty && $0 != "." && $0 != ".." }.joined(separator: "/")
    }

    private static func createEmptyFile(at url: URL) throws -> URL {
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    private static func writeLocalHeader(_ entry: ZipEntry, to handle: FileHandle) throws {
        var data = Data()
        data.appendLE(UInt32(0x04034b50)); data.appendLE(UInt16(20)); data.appendLE(UInt16(0x0800)); data.appendLE(UInt16(8))
        data.appendLE(UInt16(0)); data.appendLE(UInt16(0x0021)); data.appendLE(entry.crc)
        data.appendLE(UInt32(entry.compressedSize)); data.appendLE(UInt32(entry.size)); data.appendLE(UInt16(entry.name.count)); data.appendLE(UInt16(0))
        data.append(entry.name)
        try handle.write(contentsOf: data)
    }

    private static func writeCentralHeader(_ entry: ZipEntry, offset: UInt32, to handle: FileHandle) throws {
        var data = Data()
        data.appendLE(UInt32(0x02014b50)); data.appendLE(UInt16(20)); data.appendLE(UInt16(20)); data.appendLE(UInt16(0x0800)); data.appendLE(UInt16(8))
        data.appendLE(UInt16(0)); data.appendLE(UInt16(0x0021)); data.appendLE(entry.crc)
        data.appendLE(UInt32(entry.compressedSize)); data.appendLE(UInt32(entry.size)); data.appendLE(UInt16(entry.name.count))
        data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(UInt32(0)); data.appendLE(offset)
        data.append(entry.name)
        try handle.write(contentsOf: data)
    }

    private static func writeEndRecord(count: UInt16, centralSize: UInt32, centralOffset: UInt32, to handle: FileHandle) throws {
        var data = Data()
        data.appendLE(UInt32(0x06054b50)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(count); data.appendLE(count)
        data.appendLE(centralSize); data.appendLE(centralOffset); data.appendLE(UInt16(0))
        try handle.write(contentsOf: data)
    }

    private static func verifyZip(at url: URL) throws -> Int {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 22 else { return 0 }
        let lower = max(0, data.count - 65_557)
        for offset in stride(from: data.count - 22, through: lower, by: -1) {
            if data.readLE(UInt32.self, at: offset) == 0x06054b50 {
                return Int(data.readLE(UInt16.self, at: offset + 10) ?? 0)
            }
        }
        return 0
    }

    private func extractAudio(_ input: ArtifactRef) async throws -> ArtifactRef {
        let asset = AVURLAsset(url: input.fileURL)
        guard try await !asset.load(.tracks).filter({ $0.mediaType == .audio }).isEmpty else {
            throw KioFailure.invalidInput("This video does not contain an audio track.")
        }
        let output = try OutputLocation.makeURL(for: [input], baseName: Self.base(input.displayName) + "-Audio", fileExtension: "m4a")
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw KioFailure.processing("Kio could not prepare audio extraction for this video.")
        }
        try await session.export(to: temporary, as: .m4a)
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: temporary.path),
              try await !AVURLAsset(url: temporary).load(.tracks).filter({ $0.mediaType == .audio }).isEmpty else {
            throw KioFailure.verification("The extracted audio could not be verified.")
        }
        try OutputLocation.commit(temporary, to: output)
        return try ArtifactRef.inspect(output, parentID: input.id)
    }

    private static func base(_ name: String) -> String { URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent }
    private static func imageExtension(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif"].contains(ext) ? ext : nil
    }
    private static func imageUTI(for ext: String) -> CFString { (ext == "jpg" || ext == "jpeg" ? UTType.jpeg : UTType.png).identifier as CFString }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T? {
        guard offset >= 0, offset + MemoryLayout<T>.size <= count else { return nil }
        return withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: T.self).littleEndian
        }
    }
}
