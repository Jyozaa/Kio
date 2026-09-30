import AppKit
import Foundation
import ImageIO
import PDFKit
import Testing
import KioCore
import KioTools

@Test func mergePDFsProducesVerifiedOutputAndPreservesSources() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let aURL = folder.appendingPathComponent("one.pdf")
    let bURL = folder.appendingPathComponent("two.pdf")
    try makePDF(pageCount: 2).write(to: aURL)
    try makePDF(pageCount: 1).write(to: bURL)
    let a = try ArtifactRef.inspect(aURL)
    let b = try ArtifactRef.inspect(bURL)
    let originalSizes = [a.sizeBytes, b.sizeBytes]
    let step = TaskStep(operation: .mergePDFs, source: .artifacts([a.id, b.id]))

    let results = try await ToolExecutor().execute(step, inputs: [a, b])

    #expect(results.count == 1)
    #expect(results[0].kind == .pdf)
    #expect(PDFDocument(url: results[0].fileURL)?.pageCount == 3)
    #expect([try ArtifactRef.inspect(aURL).sizeBytes, try ArtifactRef.inspect(bURL).sizeBytes] == originalSizes)
}

@Test func resizeImageVerifiesDimensionsAndDoesNotReplaceSource() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sourceURL = folder.appendingPathComponent("sample.png")
    try makePNG(width: 100, height: 50).write(to: sourceURL)
    let source = try ArtifactRef.inspect(sourceURL)
    let originalSize = source.sizeBytes
    let step = TaskStep(operation: .resizeImage, source: .artifacts([source.id]), arguments: .imageResize(width: 40))

    let results = try await ToolExecutor().execute(step, inputs: [source])
    let imageSource = CGImageSourceCreateWithURL(results[0].fileURL as CFURL, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)! as NSDictionary

    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 40)
    #expect(properties[kCGImagePropertyPixelHeight] as? Int == 20)
    #expect(try ArtifactRef.inspect(sourceURL).sizeBytes == originalSize)
}

@Test func resizingGIFWritesPNGContentWithPNGExtension() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sourceURL = folder.appendingPathComponent("sample.gif")
    let image = makeCGImage(width: 48, height: 24)
    let encoded = NSMutableData()
    let sourceWriter = CGImageDestinationCreateWithData(encoded, "com.compuserve.gif" as CFString, 1, nil)!
    CGImageDestinationAddImage(sourceWriter, image, nil)
    #expect(CGImageDestinationFinalize(sourceWriter))
    try (encoded as Data).write(to: sourceURL)
    let input = try ArtifactRef.inspect(sourceURL)
    let step = TaskStep(operation: .resizeImage, source: .artifacts([input.id]), arguments: .imageResize(width: 24))

    let output = try await ToolExecutor().execute(step, inputs: [input])[0]
    let imageSource = try #require(CGImageSourceCreateWithURL(output.fileURL as CFURL, nil))

    #expect(output.fileURL.pathExtension.lowercased() == "png")
    #expect(CGImageSourceGetType(imageSource) as String? == "public.png")
    #expect(CGImageSourceCreateImageAtIndex(imageSource, 0, nil)?.width == 24)
}

@Test func zipArchiveRoundTripsThroughSystemArchiveReader() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sourceURL = folder.appendingPathComponent("notes.txt")
    let sourceData = Data(repeating: 0x4b, count: 200_000)
    try sourceData.write(to: sourceURL)
    let source = try ArtifactRef.inspect(sourceURL)
    let step = TaskStep(operation: .createArchive, source: .artifacts([source.id]))

    let results = try await ToolExecutor().execute(step, inputs: [source])
    #expect(results[0].sizeBytes < source.sizeBytes / 2)
    let destination = folder.appendingPathComponent("unzipped", isDirectory: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", results[0].fileURL.path, destination.path]
    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    #expect(try Data(contentsOf: destination.appendingPathComponent("notes.txt")) == sourceData)
    #expect(try Data(contentsOf: sourceURL) == sourceData)
}

@Test func imagePagesPDFAndPageRemovalVerifyPageCounts() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let urls = [folder.appendingPathComponent("one.png"), folder.appendingPathComponent("two.png")]
    try makePNG(width: 64, height: 32).write(to: urls[0])
    try makePNG(width: 32, height: 64).write(to: urls[1])
    let images = try urls.map { try ArtifactRef.inspect($0) }
    let pdf = try await ToolExecutor().execute(TaskStep(operation: .imagesToPDF, source: .artifacts(images.map(\.id))), inputs: images)[0]
    #expect(PDFDocument(url: pdf.fileURL)?.pageCount == 2)
    let pageTwo = TaskStep(operation: .removePDFPages, source: .artifacts([pdf.id]), arguments: .removePages(indices: [2]))
    let edited = try await ToolExecutor().execute(pageTwo, inputs: [pdf])[0]
    #expect(PDFDocument(url: edited.fileURL)?.pageCount == 1)
    #expect(PDFDocument(url: pdf.fileURL)?.pageCount == 2)
}

@Test func batchRenameMakesConflictSafeCopies() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let urls = [folder.appendingPathComponent("one.txt"), folder.appendingPathComponent("two.txt")]
    try Data("one".utf8).write(to: urls[0])
    try Data("two".utf8).write(to: urls[1])
    let inputs = try urls.map { try ArtifactRef.inspect($0) }
    let step = TaskStep(operation: .batchRename, source: .artifacts(inputs.map(\.id)), arguments: .rename(prefix: "lecture"))

    let first = try await ToolExecutor().execute(step, inputs: inputs)
    let second = try await ToolExecutor().execute(step, inputs: inputs)

    #expect(first.map(\.displayName) == ["lecture-001-one.txt", "lecture-002-two.txt"])
    #expect(second.map(\.displayName) == ["lecture-001-one-2.txt", "lecture-002-two-2.txt"])
    #expect(try Data(contentsOf: urls[0]) == Data("one".utf8))
}

@Test func exactRenameMakesRequestedCopyAndResolvesConflicts() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sourceURL = folder.appendingPathComponent("original.txt")
    let original = Data("keep the original".utf8)
    try original.write(to: sourceURL)
    let input = try ArtifactRef.inspect(sourceURL)
    let step = TaskStep(operation: .renameFile, source: .artifacts([input.id]), arguments: .exactRename(name: "Kio-Mobile-Followup"))

    let first = try await ToolExecutor().execute(step, inputs: [input])[0]
    let second = try await ToolExecutor().execute(step, inputs: [input])[0]

    #expect(first.displayName == "Kio-Mobile-Followup.txt")
    #expect(second.displayName == "Kio-Mobile-Followup-2.txt")
    #expect(first.kind == .text)
    #expect(try Data(contentsOf: sourceURL) == original)
    #expect(try Data(contentsOf: first.fileURL) == original)
}

@Test func exactRenameSanitizesPathAndRejectsIncompatibleExtension() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sourceURL = folder.appendingPathComponent("original.txt")
    try Data("safe".utf8).write(to: sourceURL)
    let input = try ArtifactRef.inspect(sourceURL)
    let sanitized = try await ToolExecutor().execute(
        TaskStep(operation: .renameFile, source: .artifacts([input.id]), arguments: .exactRename(name: "../../traversal.txt")),
        inputs: [input]
    )[0]

    #expect(sanitized.displayName == "traversal.txt")
    #expect(sanitized.fileURL.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
    await #expect(throws: (any Error).self) {
        try await ToolExecutor().execute(
            TaskStep(operation: .renameFile, source: .artifacts([input.id]), arguments: .exactRename(name: "wrong.pdf")),
            inputs: [input]
        )
    }
    #expect(try Data(contentsOf: sourceURL) == Data("safe".utf8))
}

@Test func pdfCompressionReturnsOnlyAnHonestSmallerCopy() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sourceURL = folder.appendingPathComponent("large.pdf")
    let document = PDFDocument()
    let image = makeNoiseCGImage(width: 1_600, height: 1_600)
    document.insert(PDFPage(image: NSImage(cgImage: image, size: NSSize(width: 540, height: 700)))!, at: 0)
    #expect(document.write(to: sourceURL))
    let input = try ArtifactRef.inspect(sourceURL)
    let originalSize = input.sizeBytes
    let step = TaskStep(operation: .compressPDF, source: .artifacts([input.id]), arguments: .pdfCompression(maxBytes: nil))

    let output = try await ToolExecutor().execute(step, inputs: [input])[0]

    #expect(output.sizeBytes < originalSize)
    #expect(PDFDocument(url: output.fileURL)?.pageCount == 1)
    #expect(try ArtifactRef.inspect(sourceURL).sizeBytes == originalSize)
}

private func makePDF(pageCount: Int) throws -> PDFDocument {
    let document = PDFDocument()
    let bitmap = makeCGImage(width: 16, height: 16)
    for _ in 0..<pageCount {
        let page = PDFPage(image: NSImage(cgImage: bitmap, size: NSSize(width: 16, height: 16)))!
        document.insert(page, at: document.pageCount)
    }
    return document
}

private func makePNG(width: Int, height: Int) throws -> Data {
    let image = makeCGImage(width: width, height: height)
    let mutable = NSMutableData()
    let destination = CGImageDestinationCreateWithData(mutable, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return mutable as Data
}

private func makeCGImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.systemBlue.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private func makeNoiseCGImage(width: Int, height: Int) -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    var state: UInt32 = 0x3141_5926
    for y in 0..<height {
        for x in 0..<width {
            let block = (y / 3 * ((width + 2) / 3) + x / 3) * 4
            if x % 3 == 0 && y % 3 == 0 {
                state ^= state << 13
                state ^= state >> 17
                state ^= state << 5
                bytes[block] = UInt8(truncatingIfNeeded: state)
                bytes[block + 1] = UInt8(truncatingIfNeeded: state >> 8)
                bytes[block + 2] = UInt8(truncatingIfNeeded: state >> 16)
            } else {
                let source = ((y / 3) * ((width + 2) / 3) + x / 3) * 4
                bytes[(y * width + x) * 4] = bytes[source]
                bytes[(y * width + x) * 4 + 1] = bytes[source + 1]
                bytes[(y * width + x) * 4 + 2] = bytes[source + 2]
            }
        }
    }
    let data = Data(bytes) as CFData
    let provider = CGDataProvider(data: data)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}
