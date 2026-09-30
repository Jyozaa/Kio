import AVFoundation
import AppKit
import CZlib
import CoreText
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision
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
        case .removeBlankPDFPages:
            guard inputs.count == 1, let input = inputs.first, input.kind == .pdf else { throw KioFailure.invalidInput("Choose one PDF to remove blank pages from.") }
            return [try removeBlankPDFPages(input)]
        case .splitPDF:
            guard inputs.count == 1, let input = inputs.first, input.kind == .pdf else { throw KioFailure.invalidInput("Choose one PDF to split into one-page files.") }
            return try splitPDF(input)
        case .extractPDFPages:
            guard inputs.count == 1, let input = inputs.first, input.kind == .pdf,
                  case .removePages(let indices) = step.arguments else { throw KioFailure.invalidInput("Choose one PDF and the pages to extract.") }
            return [try extractPDFPages(input, indices: indices)]
        case .reorderPDFPages:
            guard inputs.count == 1, let input = inputs.first, input.kind == .pdf,
                  case .pageOrder(let indices) = step.arguments else { throw KioFailure.invalidInput("Choose one PDF and a complete page order.") }
            return [try reorderPDFPages(input, indices: indices)]
        case .rotatePDFPages:
            guard inputs.count == 1, let input = inputs.first, input.kind == .pdf,
                  case .pdfRotation(let indices, let degrees) = step.arguments else { throw KioFailure.invalidInput("Choose one PDF and a rotation angle.") }
            return [try rotatePDFPages(input, indices: indices, degrees: degrees)]
        case .extractPDFText:
            guard inputs.count == 1, let input = inputs.first, input.kind == .pdf else { throw KioFailure.invalidInput("Choose one PDF to extract text from.") }
            return [try extractPDFText(input)]
        case .ocrPDFText:
            guard inputs.count == 1, let input = inputs.first, input.kind == .pdf else { throw KioFailure.invalidInput("Choose one PDF to read with OCR.") }
            return [try ocrPDFText(input)]
        case .inspectPDF:
            guard inputs.count == 1, let input = inputs.first, input.kind == .pdf else { throw KioFailure.invalidInput("Choose one PDF to inspect.") }
            return [try inspectPDF(input)]
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
        case .rotateImage:
            guard inputs.count == 1, let input = inputs.first, input.kind == .image,
                  case .imageRotation(let degrees) = step.arguments, [90, 180, 270].contains(degrees) else {
                throw KioFailure.invalidInput("Choose one image and a rotation angle of 90, 180, or 270 degrees.")
            }
            return [try rotateImage(input, degrees: degrees)]
        case .inspectImage:
            guard inputs.count == 1, let input = inputs.first, input.kind == .image else { throw KioFailure.invalidInput("Choose one image to inspect.") }
            return [try inspectImage(input)]
        case .cropImage:
            guard inputs.count == 1, let input = inputs.first, input.kind == .image,
                  case .imageCrop(let x, let y, let width, let height) = step.arguments else {
                throw KioFailure.invalidInput("Choose one image and valid crop coordinates.")
            }
            return [try cropImage(input, x: x, y: y, width: width, height: height)]
        case .compressImage:
            guard inputs.count == 1, let input = inputs.first, input.kind == .image,
                  case .imageCompression(let maxBytes) = step.arguments else { throw KioFailure.invalidInput("Choose one image to compress.") }
            return [try compressImage(input, maxBytes: maxBytes)]
        case .removeImageMetadata:
            guard inputs.count == 1, let input = inputs.first, input.kind == .image else { throw KioFailure.invalidInput("Choose one image to remove metadata from.") }
            return [try removeImageMetadata(input)]
        case .imageContactSheet:
            guard inputs.count >= 2, inputs.count <= 36, inputs.allSatisfy({ $0.kind == .image }) else {
                throw KioFailure.invalidInput("Choose between 2 and 36 images for a contact sheet.")
            }
            return [try imageContactSheet(inputs)]
        case .renameFile:
            guard let input = inputs.first, inputs.count == 1,
                  case .exactRename(let name) = step.arguments, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KioFailure.invalidInput("Choose one file and a valid new name.")
            }
            return [try exactRename(input, requestedName: name)]
        case .batchRename:
            guard case .rename(let prefix) = step.arguments, !prefix.isEmpty, prefix.count <= 64 else {
                throw KioFailure.invalidInput("Choose a short name prefix for the copies.")
            }
            return try batchRename(inputs, prefix: prefix)
        case .copyFiles:
            let (files, destination) = try fileSourcesAndDestination(inputs, action: "copy")
            return try copyFiles(files, to: destination)
        case .moveFiles:
            let (files, destination) = try fileSourcesAndDestination(inputs, action: "move")
            return try moveFiles(files, to: destination)
        case .createFolder:
            guard inputs.count == 1, let parent = inputs.first, parent.kind == .folder,
                  case .folderName(let name) = step.arguments else { throw KioFailure.invalidInput("Choose one destination folder and a new folder name.") }
            return [try createFolder(named: name, inside: parent)]
        case .findDuplicates:
            return [try findDuplicates(inputs)]
        case .organizeByType:
            return [try organizeFiles(inputs, byDate: false)]
        case .organizeByDate:
            return [try organizeFiles(inputs, byDate: true)]
        case .createArchive:
            return [try createZip(inputs)]
        case .inspectArchive:
            guard inputs.count == 1, let input = inputs.first, input.kind == .other, input.fileURL.pathExtension.lowercased() == "zip" else {
                throw KioFailure.invalidInput("Choose one ZIP file to inspect.")
            }
            return [try inspectArchive(input)]
        case .extractZip:
            guard inputs.count == 1, let input = inputs.first, input.kind == .other,
                  input.fileURL.pathExtension.lowercased() == "zip" else {
                throw KioFailure.invalidInput("Choose one ZIP file to extract.")
            }
            return [try SafeZipExtractor.extract(input)]
        case .compressPDF:
            guard let input = inputs.first, input.kind == .pdf,
                  case .pdfCompression(let maxBytes) = step.arguments else {
                throw KioFailure.invalidInput("Choose a PDF to compress.")
            }
            return [try compressPDF(input, maxBytes: maxBytes)]
        case .extractAudio:
            guard let input = inputs.first, input.kind == .video else { throw KioFailure.invalidInput("Add a video to extract its audio.") }
            return [try await extractAudio(input)]
        case .inspectMedia:
            guard inputs.count == 1, let input = inputs.first, input.kind == .video else { throw KioFailure.invalidInput("Choose one video to inspect.") }
            return [try await inspectMedia(input)]
        case .thumbnailVideo:
            guard inputs.count == 1, let input = inputs.first, input.kind == .video,
                  case .mediaThumbnail(let time) = step.arguments else { throw KioFailure.invalidInput("Choose one video and a thumbnail time.") }
            return [try await thumbnailVideo(input, timeMilliseconds: time)]
        case .trimVideo:
            guard inputs.count == 1, let input = inputs.first, input.kind == .video,
                  case .mediaTrim(let start, let duration) = step.arguments else { throw KioFailure.invalidInput("Choose one video and a trim range.") }
            return [try await trimVideo(input, startMilliseconds: start, durationMilliseconds: duration)]
        case .resizeVideo:
            guard inputs.count == 1, let input = inputs.first, input.kind == .video,
                  case .mediaResize(let width) = step.arguments else { throw KioFailure.invalidInput("Choose one video and a supported output width.") }
            return [try await resizeVideo(input, width: width)]
        case .transcodeVideo:
            guard inputs.count == 1, let input = inputs.first, input.kind == .video else { throw KioFailure.invalidInput("Choose one video to transcode.") }
            return [try await transcodeVideo(input)]
        case .compressVideo:
            guard inputs.count == 1, let input = inputs.first, input.kind == .video,
                  case .mediaCompression(let maxBytes) = step.arguments else { throw KioFailure.invalidInput("Choose one video to compress.") }
            return [try await compressVideo(input, maxBytes: maxBytes)]
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

    private func removeBlankPDFPages(_ input: ArtifactRef) throws -> ArtifactRef {
        guard let document = PDFDocument(url: input.fileURL), (1...300).contains(document.pageCount) else {
            throw KioFailure.invalidInput("Choose a readable PDF with 1 to 300 pages.")
        }
        var blankPages: [Int] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw KioFailure.processing("PDF page \(index + 1) could not be read.") }
            if try isVisuallyBlank(page) { blankPages.append(index + 1) }
        }
        guard blankPages.count < document.pageCount else {
            throw KioFailure.invalidInput("Kio found only blank pages and kept the original unchanged. Select a PDF with at least one nonblank page.")
        }
        let output = try OutputLocation.makeURL(for: [input], baseName: Self.base(input.displayName) + "-No-Blank-Pages", fileExtension: "pdf")
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for index in blankPages.sorted(by: >) { document.removePage(at: index - 1) }
        let expectedPageCount = document.pageCount
        guard document.write(to: temporary), let verified = PDFDocument(url: temporary),
              verified.pageCount == expectedPageCount else {
            throw KioFailure.verification("The blank-page removal output could not be verified.")
        }
        try OutputLocation.commit(temporary, to: output)
        let note = blankPages.isEmpty ? "No visually blank pages were found. The original remains unchanged." : "Removed visually blank page(s): \(blankPages.map(String.init).joined(separator: ", ")). The original remains unchanged."
        return try ArtifactRef.inspect(output, parentID: input.id).withVerificationNote(note)
    }

    private func reorderPDFPages(_ input: ArtifactRef, indices: [Int]) throws -> ArtifactRef {
        guard let source = PDFDocument(url: input.fileURL), (1...300).contains(source.pageCount),
              indices.count == source.pageCount, Set(indices) == Set(1...source.pageCount) else {
            throw KioFailure.invalidInput("Reordering must list every page number exactly once, from 1 through the last page.")
        }
        let result = PDFDocument()
        for pageNumber in indices {
            guard let page = source.page(at: pageNumber - 1) else { throw KioFailure.processing("PDF page \(pageNumber) could not be read.") }
            result.insert(page, at: result.pageCount)
        }
        let output = try OutputLocation.makeURL(for: [input], baseName: Self.base(input.displayName) + "-Reordered", fileExtension: "pdf")
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard result.pageCount == source.pageCount, result.write(to: temporary),
              let verified = PDFDocument(url: temporary), verified.pageCount == source.pageCount,
              zip(indices, 0..<indices.count).allSatisfy({ verified.page(at: $0.1)?.rotation == source.page(at: $0.0 - 1)?.rotation }) else {
            throw KioFailure.verification("The reordered PDF pages could not be verified.")
        }
        try OutputLocation.commit(temporary, to: output)
        return try ArtifactRef.inspect(output, parentID: input.id)
    }

    private func isVisuallyBlank(_ page: PDFPage) throws -> Bool {
        if !(page.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { return false }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return true }
        let scale = min(1, 144 / max(bounds.width, bounds.height))
        let thumbnail = page.thumbnail(of: CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale)), for: .mediaBox)
        var proposed = CGRect(origin: .zero, size: thumbnail.size)
        guard let image = thumbnail.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 96 * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw KioFailure.processing("A PDF page could not be checked for blank content.")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        let fitScale = min(88 / CGFloat(image.width), 88 / CGFloat(image.height))
        let width = CGFloat(image.width) * fitScale
        let height = CGFloat(image.height) * fitScale
        context.draw(image, in: CGRect(x: (96 - width) / 2, y: (96 - height) / 2, width: width, height: height))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        var nonWhitePixels = 0
        for pixel in 0..<(96 * 96) {
            let offset = pixel * 4
            if bytes[offset] < 236 || bytes[offset + 1] < 236 || bytes[offset + 2] < 236 { nonWhitePixels += 1 }
            if nonWhitePixels > 2 { return false }
        }
        return true
    }

    private func splitPDF(_ input: ArtifactRef) throws -> [ArtifactRef] {
        guard let source = PDFDocument(url: input.fileURL), (1...300).contains(source.pageCount) else {
            throw KioFailure.invalidInput("This PDF could not be opened or has more than 300 pages to split safely.")
        }
        var outputs: [ArtifactRef] = []
        do {
            for pageIndex in 0..<source.pageCount {
                try Task.checkCancellation()
                guard let page = source.page(at: pageIndex) else { throw KioFailure.processing("PDF page \(pageIndex + 1) could not be read.") }
                let output = try OutputLocation.makeURL(for: [input],
                    baseName: "\(Self.base(input.displayName))-Page-\(String(format: "%03d", pageIndex + 1))", fileExtension: "pdf")
                let temporary = OutputLocation.temporaryURL(beside: output)
                defer { try? FileManager.default.removeItem(at: temporary) }
                let document = PDFDocument()
                document.insert(page, at: 0)
                guard document.write(to: temporary), let check = PDFDocument(url: temporary), check.pageCount == 1 else {
                    throw KioFailure.verification("Split PDF page \(pageIndex + 1) could not be verified.")
                }
                try OutputLocation.commit(temporary, to: output)
                outputs.append(try ArtifactRef.inspect(output, parentID: input.id))
            }
            return outputs
        } catch {
            outputs.forEach { try? FileManager.default.removeItem(at: $0.fileURL) }
            throw error
        }
    }

    private func extractPDFPages(_ input: ArtifactRef, indices: [Int]) throws -> ArtifactRef {
        guard let source = PDFDocument(url: input.fileURL), source.pageCount > 0 else { throw KioFailure.invalidInput("This PDF could not be opened.") }
        let pages = Array(Set(indices)).sorted()
        guard !pages.isEmpty, pages.count <= 200, pages.allSatisfy({ (1...source.pageCount).contains($0) }) else {
            throw KioFailure.invalidInput("Choose up to 200 page numbers that exist in this PDF.")
        }
        let result = PDFDocument()
        for pageNumber in pages {
            guard let page = source.page(at: pageNumber - 1) else { throw KioFailure.processing("PDF page \(pageNumber) could not be read.") }
            result.insert(page, at: result.pageCount)
        }
        let output = try OutputLocation.makeURL(for: [input], baseName: Self.base(input.displayName) + "-Pages", fileExtension: "pdf")
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard result.write(to: temporary), let check = PDFDocument(url: temporary), check.pageCount == pages.count else {
            throw KioFailure.verification("The extracted PDF pages could not be verified.")
        }
        try OutputLocation.commit(temporary, to: output)
        return try ArtifactRef.inspect(output, parentID: input.id)
    }

    private func rotatePDFPages(_ input: ArtifactRef, indices: [Int], degrees: Int) throws -> ArtifactRef {
        guard [90, 180, 270].contains(degrees), let document = PDFDocument(url: input.fileURL), document.pageCount > 0 else {
            throw KioFailure.invalidInput("Choose a readable PDF and a rotation angle of 90, 180, or 270 degrees.")
        }
        let pageNumbers = indices.isEmpty ? Array(1...document.pageCount) : Array(Set(indices)).sorted()
        guard pageNumbers.count <= 200, pageNumbers.allSatisfy({ (1...document.pageCount).contains($0) }) else {
            throw KioFailure.invalidInput("One or more selected page numbers aren't in this PDF.")
        }
        for pageNumber in pageNumbers {
            guard let page = document.page(at: pageNumber - 1) else { throw KioFailure.processing("PDF page \(pageNumber) could not be read.") }
            page.rotation = (page.rotation + degrees) % 360
        }
        let output = try OutputLocation.makeURL(for: [input], baseName: Self.base(input.displayName) + "-Rotated", fileExtension: "pdf")
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard document.write(to: temporary), let check = PDFDocument(url: temporary), check.pageCount == document.pageCount,
              pageNumbers.allSatisfy({ check.page(at: $0 - 1)?.rotation == document.page(at: $0 - 1)?.rotation }) else {
            throw KioFailure.verification("The rotated PDF pages could not be verified.")
        }
        try OutputLocation.commit(temporary, to: output)
        return try ArtifactRef.inspect(output, parentID: input.id)
    }

    private func extractPDFText(_ input: ArtifactRef) throws -> ArtifactRef {
        guard let document = PDFDocument(url: input.fileURL), document.pageCount > 0 else { throw KioFailure.invalidInput("This PDF could not be opened.") }
        let pages = (0..<document.pageCount).compactMap { index -> String? in
            guard let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return "--- Page \(index + 1) ---\n\(text)"
        }
        guard !pages.isEmpty else { throw KioFailure.unsupported("This PDF has no selectable text. Scanned-page OCR isn't available in this workflow.") }
        return try writeTextArtifact(input, suffix: "-Text", text: pages.joined(separator: "\n\n"))
    }

    private func ocrPDFText(_ input: ArtifactRef) throws -> ArtifactRef {
        guard let document = PDFDocument(url: input.fileURL), document.pageCount > 0 else { throw KioFailure.invalidInput("This PDF could not be opened.") }
        guard document.pageCount <= 50 else { throw KioFailure.unsupported("Kio's on-device OCR is limited to 50 pages at a time. Split the PDF and retry a smaller section.") }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw KioFailure.processing("PDF page \(index + 1) could not be read.") }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let scale = min(1, 2_400 / max(bounds.width, bounds.height))
            let thumbnail = page.thumbnail(of: CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale)), for: .mediaBox)
            var proposed = CGRect(origin: .zero, size: thumbnail.size)
            guard let image = thumbnail.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
                throw KioFailure.processing("PDF page \(index + 1) could not be rendered for OCR.")
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !recognized.isEmpty { pages.append("--- Page \(index + 1) ---\n\(recognized)") }
            guard pages.joined(separator: "\n\n").utf8.count <= 2_000_000 else {
                throw KioFailure.unsupported("The OCR text exceeded Kio's safe 2 MB result limit.")
            }
        }
        guard !pages.isEmpty else { throw KioFailure.unsupported("Kio couldn't recognize readable text in this scanned PDF.") }
        return try writeTextArtifact(input, suffix: "-OCR", text: pages.joined(separator: "\n\n"))
    }

    private func inspectPDF(_ input: ArtifactRef) throws -> ArtifactRef {
        guard let document = PDFDocument(url: input.fileURL), document.pageCount > 0 else { throw KioFailure.invalidInput("This PDF could not be opened.") }
        let pageSizes = (0..<min(document.pageCount, 5)).compactMap { index -> String? in
            guard let page = document.page(at: index) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            return "Page \(index + 1): \(Int(bounds.width.rounded())) × \(Int(bounds.height.rounded())) points"
        }
        let summary = [
            "PDF: \(input.displayName)",
            "Pages: \(document.pageCount)",
            "File size: \(ByteCountFormatter.string(fromByteCount: input.sizeBytes, countStyle: .file))",
            "Page sizes:", pageSizes.joined(separator: "\n")
        ].joined(separator: "\n")
        return try writeTextArtifact(input, suffix: "-Info", text: summary)
    }

    private func writeTextArtifact(_ input: ArtifactRef, suffix: String, text: String) throws -> ArtifactRef {
        let output = try OutputLocation.makeURL(for: [input], baseName: Self.base(input.displayName) + suffix, fileExtension: "txt")
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let data = Data(text.utf8)
        guard !data.isEmpty else { throw KioFailure.verification("The text result was empty.") }
        try data.write(to: temporary, options: .atomic)
        guard (try Data(contentsOf: temporary)) == data else { throw KioFailure.verification("The text result could not be verified.") }
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
        let output = try OutputLocation.makeURL(for: [input], baseName: Self.base(input.displayName) + "-Resized", fileExtension: "png")
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

    private func rotateImage(_ input: ArtifactRef, degrees: Int) throws -> ArtifactRef {
        guard [90, 180, 270].contains(degrees),
              let source = CGImageSourceCreateWithURL(input.fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw KioFailure.invalidInput("This image couldn't be opened for rotation.")
        }
        let swapsAxes = degrees == 90 || degrees == 270
        let width = swapsAxes ? image.height : image.width
        let height = swapsAxes ? image.width : image.height
        let output = try OutputLocation.makeURL(for: [input], baseName: Self.base(input.displayName) + "-Rotated", fileExtension: "png")
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = CGImageDestinationCreateWithURL(temporary as CFURL, Self.imageUTI(for: "png"), 1, nil) else {
            throw KioFailure.processing("Kio couldn't prepare the rotated image.")
        }
        context.interpolationQuality = .high
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: CGFloat(degrees) * .pi / 180)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let rotated = context.makeImage() else { throw KioFailure.processing("Kio couldn't render the rotated image.") }
        CGImageDestinationAddImage(destination, rotated, nil)
        guard CGImageDestinationFinalize(destination),
              let check = CGImageSourceCreateWithURL(temporary as CFURL, nil),
              let verified = CGImageSourceCreateImageAtIndex(check, 0, nil), verified.width == width, verified.height == height else {
            throw KioFailure.verification("The rotated image dimensions could not be verified.")
        }
        try OutputLocation.commit(temporary, to: output)
        return try ArtifactRef.inspect(output, parentID: input.id)
    }

    private func inspectImage(_ input: ArtifactRef) throws -> ArtifactRef {
        guard let source = CGImageSourceCreateWithURL(input.fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw KioFailure.invalidInput("This image could not be opened.") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let format = CGImageSourceGetType(source) as String? ?? input.fileURL.pathExtension.uppercased()
        let metadataKeys = properties.keys.map { String(describing: $0) }.sorted()
        let summary = [
            "Image: \(input.displayName)",
            "Format: \(format)",
            "Dimensions: \(image.width) × \(image.height) pixels",
            "File size: \(ByteCountFormatter.string(fromByteCount: input.sizeBytes, countStyle: .file))",
            "Metadata fields: \(metadataKeys.isEmpty ? "none" : metadataKeys.joined(separator: ", "))"
        ].joined(separator: "\n")
        return try writeTextArtifact(input, suffix: "-Info", text: summary)
    }

    private func cropImage(_ input: ArtifactRef, x: Int, y: Int, width: Int, height: Int) throws -> ArtifactRef {
        let image = try decodedStaticImage(input, maximumPixel: 20_000)
        guard x >= 0, y >= 0, width > 0, height > 0,
              x <= image.width, y <= image.height,
              width <= image.width - x, height <= image.height - y,
              let cropped = image.cropping(to: CGRect(x: x, y: y, width: width, height: height)) else {
            throw KioFailure.invalidInput("Those crop coordinates extend beyond the image. Use pixel coordinates within its dimensions.")
        }
        let output = try OutputLocation.makeURL(for: [input], baseName: Self.base(input.displayName) + "-Cropped", fileExtension: "png")
        return try writePNG(cropped, output: output, parentID: input.id, note: nil)
    }

    private func compressImage(_ input: ArtifactRef, maxBytes: Int64?) throws -> ArtifactRef {
        if let maxBytes, !(1...1_000_000_000).contains(maxBytes) { throw KioFailure.invalidInput("Choose an image size target between 1 byte and 1 GB.") }
        let image = try decodedStaticImage(input, maximumPixel: 20_000)
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: break
        default: throw KioFailure.unsupported("This image has transparency. Kio won't flatten it just to make a JPEG smaller.")
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("KioImageCompression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let qualities: [CGFloat] = [0.9, 0.78, 0.66, 0.54, 0.42, 0.30]
        var best: (url: URL, size: Int64)?
        var reachedTarget = false
        for (index, quality) in qualities.enumerated() {
            try Task.checkCancellation()
            let candidate = staging.appendingPathComponent("candidate-\(index).jpg")
            guard let destination = CGImageDestinationCreateWithURL(candidate as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw KioFailure.processing("Kio couldn't prepare the compressed image copy.")
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination), let check = CGImageSourceCreateWithURL(candidate as CFURL, nil),
                  CGImageSourceCreateImageAtIndex(check, 0, nil) != nil else { throw KioFailure.verification("The compressed image copy could not be verified.") }
            let size = Int64(try candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            if best == nil || size < best!.size { best = (candidate, size) }
            if let maxBytes, size <= maxBytes { best = (candidate, size); reachedTarget = true; break }
            if maxBytes == nil, size < Int64(Double(input.sizeBytes) * 0.97) { best = (candidate, size); break }
        }
        guard let best, best.size > 0, best.size < input.sizeBytes else {
            throw KioFailure.processing("This image did not get smaller without more aggressive quality loss.")
        }
        let output = try OutputLocation.makeURL(for: [input], baseName: Self.base(input.displayName) + "-Compressed", fileExtension: "jpg")
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: best.url, to: temporary)
        try OutputLocation.commit(temporary, to: output)
        let note: String
        if let maxBytes, !reachedTarget {
            note = "This JPEG copy is smaller at \(ByteCountFormatter.string(fromByteCount: best.size, countStyle: .file)), but it did not reach the requested \(ByteCountFormatter.string(fromByteCount: maxBytes, countStyle: .file)). The original remains unchanged."
        } else {
            note = "Created a smaller JPEG copy. The original remains unchanged."
        }
        return try ArtifactRef.inspect(output, parentID: input.id).withVerificationNote(note)
    }

    private func removeImageMetadata(_ input: ArtifactRef) throws -> ArtifactRef {
        guard let source = CGImageSourceCreateWithURL(input.fileURL as CFURL, nil), CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?,
              let outputImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 20_000
              ] as CFDictionary) else {
            throw KioFailure.unsupported("Kio can remove metadata from one readable, static image at a time.")
        }
        let sourceExtension = input.fileURL.pathExtension.lowercased()
        let ext = UTType(filenameExtension: sourceExtension)?.identifier == type
            ? sourceExtension
            : (UTType(type)?.preferredFilenameExtension ?? sourceExtension)
        guard !ext.isEmpty else { throw KioFailure.unsupported("Kio doesn't know a safe file extension for this image format.") }
        let output = try OutputLocation.makeURL(for: [input], baseName: Self.base(input.displayName) + "-Cleaned", fileExtension: ext)
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type as CFString, 1, nil) else {
            throw KioFailure.processing("Kio couldn't prepare a metadata-free image.")
        }
        CGImageDestinationAddImage(destination, outputImage, nil)
        guard CGImageDestinationFinalize(destination),
              let verifiedSource = CGImageSourceCreateWithURL(temporary as CFURL, nil),
              let verified = CGImageSourceCreateImageAtIndex(verifiedSource, 0, nil),
              verified.width == outputImage.width, verified.height == outputImage.height else {
            throw KioFailure.verification("The metadata-free image copy could not be verified.")
        }
        try OutputLocation.commit(temporary, to: output)
        return try ArtifactRef.inspect(output, parentID: input.id)
            .withVerificationNote("Created a new image copy without its embedded metadata. The original remains unchanged.")
    }

    private func imageContactSheet(_ inputs: [ArtifactRef]) throws -> ArtifactRef {
        let columns = 4
        let cellWidth = 300
        let cellHeight = 250
        let rows = (inputs.count + columns - 1) / columns
        let width = columns * cellWidth
        let height = rows * cellHeight
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw KioFailure.processing("Kio couldn't create the contact sheet canvas.")
        }
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            let image = try decodedStaticImage(input, maximumPixel: 1_200)
            let column = index % columns
            let row = index / columns
            let cell = CGRect(x: column * cellWidth, y: height - (row + 1) * cellHeight, width: cellWidth, height: cellHeight)
            context.saveGState()
            context.clip(to: cell)
            context.setFillColor(CGColor(gray: 0.96, alpha: 1))
            context.fill(cell)
            let scale = min(CGFloat(cellWidth - 28) / CGFloat(image.width), CGFloat(cellHeight - 58) / CGFloat(image.height))
            let imageWidth = CGFloat(image.width) * scale
            let imageHeight = CGFloat(image.height) * scale
            let availableHeight = CGFloat(cellHeight - 58)
            let imageX = cell.midX - imageWidth / 2
            let imageY = cell.minY + 46 + (availableHeight - imageHeight) / 2
            let imageRect = CGRect(x: imageX, y: imageY, width: imageWidth, height: imageHeight)
            context.draw(image, in: imageRect)
            let label = String(input.displayName.prefix(36)) as CFString
            let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0.1, alpha: 1)] as CFDictionary
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, label, attributes)!)
            context.textPosition = CGPoint(x: cell.minX + 12, y: cell.minY + 17)
            CTLineDraw(line, context)
            context.restoreGState()
        }
        guard let sheet = context.makeImage() else { throw KioFailure.processing("Kio couldn't render the contact sheet.") }
        let baseName = Self.base(inputs[0].displayName) + "-Contact-Sheet"
        let output = try OutputLocation.makeURL(for: inputs, baseName: baseName, fileExtension: "png")
        return try writePNG(sheet, output: output, parentID: inputs[0].id, note: "Contact sheet made from \(inputs.count) images.")
    }

    private func decodedStaticImage(_ input: ArtifactRef, maximumPixel: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(input.fileURL as CFURL, nil), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20_000, height <= 20_000,
              width <= 150_000_000 / height,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixel
              ] as CFDictionary) else {
            throw KioFailure.unsupported("Choose one readable static image no larger than 20,000 pixels per side and 150 megapixels.")
        }
        return image
    }

    private func writePNG(_ image: CGImage, output: URL, parentID: UUID?, note: String?) throws -> ArtifactRef {
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw KioFailure.processing("Kio couldn't prepare the PNG image copy.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithURL(temporary as CFURL, nil),
              let verified = CGImageSourceCreateImageAtIndex(source, 0, nil), verified.width == image.width, verified.height == image.height else {
            throw KioFailure.verification("The PNG image copy could not be verified.")
        }
        try OutputLocation.commit(temporary, to: output)
        return try ArtifactRef.inspect(output, parentID: parentID).withVerificationNote(note)
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

    private func fileSourcesAndDestination(_ inputs: [ArtifactRef], action: String) throws -> ([ArtifactRef], URL) {
        guard inputs.count >= 2, let destination = inputs.last, destination.kind == .folder,
              (try? destination.fileURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory) == true,
              (try? destination.fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw KioFailure.invalidInput("Attach the files first and a writable destination folder last to \(action) them.")
        }
        let files = Array(inputs.dropLast())
        guard files.allSatisfy({ $0.kind != .folder && isRegularFile($0.fileURL) }) else {
            throw KioFailure.invalidInput("Kio can \(action) regular files here; folders and symbolic links aren't supported.")
        }
        return (files, destination.fileURL)
    }

    private func copyFiles(_ inputs: [ArtifactRef], to folder: URL) throws -> [ArtifactRef] {
        var outputs: [ArtifactRef] = []
        do {
            for input in inputs {
                try Task.checkCancellation()
                let digest = try sha256(input.fileURL)
                let output = try OutputLocation.makeURL(in: folder, baseName: Self.base(input.displayName), fileExtension: input.fileURL.pathExtension)
                try FileManager.default.copyItem(at: input.fileURL, to: output)
                let result = try ArtifactRef.inspect(output, parentID: input.id)
                guard result.sizeBytes == input.sizeBytes, try sha256(output) == digest else {
                    throw KioFailure.verification("The copy of \(input.displayName) did not match its source.")
                }
                outputs.append(result)
            }
            return outputs
        } catch {
            for output in outputs { try? FileManager.default.removeItem(at: output.fileURL) }
            throw error
        }
    }

    private func moveFiles(_ inputs: [ArtifactRef], to folder: URL) throws -> [ArtifactRef] {
        var moved: [(source: URL, destination: URL)] = []
        var outputs: [ArtifactRef] = []
        do {
            for input in inputs {
                try Task.checkCancellation()
                guard input.fileURL.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL else {
                    throw KioFailure.invalidInput("The destination is already the source folder. Choose a different folder to move these files.")
                }
                let digest = try sha256(input.fileURL)
                let output = try OutputLocation.makeURL(in: folder, baseName: Self.base(input.displayName), fileExtension: input.fileURL.pathExtension)
                try FileManager.default.moveItem(at: input.fileURL, to: output)
                moved.append((input.fileURL, output))
                let result = try ArtifactRef.inspect(output, parentID: input.id)
                guard result.sizeBytes == input.sizeBytes, try sha256(output) == digest else {
                    throw KioFailure.verification("The moved file \(input.displayName) did not match its original contents.")
                }
                outputs.append(result.withVerificationNote("Moved to \(folder.lastPathComponent) as requested."))
            }
            return outputs
        } catch {
            for item in moved.reversed() { try? FileManager.default.moveItem(at: item.destination, to: item.source) }
            throw error
        }
    }

    private func createFolder(named name: String, inside parent: ArtifactRef) throws -> ArtifactRef {
        guard isSafeFolder(parent.fileURL), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100 else {
            throw KioFailure.invalidInput("Choose a writable parent folder and a short folder name.")
        }
        let output = try OutputLocation.makeDirectoryURL(inside: parent.fileURL, name: name)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        return try ArtifactRef.inspect(output, parentID: parent.id)
    }

    private func findDuplicates(_ inputs: [ArtifactRef]) throws -> ArtifactRef {
        guard (2...200).contains(inputs.count), inputs.allSatisfy({ $0.kind != .folder && isRegularFile($0.fileURL) }) else {
            throw KioFailure.invalidInput("Choose 2 to 200 regular files to check for exact duplicates.")
        }
        let totalSize = inputs.reduce(Int64(0)) { $0 + $1.sizeBytes }
        guard totalSize <= 10_000_000_000 else { throw KioFailure.unsupported("Duplicate checking is limited to 10 GB of file data at a time.") }
        var groups: [String: [ArtifactRef]] = [:]
        for input in inputs {
            try Task.checkCancellation()
            groups[try sha256(input.fileURL), default: []].append(input)
        }
        let duplicates = groups.values.filter { $0.count > 1 }.sorted { $0[0].displayName.localizedStandardCompare($1[0].displayName) == .orderedAscending }
        var lines = ["Exact duplicate report", "Files checked: \(inputs.count)", "Method: byte-for-byte SHA-256 hashes", ""]
        if duplicates.isEmpty {
            lines.append("No exact duplicate files were found.")
        } else {
            lines.append("Duplicate groups: \(duplicates.count)")
            for (index, group) in duplicates.enumerated() {
                lines.append("Group \(index + 1):")
                lines.append(contentsOf: group.map { "• \($0.displayName) (\($0.sizeBytes) bytes)" })
            }
        }
        return try writeTextArtifact(inputs[0], suffix: "-Duplicates", text: lines.joined(separator: "\n"))
    }

    private func organizeFiles(_ inputs: [ArtifactRef], byDate: Bool) throws -> ArtifactRef {
        guard (1...200).contains(inputs.count), inputs.allSatisfy({ $0.kind != .folder && isRegularFile($0.fileURL) }) else {
            throw KioFailure.invalidInput("Choose 1 to 200 regular files to organize.")
        }
        let totalSize = inputs.reduce(Int64(0)) { $0 + $1.sizeBytes }
        guard totalSize <= 10_000_000_000 else { throw KioFailure.unsupported("Organization is limited to 10 GB of file data at a time.") }
        let suffix = byDate ? "-Organized-by-Date" : "-Organized-by-Type"
        let output = try OutputLocation.makeDirectoryURL(for: inputs, baseName: Self.base(inputs[0].displayName) + suffix)
        let staging = output.deletingLastPathComponent().appendingPathComponent(".kio-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            for input in inputs {
                try Task.checkCancellation()
                let groupName = byDate ? dateFolder(for: input.fileURL) : typeFolder(for: input)
                let group = staging.appendingPathComponent(groupName, isDirectory: true)
                try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
                let destination = try OutputLocation.makeURL(in: group, baseName: Self.base(input.displayName), fileExtension: input.fileURL.pathExtension)
                try FileManager.default.copyItem(at: input.fileURL, to: destination)
                let copied = try ArtifactRef.inspect(destination)
                guard copied.sizeBytes == input.sizeBytes, try sha256(destination) == sha256(input.fileURL) else {
                    throw KioFailure.verification("The organized copy of \(input.displayName) did not match its source.")
                }
            }
            guard !FileManager.default.fileExists(atPath: output.path) else { throw KioFailure.processing("A folder with that name appeared while Kio was organizing the files.") }
            try FileManager.default.moveItem(at: staging, to: output)
            return try ArtifactRef.inspect(output, parentID: inputs.first?.id)
                .withVerificationNote("Organized \(inputs.count) verified copies into \(byDate ? "date" : "type") folders. The originals remain unchanged.")
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func isSafeFolder(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true && FileManager.default.isWritableFile(atPath: url.path)
    }

    private func typeFolder(for input: ArtifactRef) -> String {
        switch input.kind {
        case .pdf: "PDFs"
        case .image: "Images"
        case .audio: "Audio"
        case .video: "Videos"
        case .text, .csv: "Documents"
        case .folder: "Folders"
        case .other: "Other"
        }
    }

    private func dateFolder(for url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let date = attributes?[.modificationDate] as? Date else { return "Unknown-Date" }
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month else { return "Unknown-Date" }
        return String(format: "%04d-%02d", year, month)
    }

    private func exactRename(_ input: ArtifactRef, requestedName: String) throws -> ArtifactRef {
        let requestedURL = URL(fileURLWithPath: requestedName)
        let safeRequestedName = requestedURL.lastPathComponent
        let requestedExtension = requestedURL.pathExtension
        let outputExtension: String
        let baseName: String
        if requestedExtension.isEmpty {
            outputExtension = input.fileURL.pathExtension
            baseName = safeRequestedName
        } else {
            guard requestedExtension.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }),
                  let requestedType = UTType(filenameExtension: requestedExtension),
                  let sourceType = UTType(filenameExtension: input.fileURL.pathExtension),
                  requestedType.identifier == sourceType.identifier else {
                throw KioFailure.invalidInput("Use the existing file extension, or leave it off to keep the current format.")
            }
            outputExtension = requestedExtension.lowercased()
            baseName = requestedURL.deletingPathExtension().lastPathComponent
        }
        guard !baseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KioFailure.invalidInput("Enter a file name before the extension.")
        }
        let output = try OutputLocation.makeURL(for: [input], baseName: baseName, fileExtension: outputExtension)
        try FileManager.default.copyItem(at: input.fileURL, to: output)
        do {
            let result = try ArtifactRef.inspect(output, parentID: input.id)
            guard result.sizeBytes == input.sizeBytes else { throw KioFailure.verification("The renamed copy did not verify.") }
            return result
        } catch {
            try? FileManager.default.removeItem(at: output)
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

    private func inspectArchive(_ input: ArtifactRef) throws -> ArtifactRef {
        guard let names = try Self.archiveEntryNames(at: input.fileURL) else {
            throw KioFailure.invalidInput("This file doesn't contain a supported, readable ZIP directory.")
        }
        let shown = names.prefix(50).map { "• \($0)" }
        let remainder = names.count > shown.count ? "\n…and \(names.count - shown.count) more entries." : ""
        let summary = (["ZIP archive: \(input.displayName)", "Entries: \(names.count)"] + shown).joined(separator: "\n") + remainder
        return try writeTextArtifact(input, suffix: "-Contents", text: summary)
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
        try archiveEntryNames(at: url)?.count ?? 0
    }

    private static func archiveEntryNames(at url: URL) throws -> [String]? {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 22 else { return nil }
        let lower = max(0, data.count - 65_557)
        var endRecord: Int?
        for offset in stride(from: data.count - 22, through: lower, by: -1) {
            if data.readLE(UInt32.self, at: offset) == 0x06054b50 {
                let commentLength = Int(data.readLE(UInt16.self, at: offset + 20) ?? UInt16.max)
                if offset + 22 + commentLength <= data.count { endRecord = offset; break }
            }
        }
        guard let endRecord,
              data.readLE(UInt16.self, at: endRecord + 4) == 0,
              data.readLE(UInt16.self, at: endRecord + 6) == 0,
              let diskEntries = data.readLE(UInt16.self, at: endRecord + 8),
              let entryCount = data.readLE(UInt16.self, at: endRecord + 10),
              diskEntries == entryCount,
              let centralSize = data.readLE(UInt32.self, at: endRecord + 12),
              let centralOffset = data.readLE(UInt32.self, at: endRecord + 16) else { return nil }
        let start = Int(centralOffset)
        let end = start + Int(centralSize)
        guard start >= 0, end >= start, end <= endRecord else { return nil }
        var names: [String] = []
        var cursor = start
        for _ in 0..<Int(entryCount) {
            guard cursor + 46 <= end, data.readLE(UInt32.self, at: cursor) == 0x02014b50,
                  let nameLength = data.readLE(UInt16.self, at: cursor + 28),
                  let extraLength = data.readLE(UInt16.self, at: cursor + 30),
                  let commentLength = data.readLE(UInt16.self, at: cursor + 32) else { return nil }
            let next = cursor + 46 + Int(nameLength) + Int(extraLength) + Int(commentLength)
            guard next <= end else { return nil }
            let nameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + Int(nameLength)))
            guard let name = String(data: nameData, encoding: .utf8), !name.isEmpty else { return nil }
            names.append(name)
            cursor = next
        }
        guard cursor == end else { return nil }
        return names
    }

    private func inspectMedia(_ input: ArtifactRef) async throws -> ArtifactRef {
        let asset = AVURLAsset(url: input.fileURL)
        let tracks = try await asset.load(.tracks)
        let duration = try await asset.load(.duration)
        guard tracks.contains(where: { $0.mediaType == .video }) else { throw KioFailure.invalidInput("This file does not contain a readable video track.") }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw KioFailure.verification("Kio couldn't read the video duration.") }
        let audioCount = tracks.filter { $0.mediaType == .audio }.count
        let videoCount = tracks.filter { $0.mediaType == .video }.count
        let summary = [
            "Video: \(input.displayName)",
            String(format: "Duration: %.2f seconds", seconds),
            "Video tracks: \(videoCount)",
            "Audio tracks: \(audioCount)",
            "File size: \(ByteCountFormatter.string(fromByteCount: input.sizeBytes, countStyle: .file))"
        ].joined(separator: "\n")
        return try writeTextArtifact(input, suffix: "-Info", text: summary)
    }

    private func thumbnailVideo(_ input: ArtifactRef, timeMilliseconds: Int64) async throws -> ArtifactRef {
        guard (0...86_400_000).contains(timeMilliseconds) else { throw KioFailure.invalidInput("Choose a thumbnail time within the first 24 hours.") }
        let asset = AVURLAsset(url: input.fileURL)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let seconds = Double(timeMilliseconds) / 1_000
        guard duration.isFinite, seconds < duration else { throw KioFailure.invalidInput("The requested thumbnail time is past the end of this video.") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_600, height: 1_600)
        let (image, actualTime) = try await generator.image(at: CMTime(value: timeMilliseconds, timescale: 1_000))
        try Task.checkCancellation()
        let actualSeconds = CMTimeGetSeconds(actualTime)
        guard actualSeconds.isFinite, actualSeconds >= 0, image.width > 0, image.height > 0 else {
            throw KioFailure.verification("Kio couldn't verify the video thumbnail.")
        }
        let output = try OutputLocation.makeURL(for: [input], baseName: Self.base(input.displayName) + "-Thumbnail", fileExtension: "png")
        return try writePNG(image, output: output, parentID: input.id, note: String(format: "Frame near %.2f seconds.", actualSeconds))
    }

    private func trimVideo(_ input: ArtifactRef, startMilliseconds: Int64, durationMilliseconds: Int64) async throws -> ArtifactRef {
        guard startMilliseconds >= 0, durationMilliseconds > 0,
              startMilliseconds + durationMilliseconds <= 86_400_000 else { throw KioFailure.invalidInput("Choose a valid video trim range.") }
        let range = CMTimeRange(start: CMTime(value: startMilliseconds, timescale: 1_000),
                                duration: CMTime(value: durationMilliseconds, timescale: 1_000))
        return try await exportVideoCopy(input, preset: AVAssetExportPresetHighestQuality, suffix: "-Trimmed", timeRange: range,
                                         expectedDuration: Double(durationMilliseconds) / 1_000, maximumWidth: nil)
    }

    private func resizeVideo(_ input: ArtifactRef, width: Int) async throws -> ArtifactRef {
        let preset: String
        switch width {
        case 640: preset = AVAssetExportPreset640x480
        case 960: preset = AVAssetExportPreset960x540
        case 1280: preset = AVAssetExportPreset1280x720
        default: throw KioFailure.invalidInput("Choose a video width of 640, 960, or 1280 pixels.")
        }
        return try await exportVideoCopy(input, preset: preset, suffix: "-Resized", timeRange: nil,
                                         expectedDuration: nil, maximumWidth: width)
    }

    private func transcodeVideo(_ input: ArtifactRef) async throws -> ArtifactRef {
        try await exportVideoCopy(input, preset: AVAssetExportPresetHighestQuality, suffix: "-Converted",
                                  timeRange: nil, expectedDuration: nil, maximumWidth: nil)
    }

    private func exportVideoCopy(_ input: ArtifactRef, preset: String, suffix: String,
                                 timeRange: CMTimeRange?, expectedDuration: Double?, maximumWidth: Int?) async throws -> ArtifactRef {
        let asset = AVURLAsset(url: input.fileURL)
        guard try await asset.load(.tracks).contains(where: { $0.mediaType == .video }) else {
            throw KioFailure.invalidInput("This file does not contain a readable video track.")
        }
        let output = try OutputLocation.makeURL(for: [input], baseName: Self.base(input.displayName) + suffix, fileExtension: "mp4")
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await exportMovie(asset, preset: preset, to: temporary, timeRange: timeRange)
        let verified = AVURLAsset(url: temporary)
        let tracks = try await verified.load(.tracks)
        let duration = CMTimeGetSeconds(try await verified.load(.duration))
        guard tracks.contains(where: { $0.mediaType == .video }), duration.isFinite, duration > 0 else {
            throw KioFailure.verification("The exported video has no readable video track or duration.")
        }
        if let expectedDuration, abs(duration - expectedDuration) > max(0.25, expectedDuration * 0.1) {
            throw KioFailure.verification("The trimmed video duration did not match the requested range.")
        }
        if let maximumWidth, let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
            let naturalSize = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)
            let oriented = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized.size
            guard max(oriented.width, oriented.height) <= CGFloat(maximumWidth) + 2 else {
                throw KioFailure.verification("The exported video is wider than the requested maximum.")
            }
        }
        try OutputLocation.commit(temporary, to: output)
        return try ArtifactRef.inspect(output, parentID: input.id)
    }

    private func exportMovie(_ asset: AVAsset, preset: String, to url: URL, timeRange: CMTimeRange?) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset), session.supportedFileTypes.contains(.mp4) else {
            throw KioFailure.unsupported("This video can't be exported as a compatible MP4 on this Mac.")
        }
        if let timeRange { session.timeRange = timeRange }
        try await session.export(to: url, as: .mp4)
        try Task.checkCancellation()
    }

    private func compressVideo(_ input: ArtifactRef, maxBytes: Int64?) async throws -> ArtifactRef {
        if let maxBytes, !(1...10_000_000_000).contains(maxBytes) { throw KioFailure.invalidInput("Choose a video size target between 1 byte and 10 GB.") }
        let asset = AVURLAsset(url: input.fileURL)
        guard try await asset.load(.tracks).contains(where: { $0.mediaType == .video }) else {
            throw KioFailure.invalidInput("This file does not contain a readable video track.")
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("KioVideoCompression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let presets = [AVAssetExportPresetMediumQuality, AVAssetExportPreset960x540, AVAssetExportPreset640x480]
        var best: (url: URL, size: Int64)?
        var reachedTarget = false
        for (index, preset) in presets.enumerated() {
            try Task.checkCancellation()
            let candidate = staging.appendingPathComponent("candidate-\(index).mp4")
            do {
                try await exportMovie(asset, preset: preset, to: candidate, timeRange: nil)
                let verificationAsset = AVURLAsset(url: candidate)
                let tracks = try await verificationAsset.load(.tracks)
                guard tracks.contains(where: { $0.mediaType == .video }),
                      CMTimeGetSeconds(try await verificationAsset.load(.duration)).isFinite else { continue }
                let size = Int64(try candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                if size > 0, best == nil || size < best!.size { best = (candidate, size) }
                if let maxBytes, size > 0, size <= maxBytes { best = (candidate, size); reachedTarget = true; break }
                if maxBytes == nil, size > 0, size < Int64(Double(input.sizeBytes) * 0.97) { best = (candidate, size); break }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        guard let best, best.size > 0, best.size < input.sizeBytes else {
            throw KioFailure.processing("This video did not get smaller with the supported native export presets.")
        }
        let output = try OutputLocation.makeURL(for: [input], baseName: Self.base(input.displayName) + "-Compressed", fileExtension: "mp4")
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: best.url, to: temporary)
        try OutputLocation.commit(temporary, to: output)
        let note: String
        if let maxBytes, !reachedTarget {
            note = "Created a smaller MP4 at \(ByteCountFormatter.string(fromByteCount: best.size, countStyle: .file)), but it did not reach \(ByteCountFormatter.string(fromByteCount: maxBytes, countStyle: .file)). The original remains unchanged."
        } else {
            note = "Created a smaller MP4 copy. The original remains unchanged."
        }
        return try ArtifactRef.inspect(output, parentID: input.id).withVerificationNote(note)
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
