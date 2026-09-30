import AppKit
import AVFoundation
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

@Test func pdfSplitExtractRotateAndInspectVerifyCopies() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sourceURL = folder.appendingPathComponent("report.pdf")
    try makePDF(pageCount: 3).write(to: sourceURL)
    let source = try ArtifactRef.inspect(sourceURL)
    let executor = ToolExecutor()

    let split = try await executor.execute(TaskStep(operation: .splitPDF, source: .artifacts([source.id])), inputs: [source])
    let extracted = try await executor.execute(TaskStep(operation: .extractPDFPages, source: .artifacts([source.id]),
                                                        arguments: .removePages(indices: [1, 3])), inputs: [source])[0]
    let rotated = try await executor.execute(TaskStep(operation: .rotatePDFPages, source: .artifacts([source.id]),
                                                       arguments: .pdfRotation(indices: [2], degrees: 90)), inputs: [source])[0]
    let inspected = try await executor.execute(TaskStep(operation: .inspectPDF, source: .artifacts([source.id])), inputs: [source])[0]

    #expect(split.count == 3)
    #expect(split.allSatisfy { PDFDocument(url: $0.fileURL)?.pageCount == 1 })
    #expect(PDFDocument(url: extracted.fileURL)?.pageCount == 2)
    #expect(PDFDocument(url: rotated.fileURL)?.pageCount == 3)
    #expect(PDFDocument(url: rotated.fileURL)?.page(at: 1)?.rotation == 90)
    #expect(inspected.kind == .text)
    #expect(String(decoding: try Data(contentsOf: inspected.fileURL), as: UTF8.self).contains("Pages: 3"))
    #expect(FileManager.default.fileExists(atPath: sourceURL.path))
}

@Test func pdfReorderVerifiesFullUniquePageOrder() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sourceURL = folder.appendingPathComponent("report.pdf")
    let sourceDoc = try makePDF(pageCount: 3)
    sourceDoc.page(at: 0)?.rotation = 0
    sourceDoc.page(at: 1)?.rotation = 90
    sourceDoc.page(at: 2)?.rotation = 180
    #expect(sourceDoc.write(to: sourceURL))
    let source = try ArtifactRef.inspect(sourceURL)
    let executor = ToolExecutor()
    let step = TaskStep(operation: .reorderPDFPages, source: .artifacts([source.id]), arguments: .pageOrder(indices: [3, 1, 2]))
    let output = try await executor.execute(step, inputs: [source])[0]
    let reordered = try #require(PDFDocument(url: output.fileURL))

    #expect(reordered.pageCount == 3)
    #expect(reordered.page(at: 0)?.rotation == 180)
    #expect(reordered.page(at: 1)?.rotation == 0)
    #expect(reordered.page(at: 2)?.rotation == 90)
    await #expect(throws: (any Error).self) {
        try await executor.execute(TaskStep(operation: .reorderPDFPages, source: .artifacts([source.id]), arguments: .pageOrder(indices: [1, 1, 3])), inputs: [source])
    }
}

@Test func removeBlankPDFPagesKeepsVisibleContentAndReportsPages() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sourceURL = folder.appendingPathComponent("mixed.pdf")
    let document = PDFDocument()
    for image in [makeCGImage(width: 96, height: 96), makeWhiteCGImage(width: 96, height: 96), makeCGImage(width: 96, height: 96)] {
        document.insert(PDFPage(image: NSImage(cgImage: image, size: NSSize(width: 96, height: 96)))!, at: document.pageCount)
    }
    #expect(document.write(to: sourceURL))
    let source = try ArtifactRef.inspect(sourceURL)
    let output = try await ToolExecutor().execute(TaskStep(operation: .removeBlankPDFPages, source: .artifacts([source.id])), inputs: [source])[0]

    #expect(PDFDocument(url: output.fileURL)?.pageCount == 2)
    #expect(output.verificationNote?.contains("2") == true)
    #expect(PDFDocument(url: sourceURL)?.pageCount == 3)
}

@Test func scannedPDFOCRCreatesLocalTextArtifact() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sourceURL = folder.appendingPathComponent("scan.pdf")
    #expect(makeTextPDF("KIO OCR SAMPLE").write(to: sourceURL))
    let source = try ArtifactRef.inspect(sourceURL)
    let step = TaskStep(operation: .ocrPDFText, source: .artifacts([source.id]))

    let result = try await ToolExecutor().execute(step, inputs: [source])[0]
    let recognizedText = String(decoding: try Data(contentsOf: result.fileURL), as: UTF8.self)

    #expect(result.kind == .text)
    #expect(recognizedText.contains("Page 1"))
    #expect(recognizedText.localizedCaseInsensitiveContains("kio"))
    #expect(FileManager.default.fileExists(atPath: sourceURL.path))
}

@Test func rotatedImageWritesCorrectPNGDimensionsAndImageInspection() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sourceURL = folder.appendingPathComponent("photo.png")
    try makePNG(width: 90, height: 40).write(to: sourceURL)
    let source = try ArtifactRef.inspect(sourceURL)
    let executor = ToolExecutor()

    let rotated = try await executor.execute(TaskStep(operation: .rotateImage, source: .artifacts([source.id]),
                                                      arguments: .imageRotation(degrees: 90)), inputs: [source])[0]
    let info = try await executor.execute(TaskStep(operation: .inspectImage, source: .artifacts([source.id])), inputs: [source])[0]
    let imageSource = CGImageSourceCreateWithURL(rotated.fileURL as CFURL, nil)

    #expect(rotated.fileURL.pathExtension == "png")
    #expect(CGImageSourceCreateImageAtIndex(imageSource!, 0, nil)?.width == 40)
    #expect(CGImageSourceCreateImageAtIndex(imageSource!, 0, nil)?.height == 90)
    #expect(info.kind == .text)
    #expect(String(decoding: try Data(contentsOf: info.fileURL), as: UTF8.self).contains("90 × 40 pixels"))
    #expect(FileManager.default.fileExists(atPath: sourceURL.path))
}

@Test func imageCropCompressionAndContactSheetVerifyOutputAndPreserveInputs() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let firstURL = folder.appendingPathComponent("first.png")
    let secondURL = folder.appendingPathComponent("second.png")
    try makePNG(width: 90, height: 50).write(to: firstURL)
    let noise = makeNoiseCGImage(width: 720, height: 720)
    let noiseData = NSMutableData()
    let jpegWriter = CGImageDestinationCreateWithData(noiseData, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(jpegWriter, noise, nil)
    #expect(CGImageDestinationFinalize(jpegWriter))
    try (noiseData as Data).write(to: secondURL)
    let inputs = try [firstURL, secondURL].map { try ArtifactRef.inspect($0) }
    let executor = ToolExecutor()

    let crop = try await executor.execute(TaskStep(operation: .cropImage, source: .artifacts([inputs[0].id]),
                                                    arguments: .imageCrop(x: 10, y: 5, width: 40, height: 20)), inputs: [inputs[0]])[0]
    let cropSource = try #require(CGImageSourceCreateWithURL(crop.fileURL as CFURL, nil))
    let cropped = try #require(CGImageSourceCreateImageAtIndex(cropSource, 0, nil))
    let compressed = try await executor.execute(TaskStep(operation: .compressImage, source: .artifacts([inputs[1].id]),
                                                          arguments: .imageCompression(maxBytes: 1_000)), inputs: [inputs[1]])[0]
    let contact = try await executor.execute(TaskStep(operation: .imageContactSheet, source: .artifacts(inputs.map(\.id))), inputs: inputs)[0]
    let contactSource = try #require(CGImageSourceCreateWithURL(contact.fileURL as CFURL, nil))
    let sheet = try #require(CGImageSourceCreateImageAtIndex(contactSource, 0, nil))

    #expect(cropped.width == 40 && cropped.height == 20)
    #expect(compressed.fileURL.pathExtension == "jpg")
    #expect(compressed.sizeBytes < inputs[1].sizeBytes)
    #expect(compressed.verificationNote?.contains("did not reach") == true)
    #expect(sheet.width == 1_200 && sheet.height == 250)
    #expect(FileManager.default.fileExists(atPath: firstURL.path))
    #expect(FileManager.default.fileExists(atPath: secondURL.path))
}

@Test func imageMetadataRemovalCreatesCleanCopy() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sourceURL = folder.appendingPathComponent("private.jpg")
    let destination = CGImageDestinationCreateWithURL(sourceURL as CFURL, "public.jpeg" as CFString, 1, nil)!
    let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N"]
    CGImageDestinationAddImage(destination, makeCGImage(width: 64, height: 32), [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    let input = try ArtifactRef.inspect(sourceURL)
    let originalProps = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(sourceURL as CFURL, nil)!, 0, nil) as! [CFString: Any]
    #expect(originalProps[kCGImagePropertyGPSDictionary] != nil)

    let cleaned = try await ToolExecutor().execute(TaskStep(operation: .removeImageMetadata, source: .artifacts([input.id])), inputs: [input])[0]
    let cleanSource = try #require(CGImageSourceCreateWithURL(cleaned.fileURL as CFURL, nil))
    let cleanProps = CGImageSourceCopyPropertiesAtIndex(cleanSource, 0, nil) as! [CFString: Any]

    #expect(cleaned.fileURL.pathExtension == "jpg")
    #expect(cleanProps[kCGImagePropertyGPSDictionary] == nil)
    #expect(CGImageSourceCreateImageAtIndex(cleanSource, 0, nil)?.width == 64)
    #expect(FileManager.default.fileExists(atPath: sourceURL.path))
}

@Test func nativeVideoInspectionThumbnailTrimResizeAndTranscodeAreVerified() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sourceURL = folder.appendingPathComponent("clip.mov")
    try await makeTinyVideo(at: sourceURL)
    let source = try ArtifactRef.inspect(sourceURL)
    let executor = ToolExecutor()

    let info = try await executor.execute(TaskStep(operation: .inspectMedia, source: .artifacts([source.id])), inputs: [source])[0]
    let thumbnail = try await executor.execute(TaskStep(operation: .thumbnailVideo, source: .artifacts([source.id]),
                                                         arguments: .mediaThumbnail(timeMilliseconds: 500)), inputs: [source])[0]
    let trimmed = try await executor.execute(TaskStep(operation: .trimVideo, source: .artifacts([source.id]),
                                                       arguments: .mediaTrim(startMilliseconds: 250, durationMilliseconds: 500)), inputs: [source])[0]
    let resized = try await executor.execute(TaskStep(operation: .resizeVideo, source: .artifacts([source.id]),
                                                       arguments: .mediaResize(width: 640)), inputs: [source])[0]
    let transcoded = try await executor.execute(TaskStep(operation: .transcodeVideo, source: .artifacts([source.id])), inputs: [source])[0]
    let trimmedAsset = AVURLAsset(url: trimmed.fileURL)
    let resizedAsset = AVURLAsset(url: resized.fileURL)
    let thumbnailSource = try #require(CGImageSourceCreateWithURL(thumbnail.fileURL as CFURL, nil))

    #expect(info.kind == .text)
    #expect(String(decoding: try Data(contentsOf: info.fileURL), as: UTF8.self).contains("Duration:"))
    #expect(thumbnail.kind == .image)
    #expect((CGImageSourceCreateImageAtIndex(thumbnailSource, 0, nil)?.width ?? 0) > 0)
    #expect(abs(CMTimeGetSeconds(try await trimmedAsset.load(.duration)) - 0.5) < 0.25)
    #expect(try await resizedAsset.load(.tracks).contains(where: { $0.mediaType == .video }))
    #expect(transcoded.fileURL.pathExtension == "mp4")
    #expect(try await AVURLAsset(url: transcoded.fileURL).load(.tracks).contains(where: { $0.mediaType == .video }))
    #expect(FileManager.default.fileExists(atPath: sourceURL.path))
}

@Test func clerkCopiesMovesCreatesFoldersHashesDuplicatesAndOrganizesSafely() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("KioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceFolder = root.appendingPathComponent("Sources", isDirectory: true)
    let destinationFolder = root.appendingPathComponent("Destination", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
    let firstURL = sourceFolder.appendingPathComponent("report.txt")
    let secondDir = sourceFolder.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
    let secondURL = secondDir.appendingPathComponent("report.txt")
    try Data("same bytes".utf8).write(to: firstURL)
    try Data("same bytes".utf8).write(to: secondURL)
    let first = try ArtifactRef.inspect(firstURL)
    let second = try ArtifactRef.inspect(secondURL)
    let destination = try ArtifactRef.inspect(destinationFolder)
    let executor = ToolExecutor()

    let copies = try await executor.execute(TaskStep(operation: .copyFiles, source: .artifacts([first.id, second.id, destination.id])), inputs: [first, second, destination])
    #expect(copies.map(\.displayName) == ["report.txt", "report-2.txt"])
    #expect(try Data(contentsOf: copies[1].fileURL) == Data("same bytes".utf8))
    #expect(FileManager.default.fileExists(atPath: firstURL.path) && FileManager.default.fileExists(atPath: secondURL.path))

    let duplicateReport = try await executor.execute(TaskStep(operation: .findDuplicates, source: .artifacts([first.id, second.id])), inputs: [first, second])[0]
    #expect(String(decoding: try Data(contentsOf: duplicateReport.fileURL), as: UTF8.self).contains("Duplicate groups: 1"))

    let newFolder = try await executor.execute(TaskStep(operation: .createFolder, source: .artifacts([destination.id]),
                                                         arguments: .folderName(name: "Projects")), inputs: [destination])[0]
    let secondFolder = try await executor.execute(TaskStep(operation: .createFolder, source: .artifacts([destination.id]),
                                                           arguments: .folderName(name: "Projects")), inputs: [destination])[0]
    #expect(newFolder.kind == .folder)
    #expect(secondFolder.displayName == "Projects-2")

    let movingURL = sourceFolder.appendingPathComponent("move.txt")
    try Data("move me".utf8).write(to: movingURL)
    let moving = try ArtifactRef.inspect(movingURL)
    let moved = try await executor.execute(TaskStep(operation: .moveFiles, source: .artifacts([moving.id, destination.id])), inputs: [moving, destination])[0]
    #expect(!FileManager.default.fileExists(atPath: movingURL.path))
    #expect(try Data(contentsOf: moved.fileURL) == Data("move me".utf8))

    let pdfURL = sourceFolder.appendingPathComponent("slides.pdf")
    let imageURL = sourceFolder.appendingPathComponent("photo.png")
    try Data("PDF fixture".utf8).write(to: pdfURL)
    try makePNG(width: 30, height: 20).write(to: imageURL)
    let typedInputs = try [pdfURL, imageURL].map { try ArtifactRef.inspect($0) }
    let byType = try await executor.execute(TaskStep(operation: .organizeByType, source: .artifacts(typedInputs.map(\.id))), inputs: typedInputs)[0]
    #expect(FileManager.default.fileExists(atPath: byType.fileURL.appendingPathComponent("PDFs/slides.pdf").path))
    #expect(FileManager.default.fileExists(atPath: byType.fileURL.appendingPathComponent("Images/photo.png").path))

    let date = Calendar.current.date(from: DateComponents(year: 2025, month: 3, day: 14))!
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: pdfURL.path)
    let datedInput = try ArtifactRef.inspect(pdfURL)
    let byDate = try await executor.execute(TaskStep(operation: .organizeByDate, source: .artifacts([datedInput.id])), inputs: [datedInput])[0]
    #expect(FileManager.default.fileExists(atPath: byDate.fileURL.appendingPathComponent("2025-03/slides.pdf").path))
    #expect(FileManager.default.fileExists(atPath: pdfURL.path))
}

@Test func archiveInspectionListsEntriesWithoutExtractingThem() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sourceURL = folder.appendingPathComponent("notes.txt")
    try Data("safe archive fixture".utf8).write(to: sourceURL)
    let source = try ArtifactRef.inspect(sourceURL)
    let archive = try await ToolExecutor().execute(TaskStep(operation: .createArchive, source: .artifacts([source.id])), inputs: [source])[0]
    let info = try await ToolExecutor().execute(TaskStep(operation: .inspectArchive, source: .artifacts([archive.id])), inputs: [archive])[0]

    #expect(info.kind == .text)
    #expect(String(decoding: try Data(contentsOf: info.fileURL), as: UTF8.self).contains("notes.txt"))
    #expect(FileManager.default.fileExists(atPath: sourceURL.path))
}

@Test func zipExtractionWritesVerifiedFilesUnderANewFolder() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sourceURL = folder.appendingPathComponent("notes.txt")
    let sourceData = Data("safe archive extraction".utf8)
    try sourceData.write(to: sourceURL)
    let source = try ArtifactRef.inspect(sourceURL)
    let archive = try await ToolExecutor().execute(TaskStep(operation: .createArchive, source: .artifacts([source.id])), inputs: [source])[0]

    let output = try await ToolExecutor().execute(TaskStep(operation: .extractZip, source: .artifacts([archive.id])), inputs: [archive])[0]

    #expect(output.kind == .folder)
    #expect(output.fileURL.lastPathComponent == "notes-Archive-Extracted")
    #expect(try Data(contentsOf: output.fileURL.appendingPathComponent("notes.txt")) == sourceData)
    #expect(try Data(contentsOf: sourceURL) == sourceData)
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes-Extracted").path))
}

@Test func zipExtractionRejectsTraversalAndUnixSymlinksBeforeWriting() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let traversalURL = folder.appendingPathComponent("traversal.zip")
    try makeStoredZip(path: "../escaped.txt", payload: Data("bad".utf8)).write(to: traversalURL)
    let traversal = try ArtifactRef.inspect(traversalURL)
    await #expect(throws: (any Error).self) {
        try await ToolExecutor().execute(TaskStep(operation: .extractZip, source: .artifacts([traversal.id])), inputs: [traversal])
    }
    #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent("escaped.txt").path))

    let symlinkURL = folder.appendingPathComponent("symlink.zip")
    try makeStoredZip(path: "escape-link", payload: Data("../../escaped.txt".utf8), unixMode: 0o120777).write(to: symlinkURL)
    let symlink = try ArtifactRef.inspect(symlinkURL)
    await #expect(throws: (any Error).self) {
        try await ToolExecutor().execute(TaskStep(operation: .extractZip, source: .artifacts([symlink.id])), inputs: [symlink])
    }
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("symlink-Extracted").path))
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

private func makeTinyVideo(at url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let writerBox = AssetWriterBox(writer)
    let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 320,
        kCVPixelBufferHeightKey as String: 240,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
    #expect(writer.canAdd(input))
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<30 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        guard let pool = adaptor.pixelBufferPool else { throw KioFailure.processing("The video fixture has no pixel-buffer pool.") }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw KioFailure.processing("The video fixture frame couldn't be allocated.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<240 {
                for x in 0..<320 {
                    let offset = y * rowBytes + x * 4
                    bytes[offset] = UInt8((x + frame * 3) % 256)
                    bytes[offset + 1] = UInt8((y + frame * 5) % 256)
                    bytes[offset + 2] = 180
                    bytes[offset + 3] = 255
                }
            }
        }
        let appended = adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard appended else { throw writer.error ?? KioFailure.processing("A video fixture frame couldn't be written.") }
    }
    input.markAsFinished()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        writerBox.value.finishWriting {
            if writerBox.value.status == .completed { continuation.resume() }
            else { continuation.resume(throwing: writerBox.value.error ?? KioFailure.processing("The video fixture couldn't be finalized.")) }
        }
    }
}

private final class AssetWriterBox: @unchecked Sendable {
    let value: AVAssetWriter

    init(_ value: AVAssetWriter) {
        self.value = value
    }
}

private func makeTextPDF(_ text: String) -> PDFDocument {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1_200, pixelsHigh: 240,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 1_200, height: 240).fill()
    (text as NSString).draw(at: NSPoint(x: 40, y: 70), withAttributes: [.font: NSFont.systemFont(ofSize: 100), .foregroundColor: NSColor.black])
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: NSSize(width: 1_200, height: 240))
    image.addRepresentation(bitmap)
    let document = PDFDocument()
    document.insert(PDFPage(image: image)!, at: 0)
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

private func makeWhiteCGImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.white.cgColor)
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

private func makeStoredZip(path: String, payload: Data, unixMode: UInt16 = 0o100644) -> Data {
    let name = Data(path.utf8)
    let checksum = testCRC32(payload)
    var data = Data()
    data.appendLE(UInt32(0x04034b50)); data.appendLE(UInt16(20)); data.appendLE(UInt16(0x0800)); data.appendLE(UInt16(0))
    data.appendLE(UInt16(0)); data.appendLE(UInt16(0x0021)); data.appendLE(checksum)
    data.appendLE(UInt32(payload.count)); data.appendLE(UInt32(payload.count)); data.appendLE(UInt16(name.count)); data.appendLE(UInt16(0))
    data.append(name); data.append(payload)
    let centralOffset = UInt32(data.count)
    data.appendLE(UInt32(0x02014b50)); data.appendLE(UInt16(0x0314)); data.appendLE(UInt16(20)); data.appendLE(UInt16(0x0800)); data.appendLE(UInt16(0))
    data.appendLE(UInt16(0)); data.appendLE(UInt16(0x0021)); data.appendLE(checksum)
    data.appendLE(UInt32(payload.count)); data.appendLE(UInt32(payload.count)); data.appendLE(UInt16(name.count))
    data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0))
    data.appendLE(UInt32(unixMode) << 16); data.appendLE(UInt32(0)); data.append(name)
    let centralSize = UInt32(data.count) - centralOffset
    data.appendLE(UInt32(0x06054b50)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(UInt16(1)); data.appendLE(UInt16(1))
    data.appendLE(centralSize); data.appendLE(centralOffset); data.appendLE(UInt16(0))
    return data
}

private func testCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
    }
    return crc ^ 0xffff_ffff
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
