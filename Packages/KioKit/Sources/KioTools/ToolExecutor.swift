import AVFoundation
import AppKit
import CoreImage
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import KioCore

public struct ToolExecutor: Sendable {
    private let mediaRuntimeRoot: URL?

    public init(mediaRuntimeRoot: URL? = nil) {
        self.mediaRuntimeRoot = mediaRuntimeRoot
    }

    public func execute(_ step: TaskStep, inputs: [ArtifactRef]) async throws -> [ArtifactRef] {
        try Task.checkCancellation()
        guard !inputs.isEmpty else { throw KioFailure.invalidInput("Add a file for this conversion.") }
        switch step.operation {
        case .mergePDFs:
            guard inputs.count >= 2, inputs.allSatisfy({ $0.kind == .pdf }) else { throw KioFailure.invalidInput("Choose at least two PDF files.") }
            return [try mergePDFs(inputs)]
        case .imagesToPDF:
            guard inputs.allSatisfy({ $0.kind == .image }) else { throw KioFailure.invalidInput("Choose image files to create a PDF.") }
            return [try imagesToPDF(inputs)]
        case .compressPDF:
            guard inputs.count == 1, let input = inputs.first, input.kind == .pdf,
                  case .pdfCompression(let maxBytes) = step.arguments else { throw KioFailure.invalidInput("Choose one PDF and an optional target size.") }
            return [try compressPDF(input, maxBytes: maxBytes)]
        case .resizeImage, .batchResizeImages:
            guard inputs.allSatisfy({ $0.kind == .image }), case .imageResize(let width) = step.arguments,
                  (1...20_000).contains(width) else { throw KioFailure.invalidInput("Choose images and a width from 1 to 20,000 pixels.") }
            return try performAtomicBatch(inputs) { try resizeImage($0, width: width) }
        case .convertImage, .batchConvertImages:
            guard inputs.allSatisfy({ $0.kind == .image }), case .imageConvert(let format) = step.arguments else { throw KioFailure.invalidInput("Choose images and an output format.") }
            return try performAtomicBatch(inputs) { try convertImage($0, format: format) }
        case .compressImage:
            guard inputs.allSatisfy({ $0.kind == .image }), case .imageCompression(let maxBytes) = step.arguments else { throw KioFailure.invalidInput("Choose images and an optional target size.") }
            return try performAtomicBatch(inputs) { try compressImage($0, maxBytes: maxBytes) }
        case .convertAudio:
            guard case .audioConvert(let format) = step.arguments,
                  inputs.allSatisfy({ $0.kind == .audio || $0.kind == .video }) else { throw KioFailure.invalidInput("Choose audio or video and an audio output format.") }
            return try await convertAudio(inputs, format: format)
        case .extractAudio:
            guard inputs.allSatisfy({ $0.kind == .video }) else { throw KioFailure.invalidInput("Choose video files to extract their audio.") }
            return try await convertAudio(inputs, format: .m4a)
        case .resizeVideo:
            guard inputs.allSatisfy({ $0.kind == .video }), case .mediaResize(let width) = step.arguments else { throw KioFailure.invalidInput("Choose video files and a target width.") }
            return try await convertVideos(inputs) { try await resizeVideo($0, width: width) }
        case .transcodeVideo:
            guard inputs.allSatisfy({ $0.kind == .video }), case .videoConvert(let format) = step.arguments else { throw KioFailure.invalidInput("Choose video files and a supported output format.") }
            return try await convertVideos(inputs) { try await transcodeVideo($0, format: format) }
        case .compressVideo:
            guard inputs.allSatisfy({ $0.kind == .video }), case .mediaCompression(let maxBytes) = step.arguments else { throw KioFailure.invalidInput("Choose video files and an optional target size.") }
            return try await convertVideos(inputs) { try await compressVideo($0, maxBytes: maxBytes) }
        case .inspectRemoteMedia, .downloadRemoteVideo, .downloadRemoteAudio, .downloadRemoteLive, .downloadRemoteSubtitles, .downloadRemoteThumbnail:
            return try await ReelWorkflow.execute(step.operation, inputs: inputs, arguments: step.arguments)
        }
    }

    private func convertAudio(_ inputs: [ArtifactRef], format: AudioTargetFormat) async throws -> [ArtifactRef] {
        var outputs: [ArtifactRef] = []
        do {
            for input in inputs {
                try Task.checkCancellation()
                let output = try OutputLocation.makeURL(for: [input], baseName: Self.base(input.displayName) + "-Converted", fileExtension: format.rawValue)
                let temporary = OutputLocation.temporaryURL(beside: output)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try await BundledMediaRuntime.transcodeAudio(input.fileURL, to: temporary, format: format,
                                                              runtimeRoot: mediaRuntimeRoot)
                let info = try await BundledMediaRuntime.probe(temporary, runtimeRoot: mediaRuntimeRoot)
                guard info.isCompatibleAudio(with: format), info.duration.map({ $0.isFinite && $0 > 0 }) == true else {
                    throw KioFailure.verification("The converted audio failed its format or duration check.")
                }
                try OutputLocation.commit(temporary, to: output)
                outputs.append(try ArtifactRef.inspect(output, parentID: input.id))
            }
            return outputs
        } catch {
            for output in outputs { try? FileManager.default.removeItem(at: output.fileURL) }
            throw error
        }
    }

    private func convertVideos(_ inputs: [ArtifactRef], operation: (ArtifactRef) async throws -> ArtifactRef) async throws -> [ArtifactRef] {
        var outputs: [ArtifactRef] = []
        do {
            for input in inputs { try Task.checkCancellation(); outputs.append(try await operation(input)) }
            return outputs
        } catch {
            for output in outputs { try? FileManager.default.removeItem(at: output.fileURL) }
            throw error
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
        var firstFrameOnly = false
        for input in inputs {
            guard let source = CGImageSourceCreateWithURL(input.fileURL as CFURL, nil),
                  let image = try? orientedImage(source, maximumPixel: 20_000),
                  let page = PDFPage(image: NSImage(cgImage: image, size: .zero)) else {
                throw KioFailure.invalidInput("\(input.displayName) could not be opened as an image.")
            }
            firstFrameOnly = firstFrameOnly || CGImageSourceGetCount(source) > 1
            document.insert(page, at: document.pageCount)
        }
        guard document.pageCount == inputs.count, document.write(to: temporary),
              let verified = PDFDocument(url: temporary), verified.pageCount == inputs.count else {
            throw KioFailure.verification("The image PDF could not be verified.")
        }
        try OutputLocation.commit(temporary, to: output)
        let note = firstFrameOnly ? "Animated image inputs contribute their first frame only. The original images remain unchanged." : nil
        return try ArtifactRef.inspect(output, parentID: inputs.first?.id).withVerificationNote(note)
    }

    private func resizeImage(_ input: ArtifactRef, width: Int) throws -> ArtifactRef {
        guard let image = try? decodedStaticImage(input, maximumPixel: 20_000) else { throw KioFailure.invalidInput("This image could not be opened as a static image.") }
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
              let image = try? orientedImage(source, maximumPixel: 20_000) else { throw KioFailure.invalidInput("This image could not be opened.") }
        let requestedFormat = format.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let normalized = requestedFormat == "jpg" || requestedFormat == "jpeg" ? "jpeg" : requestedFormat
        let (uti, ext): (String, String) = switch normalized {
        case "png": (UTType.png.identifier, "png")
        case "jpeg": (UTType.jpeg.identifier, requestedFormat == "jpeg" ? "jpeg" : "jpg")
        case "heic", "heif": (UTType.heic.identifier, "heic")
        case "tiff", "tif": (UTType.tiff.identifier, "tiff")
        case "webp": ("org.webmproject.webp", "webp")
        default: throw KioFailure.unsupported("Convert supports PNG, JPEG, HEIC, TIFF, and WebP only when this macOS runtime can encode them.")
        }
        let encoderTypes = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        guard encoderTypes.contains(uti) else { throw KioFailure.unsupported("This macOS ImageIO runtime cannot encode \(normalized.uppercased()) images.") }
        let output = try OutputLocation.makeURL(for: [input], baseName: Self.base(input.displayName), fileExtension: ext)
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, uti as CFString, 1, nil) else {
            throw KioFailure.processing("Kio could not create the converted image.")
        }
        let outputImage = normalized == "jpeg" ? try Self.flattenForJPEG(image) : image
        let properties: [CFString: Any] = normalized == "jpeg" ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:]
        CGImageDestinationAddImage(destination, outputImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let check = CGImageSourceCreateWithURL(temporary as CFURL, nil),
                  CGImageSourceGetCount(check) == 1,
              CGImageSourceGetType(check) as String? == uti,
              let verifiedImage = CGImageSourceCreateThumbnailAtIndex(check, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 20_000
              ] as CFDictionary), verifiedImage.width > 0, verifiedImage.height > 0,
              output.pathExtension.lowercased() == ext else { throw KioFailure.verification("The converted image's encoded format, extension, or dimensions could not be verified.") }
        try OutputLocation.commit(temporary, to: output)
        let animatedInput = CGImageSourceGetCount(source) > 1
        let note = animatedInput ? "Converted the first frame only; this operation does not preserve animation. The original remains unchanged." : nil
        return try ArtifactRef.inspect(output, parentID: input.id).withVerificationNote(note)
    }

    private static func flattenForJPEG(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw KioFailure.processing("Kio couldn't prepare a white background for JPEG transparency flattening.")
        }
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flattened = context.makeImage() else { throw KioFailure.processing("Kio couldn't flatten the transparent image for JPEG.") }
        return flattened
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

    private func decodedStaticImage(_ input: ArtifactRef, maximumPixel: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(input.fileURL as CFURL, nil), CGImageSourceGetCount(source) == 1,
              let image = try? orientedImage(source, maximumPixel: maximumPixel) else {
            throw KioFailure.unsupported("Choose one readable static image no larger than 20,000 pixels per side and 150 megapixels.")
        }
        return image
    }

    private func orientedImage(_ source: CGImageSource, maximumPixel: Int) throws -> CGImage {
        guard maximumPixel > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20_000, height <= 20_000,
              width <= 150_000_000 / height,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixel
              ] as CFDictionary), image.width > 0, image.height > 0 else {
            throw KioFailure.invalidInput("This image is unreadable or exceeds the 20,000 pixel/150 megapixel safety bound.")
        }
        return image
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

    private func transcodeVideo(_ input: ArtifactRef, format: VideoTargetFormat) async throws -> ArtifactRef {
        guard let container = ReelVideoContainer(rawValue: format.rawValue) else {
            throw KioFailure.invalidInput("Choose MP4, MOV, MKV, or WebM.")
        }
        let source = try await BundledMediaRuntime.probe(input.fileURL)
        guard source.hasVideo else { throw KioFailure.invalidInput("This file does not contain a readable video stream.") }
        if container == .webm && !source.isCompatible(with: .webm) {
            throw KioFailure.unsupported("The bundled runtime can create WebM only when the source already has WebM-compatible video and audio streams.")
        }
        guard let duration = source.duration, duration.isFinite, duration > 0 else {
            throw KioFailure.verification("The source video has no finite readable duration.")
        }
        let output = try OutputLocation.makeURL(for: [input], baseName: Self.base(input.displayName) + "-Converted",
                                                fileExtension: format.rawValue)
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await BundledMediaRuntime.transcodeVideo(input.fileURL, to: temporary, container: container)
        let verified = try await BundledMediaRuntime.probe(temporary)
        let size = Int64((try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard verified.hasVideo, (!source.hasAudio || verified.hasAudio),
              verified.isCompatible(with: container),
              verified.duration.map({ $0.isFinite && abs($0 - duration) <= max(1, duration * 0.02) }) == true,
              size > 0, size <= BundledMediaRuntime.maximumMediaBytes else {
            throw KioFailure.verification("The converted video failed its container, stream, duration, or size checks.")
        }
        try OutputLocation.commit(temporary, to: output)
        return try ArtifactRef.inspect(output, parentID: input.id)
            .withVerificationNote("Verified \(format.rawValue.uppercased()) video with its video and audio tracks.")
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

    private func performAtomicBatch(_ inputs: [ArtifactRef], operation: (ArtifactRef) throws -> ArtifactRef) throws -> [ArtifactRef] {
        var completed: [ArtifactRef] = []
        do {
            for input in inputs {
                try Task.checkCancellation()
                completed.append(try operation(input))
            }
            return completed
        } catch {
            for output in completed where output.role == .userResult {
                try? FileManager.default.removeItem(at: output.fileURL)
            }
            throw error
        }
    }

    private static func base(_ name: String) -> String { URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent }

    private static func imageUTI(for ext: String) -> CFString {
        let uti: UTType = switch ext.lowercased() {
        case "jpg", "jpeg": .jpeg
        case "heic", "heif": .heic
        case "tif", "tiff": .tiff
        case "webp": UTType("org.webmproject.webp") ?? .png
        default: .png
        }
        return uti.identifier as CFString
    }
}
