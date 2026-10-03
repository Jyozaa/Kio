import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
import KioCore
@testable import KioTools

@Test func convertImageFormatsKeepExtensionsAndEncodedTypesInAgreement() async throws {
    let folder = try makeConvertTestFolder("KioConvertImages")
    defer { try? FileManager.default.removeItem(at: folder) }
    let sourceURL = folder.appendingPathComponent("sample.png")
    try makeConvertPNG(width: 64, height: 40).write(to: sourceURL)
    let source = try ArtifactRef.inspect(sourceURL)
    let original = try Data(contentsOf: sourceURL)
    let executor = ToolExecutor()

    for (format, ext, uti) in [("jpeg", "jpeg", UTType.jpeg.identifier),
                               ("tiff", "tiff", UTType.tiff.identifier)] {
        let output = try #require(try await executor.execute(
            TaskStep(operation: .convertImage, source: .artifacts([source.id]), arguments: .imageConvert(format: format)),
            inputs: [source]).first)
        let encoded = try #require(CGImageSourceCreateWithURL(output.fileURL as CFURL, nil))
        #expect(output.fileURL.pathExtension == ext)
        #expect(CGImageSourceGetType(encoded) as String? == uti)
        #expect(output.kind == .image)
    }

    let outputs = try await executor.execute(
        TaskStep(operation: .batchConvertImages, source: .artifacts([source.id, source.id]),
                 arguments: .imageConvert(format: "jpg")), inputs: [source, source])
    #expect(outputs.count == 2)
    #expect(outputs.allSatisfy { $0.fileURL.pathExtension == "jpg" })
    #expect(outputs.allSatisfy { output in
        guard let encoded = CGImageSourceCreateWithURL(output.fileURL as CFURL, nil) else { return false }
        return CGImageSourceGetType(encoded) as String? == UTType.jpeg.identifier
    })
    #expect(try Data(contentsOf: sourceURL) == original)
}

@Test func convertResizesImagesAndCreatesThenMergesPDFCopies() async throws {
    let folder = try makeConvertTestFolder("KioConvertDocuments")
    defer { try? FileManager.default.removeItem(at: folder) }
    let urls = [folder.appendingPathComponent("first.png"), folder.appendingPathComponent("second.png"),
                folder.appendingPathComponent("third.png")]
    try makeConvertPNG(width: 80, height: 40).write(to: urls[0])
    try makeConvertPNG(width: 40, height: 80).write(to: urls[1])
    try makeConvertPNG(width: 48, height: 48).write(to: urls[2])
    let inputs = try urls.map { try ArtifactRef.inspect($0) }
    let executor = ToolExecutor()

    let resized = try #require(try await executor.execute(
        TaskStep(operation: .resizeImage, source: .artifacts([inputs[0].id]), arguments: .imageResize(width: 32)),
        inputs: [inputs[0]]).first)
    let resizedSource = try #require(CGImageSourceCreateWithURL(resized.fileURL as CFURL, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(resizedSource, 0, nil)) as NSDictionary
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 32)
    #expect(properties[kCGImagePropertyPixelHeight] as? Int == 16)

    let firstPDF = try #require(try await executor.execute(
        TaskStep(operation: .imagesToPDF, source: .artifacts([inputs[0].id, inputs[1].id])),
        inputs: Array(inputs.prefix(2))).first)
    let secondPDF = try #require(try await executor.execute(
        TaskStep(operation: .imagesToPDF, source: .artifacts([inputs[2].id])), inputs: [inputs[2]]).first)
    let merged = try #require(try await executor.execute(
        TaskStep(operation: .mergePDFs, source: .artifacts([firstPDF.id, secondPDF.id])),
        inputs: [firstPDF, secondPDF]).first)
    #expect(PDFDocument(url: firstPDF.fileURL)?.pageCount == 2)
    #expect(PDFDocument(url: secondPDF.fileURL)?.pageCount == 1)
    #expect(PDFDocument(url: merged.fileURL)?.pageCount == 3)
    #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
}

@Test func convertPDFCompressionProducesAnHonestSmallerCopy() async throws {
    let folder = try makeConvertTestFolder("KioConvertPDFCompression")
    defer { try? FileManager.default.removeItem(at: folder) }
    let sourceURL = folder.appendingPathComponent("large.pdf")
    let document = PDFDocument()
    let image = makeConvertNoiseImage(width: 1_600, height: 1_600)
    let page = try #require(PDFPage(image: NSImage(cgImage: image, size: NSSize(width: 540, height: 700))))
    document.insert(page, at: 0)
    #expect(document.write(to: sourceURL))
    let input = try ArtifactRef.inspect(sourceURL)
    let originalSize = input.sizeBytes
    let output = try #require(try await ToolExecutor().execute(
        TaskStep(operation: .compressPDF, source: .artifacts([input.id]), arguments: .pdfCompression(maxBytes: nil)),
        inputs: [input]).first)

    #expect(output.sizeBytes < originalSize)
    #expect(PDFDocument(url: output.fileURL)?.pageCount == 1)
    #expect(try ArtifactRef.inspect(sourceURL).sizeBytes == originalSize)
    #expect(output.verificationNote?.contains("original remains unchanged") == true)
}

@Test func convertExtractsMP3FromLocalVideoAndKeepsTheSource() async throws {
    guard let rootPath = ProcessInfo.processInfo.environment["KIO_REEL_RUNTIME_ROOT"] else {
        Issue.record("The broad check must prepare the pinned Reel runtime before running media conversion integration tests.")
        return
    }
    let runtimeRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
    let ffmpeg = try #require(ReelRuntime.url(for: "ffmpeg", in: runtimeRoot))
    let folder = try makeConvertTestFolder("KioConvertVideoAudio")
    defer { try? FileManager.default.removeItem(at: folder) }
    let videoURL = folder.appendingPathComponent("tone.mp4")
    try runConvertFixtureProcess(ffmpeg, ["-nostdin", "-hide_banner", "-v", "error", "-y",
        "-f", "lavfi", "-i", "color=c=blue:s=64x48:r=10:d=1",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-shortest",
        "-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac", "-f", "mp4", videoURL.path])
    let input = try ArtifactRef.inspect(videoURL)
    let original = try Data(contentsOf: videoURL)
    let output = try #require(try await ToolExecutor(mediaRuntimeRoot: runtimeRoot).execute(
        TaskStep(operation: .convertAudio, source: .artifacts([input.id]), arguments: .audioConvert(format: .mp3)),
        inputs: [input]).first)
    let probe = try await BundledMediaRuntime.probe(output.fileURL, runtimeRoot: runtimeRoot)

    #expect(output.fileURL.pathExtension == "mp3")
    #expect(probe.isCompatibleAudio(with: .mp3))
    #expect(!probe.hasVideo)
    #expect(try Data(contentsOf: videoURL) == original)
}

private func makeConvertTestFolder(_ name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func makeConvertPNG(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.systemBlue.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func makeConvertNoiseImage(width: Int, height: Int) -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    var state: UInt32 = 0x3141_5926
    for y in 0..<height {
        for x in 0..<width {
            let source = ((y / 3) * ((width + 2) / 3) + x / 3) * 4
            let target = (y * width + x) * 4
            if x % 3 == 0 && y % 3 == 0 {
                state ^= state << 13
                state ^= state >> 17
                state ^= state << 5
                bytes[target] = UInt8(truncatingIfNeeded: state)
                bytes[target + 1] = UInt8(truncatingIfNeeded: state >> 8)
                bytes[target + 2] = UInt8(truncatingIfNeeded: state >> 16)
            } else {
                bytes[target] = bytes[source]
                bytes[target + 1] = bytes[source + 1]
                bytes[target + 2] = bytes[source + 2]
            }
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private func runConvertFixtureProcess(_ executable: URL, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let detail = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw NSError(domain: "KioConvertFixture", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "The bundled fixture helper failed." : detail])
    }
}
