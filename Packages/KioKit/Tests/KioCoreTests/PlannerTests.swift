import Foundation
import Testing
import KioCore
@testable import KioModel

@Test func destinationFormatsCompileFromStructuredSemanticIntent() throws {
    let png = try makeArtifact(name: "source.png", kind: .image)
    let cases: [(String, String)] = [
        ("convert this png to a heic", "heic"),
        ("turn this PNG into HEIC", "heic"),
        ("convert this into jpeg", "jpeg"),
        ("make this a jpg", "jpg"),
        ("export this as .tiff", "tiff"),
        ("give me a webp version", "webp")
    ]
    for (request, format) in cases {
        let plan = FastPathPlanner().plan(request: request, artifacts: [png])
        #expect(plan.steps.first?.operation == .convertImage)
        #expect(plan.steps.first?.arguments == .imageConvert(format: format))
    }
}

@Test func explicitNeedAndBareJpegRequestPreserveTheRequestedFormat() throws {
    let image = try makeArtifact(name: "photo.png", kind: .image)
    let need = FastPathPlanner().plan(request: "I need this as a .jpeg file", artifacts: [image])
    #expect(need.steps.first?.operation == .convertImage)
    #expect(need.steps.first?.arguments == .imageConvert(format: "jpeg"))

    let bare = FastPathPlanner().plan(request: "JPEG, please", artifacts: [image])
    #expect(bare.steps.first?.operation == .convertImage)
    #expect(bare.steps.first?.arguments == .imageConvert(format: "jpeg"))
}

@Test func semanticCompilerRejectsAnExplicitSourceSubtypeThatDoesNotMatchTheInput() throws {
    let image = try makeArtifact(name: "actual.jpg", kind: .image)
    let imagePlan = FastPathPlanner().plan(request: "convert this PNG to HEIC", artifacts: [image])
    #expect(imagePlan.steps.isEmpty)
    #expect(imagePlan.clarification != nil)

    let video = try makeArtifact(name: "actual.webm", kind: .video)
    let audioPlan = FastPathPlanner().plan(request: "convert this MP4 to MP3", artifacts: [video])
    #expect(audioPlan.steps.isEmpty)
    #expect(audioPlan.clarification != nil)
}

@Test func semanticFormatRelationshipsAlwaysChooseTheDestinationAcrossPhrasing() throws {
    let imageFormats = ["png", "jpeg", "jpg", "heic", "tiff", "webp"]
    let input = try makeArtifact(name: "source.png", kind: .image)
    let templates = [
        "convert this png to %@",
        "convert this png into %@",
        "turn this png into %@",
        "export this as %@",
        "save this as %@",
        "make this %@",
        "give me a %@ version"
    ]
    for target in imageFormats {
        for template in templates {
            let request = String(format: template, target.uppercased())
            let plan = FastPathPlanner().plan(request: request, artifacts: [input])
            #expect(plan.steps.first?.arguments == .imageConvert(format: target), "\(request)")
        }
    }
    let arrow = FastPathPlanner().plan(request: "PNG -> HEIC", artifacts: [input])
    #expect(arrow.steps.first?.arguments == .imageConvert(format: "heic"))
    let unicodeArrow = FastPathPlanner().plan(request: "png→heic", artifacts: [input])
    #expect(unicodeArrow.steps.first?.arguments == .imageConvert(format: "heic"))

    let unsupportedSizeContract = FastPathPlanner().plan(request: "convert this to jpeg under 3 megs", artifacts: [input])
    #expect(unsupportedSizeContract.steps.map(\.operation) == [.convertImage, .compressImage])
    #expect(unsupportedSizeContract.steps.last?.arguments == .imageCompression(maxBytes: 3_000_000))

    let video = try makeArtifact(name: "clip.mp4", kind: .video)
    for target in ["mp3", "m4a", "wav", "flac"] {
        let plan = FastPathPlanner().plan(request: "convert this video to \(target)", artifacts: [video])
        #expect(plan.steps.first?.arguments == .audioConvert(format: AudioTargetFormat(rawValue: target)!))
    }
}

@Test func semanticIntentCapturesTypedQualityAndTargetSize() {
    guard case .resolved(let intent, let confidence) = SemanticIntentParser.parse("download this video as mp4 at 1080p below 3 megs") else {
        Issue.record("A structured media request should parse deterministically")
        return
    }
    #expect(confidence >= 0.9)
    #expect(intent.domain == .remoteMedia)
    #expect(intent.targetFormat == .mp4)
    #expect(intent.quality == "1080p")
    #expect(intent.targetSizeBytes == 3_000_000)
}

@Test func semanticValueParserResolvesSpokenPagesTimeTargetsAndRenameNames() throws {
    #expect(SemanticValueParser.pageSelection(in: "take pages five through twelve") == Array(5...12))
    #expect(SemanticValueParser.pageSelection(in: "remove page seven") == [7])
    #expect(SemanticValueParser.pageSelection(in: "extract the first three pages") == [1, 2, 3])
    #expect(SemanticValueParser.pageSelection(in: "pages 4, 8 and 10") == [4, 8, 10])
    #expect(SemanticValueParser.targetSizeBytes(in: "compress below 3 megs") == 3_000_000)

    let clockRange = try #require(SemanticValueParser.videoRange(in: "from 1:20 to 2:45"))
    #expect(clockRange.startMilliseconds == 80_000)
    #expect(clockRange.durationMilliseconds == 85_000)
    let firstHalfMinute = try #require(SemanticValueParser.videoRange(in: "take the first 30 seconds"))
    #expect(firstHalfMinute.startMilliseconds == 0)
    #expect(firstHalfMinute.durationMilliseconds == 30_000)
    let spokenMinute = try #require(SemanticValueParser.videoRange(in: "starting at 30 seconds for one minute"))
    #expect(spokenMinute.startMilliseconds == 30_000)
    #expect(spokenMinute.durationMilliseconds == 60_000)
    #expect(SemanticValueParser.renameTarget(in: "rename this \"final submission\"") == "final submission")
    #expect(SemanticValueParser.renameTarget(in: "call this final") == "final")
    #expect(SemanticValueParser.renameTarget(in: "name it report-v2.pdf") == "report-v2.pdf")
}

@Test func pageActionsCompileNaturalTakeAndGetRidOfPhrasesDirectionally() throws {
    let pdf = try makeArtifact(name: "pages.pdf", kind: .pdf)
    let extracted = FastPathPlanner().plan(request: "take pages five through twelve", artifacts: [pdf])
    #expect(extracted.steps.first?.operation == .extractPDFPages)
    #expect(extracted.steps.first?.arguments == .removePages(indices: Array(5...12)))

    let removed = FastPathPlanner().plan(request: "get rid of page seven", artifacts: [pdf])
    #expect(removed.steps.first?.operation == .removePDFPages)
    #expect(removed.steps.first?.arguments == .removePages(indices: [7]))
}

@Test func tableDirectionAndAudioTargetRemainTyped() throws {
    let json = try makeArtifact(name: "data.json", kind: .table)
    let jsonToCSV = FastPathPlanner().plan(request: "convert this JSON to CSV", artifacts: [json])
    #expect(jsonToCSV.steps.map(\.operation) == [.jsonToCSV])
    let csv = try makeArtifact(name: "data.csv", kind: .csv)
    let csvToJSON = FastPathPlanner().plan(request: "turn this CSV into JSON", artifacts: [csv])
    #expect(csvToJSON.steps.map(\.operation) == [.csvToJSON])

    let video = try makeArtifact(name: "clip.mp4", kind: .video)
    for (request, format) in [("convert this video to mp3", AudioTargetFormat.mp3),
                              ("give me the audio as m4a", AudioTargetFormat.m4a),
                              ("turn this video into wav", AudioTargetFormat.wav),
                              ("extract the audio as flac", AudioTargetFormat.flac)] {
        let plan = FastPathPlanner().plan(request: request, artifacts: [video])
        #expect(plan.steps.map(\.operation) == [.convertAudio])
        #expect(plan.steps.first?.arguments == .audioConvert(format: format))
    }
}

@Test func negatedFormatRequestDoesNotCompileAConversion() throws {
    let image = try makeArtifact(name: "source.jpg", kind: .image)
    let plan = FastPathPlanner().plan(request: "don't convert this to PNG", artifacts: [image])
    #expect(plan.steps.isEmpty)
    #expect(plan.clarification != nil)
    #expect(SemanticIntentParser.explicitlyNegatesTransformation("don't convert this to PNG"))
    #expect(!SemanticIntentParser.explicitlyNegatesTransformation("convert this to PNG"))
}

@Test func artifactContextDisambiguatesGetAsMP3ForLocalVideoAndPublicURL() throws {
    let video = try makeArtifact(name: "local.mp4", kind: .video)
    let local = FastPathPlanner().plan(request: "get this as mp3", artifacts: [video])
    #expect(local.steps.map(\.operation) == [.convertAudio])
    #expect(local.steps.first?.arguments == .audioConvert(format: .mp3))

    let url = try makeArtifact(name: "media.kio-url", kind: .url)
    let remote = FastPathPlanner().plan(request: "get this as mp3", artifacts: [url])
    #expect(remote.steps.map(\.operation) == [.downloadRemoteAudio])
    #expect(remote.steps.first?.arguments == .remoteMedia(quality: nil, format: "mp3"))
}

@Test func imageFormatConversionCompilesResizeAndCompressionClausesAsFollowingSteps() throws {
    let image = try makeArtifact(name: "source.png", kind: .image)
    let resized = FastPathPlanner().plan(request: "convert this to jpeg and resize it to 1200 px", artifacts: [image])
    #expect(resized.steps.map(\.operation) == [.convertImage, .resizeImage])
    #expect(resized.steps[0].arguments == .imageConvert(format: "jpeg"))
    #expect(resized.steps[1].arguments == .imageResize(width: 1200))
    if case .previousStep(let id) = resized.steps[1].source { #expect(id == resized.steps[0].id) }
    else { Issue.record("The resize step must consume the converted image.") }

    let compressed = FastPathPlanner().plan(request: "convert this to jpeg under 1 MB", artifacts: [image])
    #expect(compressed.steps.map(\.operation) == [.convertImage, .compressImage])
    #expect(compressed.steps[1].arguments == .imageCompression(maxBytes: 1_000_000))
}

@Test func unsupportedCompoundClausesAndGeneralNegationNeverBecomePartialPlans() throws {
    let image = try makeArtifact(name: "source.png", kind: .image)
    let mixed = FastPathPlanner().plan(request: "convert this to jpeg and rename it final", artifacts: [image])
    #expect(mixed.steps.isEmpty)
    #expect(mixed.clarification != nil)
    let unboundedCompression = FastPathPlanner().plan(request: "convert this to jpeg and compress it", artifacts: [image])
    #expect(unboundedCompression.steps.isEmpty)
    #expect(unboundedCompression.clarification != nil)

    let folder = try makeArtifact(name: "folder", kind: .folder)
    let files = try makeArtifact(name: "a.txt", kind: .text)
    for request in ["don't move these files", "don’t delete page 7", "do not delete page 7", "don't remove page 7",
                    "don't rename this", "don't extract the audio", "don't download this", "don't convert this"] {
        let plan = FastPathPlanner().plan(request: request, artifacts: [files, folder])
        #expect(plan.steps.isEmpty, "\(request)")
        #expect(plan.clarification != nil, "\(request)")
        #expect(SemanticIntentParser.explicitlyNegatesAction(request), "\(request)")
    }
}

@Test func genericActionPolarityBlocksNegatedToolOperationsAndModelPlans() throws {
    #expect(SemanticIntentParser.requestsAction("copy", in: "copies these files", synonyms: ["duplicate"]))
    #expect(!SemanticIntentParser.requestsAction("copy", in: "do not copy these files", synonyms: ["duplicate"]))
    let text = try makeArtifact(name: "notes.txt", kind: .text)
    let pdf = try makeArtifact(name: "pages.pdf", kind: .pdf)
    let image = try makeArtifact(name: "photo.png", kind: .image)
    let audio = try makeArtifact(name: "voice.m4a", kind: .audio)
    let folder = try makeArtifact(name: "folder", kind: .folder)
    let files = try makeArtifact(name: "draft.txt", kind: .text)

    let cases: [(String, [ArtifactRef], String)] = [
        ("don't summarize this", [text], "summarize"),
        ("do not translate this", [text], "translate"),
        ("don't move these files", [files, folder], "move"),
        ("never remove page 7", [pdf], "remove"),
        ("don't crop this", [image], "crop"),
        ("don't transcribe this", [audio], "transcribe")
    ]
    for (request, artifacts, action) in cases {
        let plan = FastPathPlanner().plan(request: request, artifacts: artifacts)
        #expect(plan.steps.isEmpty, "\(request)")
        #expect(plan.clarification != nil, "\(request)")
        #expect(SemanticIntentParser.explicitlyNegatesAction(request), "\(request)")
        #expect(SemanticIntentParser.actionPolarities(in: request).first?.action == action, "\(request)")
        #expect(SemanticIntentParser.actionPolarities(in: request).first?.polarity == .prohibited, "\(request)")
    }

    let modelPlan = #"{"steps":[{"operation":"text.summarize","inputIndexes":[0],"arguments":{"request":"summarize this"}}]}"#
    #expect(ModelPlanDecoder.decode(modelPlan, request: "don't summarize this", artifacts: [text]) == nil)
    #expect(!ModelPlanDecoder.validationErrors(modelPlan, request: "don't summarize this", artifacts: [text]).isEmpty)
}

@Test func compoundTrimAndConversionCannotSilentlyDropEitherAction() throws {
    let video = try makeArtifact(name: "clip.mov", kind: .video)
    let plan = FastPathPlanner().plan(request: "trim this and convert it to mp4", artifacts: [video])
    #expect(plan.steps.isEmpty)
    #expect(plan.clarification != nil)
}

@Test func localVideoFormatsRemainTypedAndUnsupportedWebMSourceIsNotSelected() throws {
    let mp4 = try makeArtifact(name: "source.mp4", kind: .video)
    for format in [VideoTargetFormat.mp4, .mov, .mkv] {
        let plan = FastPathPlanner().plan(request: "convert this to \(format.rawValue)", artifacts: [mp4])
        #expect(plan.steps.first?.operation == .transcodeVideo)
        #expect(plan.steps.first?.arguments == .videoConvert(format: format))
    }
    let webm = FastPathPlanner().plan(request: "convert this to webm", artifacts: [mp4])
    #expect(webm.steps.isEmpty)
    #expect(webm.clarification != nil)
}

@Test func modelPlanDecoderKeepsTypedAudioFormatsAndInternalReelStatePrivate() throws {
    let video = try makeArtifact(name: "clip.webm", kind: .video)
    let audioPlan = #"{"steps":[{"operation":"audio.convert","inputIndexes":[0],"arguments":{"format":"mp3"}}]}"#
    #expect(ModelPlanDecoder.decode(audioPlan, request: "convert this video to mp3", artifacts: [video])?.steps.first?.arguments == .audioConvert(format: .mp3))

    let infoURL = FileManager.default.temporaryDirectory.appendingPathComponent("Kio-Internal-\(UUID().uuidString).kio-reel-info")
    try Data("{}".utf8).write(to: infoURL)
    defer { try? FileManager.default.removeItem(at: infoURL) }
    let internalInfo = try ArtifactRef.inspect(infoURL)
    #expect(internalInfo.kind == .other)
    #expect(internalInfo.role == .internalIntermediate)
    let summarize = #"{"steps":[{"operation":"text.summarize","inputIndexes":[0],"arguments":{"request":"summarize this"}}]}"#
    #expect(ModelPlanDecoder.decode(summarize, request: "summarize this", artifacts: [internalInfo]) == nil)
    let download = #"{"steps":[{"operation":"remoteMedia.downloadAudio","inputIndexes":[0],"arguments":{"format":"mp3"}}]}"#
    #expect(ModelPlanDecoder.decode(download, request: "download audio as mp3", artifacts: [internalInfo])?.steps.first?.operation == .downloadRemoteAudio)
}

@Test func mergeRequestSelectsRegisteredPDFOperation() throws {
    let a = try makeArtifact(name: "report.pdf", kind: .pdf)
    let b = try makeArtifact(name: "appendix.pdf", kind: .pdf)
    let plan = FastPathPlanner().plan(request: "Merge these PDFs", artifacts: [a, b])
    #expect(plan.steps.count == 1)
    #expect(plan.steps.first?.operation == .mergePDFs)
    #expect(plan.steps.first?.owner == .pip)
}

@Test func mixedPDFAndImageInputsUseOrderedCombinedPDFTool() throws {
    let image = try makeArtifact(name: "cover.png", kind: .image)
    let pdf = try makeArtifact(name: "report.pdf", kind: .pdf)
    let plan = FastPathPlanner().plan(
        request: "Combine these PDFs and images into one PDF",
        artifacts: [image, pdf]
    )
    #expect(plan.steps.map(\.operation) == [.combineMixedPDFInputs])
    #expect(plan.steps[0].source == .artifacts([image.id, pdf.id]))
    #expect(plan.steps[0].owner == .pip)
    #expect(FastPathPlanner.isCompatible(.combineMixedPDFInputs, inputKinds: [.image, .pdf]))
    #expect(!FastPathPlanner.isCompatible(.combineMixedPDFInputs, inputKinds: [.pdf, .pdf]))
}

@Test func contextualQuickActionsAreTypeSpecificAndShared() throws {
    let pdf = try makeArtifact(name: "report.pdf", kind: .pdf)
    let pdfActions = ContextualQuickActionCatalog.suggestions(for: [pdf])
    #expect(pdfActions.map(\.title).contains("Summarize"))
    #expect(pdfActions.map(\.title).contains("Pages…"))

    let image = try makeArtifact(name: "receipt.png", kind: .image)
    let imageActions = ContextualQuickActionCatalog.suggestions(for: [image])
    #expect(imageActions.map(\.title).contains("OCR"))
    #expect(imageActions.map(\.title).contains("Receipt"))
    #expect(ContextualQuickActionCatalog.suggestions(for: []).isEmpty)
}

@Test func unsupportedRequestDoesNotInventTools() throws {
    let image = try makeArtifact(name: "photo.png", kind: .image)
    let plan = FastPathPlanner().plan(request: "Make this look cinematic", artifacts: [image])
    #expect(plan.steps.isEmpty)
    #expect(plan.clarification != nil)
}

@Test func newSpecialistRosterAndDesignTokensAreRegistered() {
    #expect(Set([AgentID.scribe, .table, .lens, .scout, .patch]).isSubset(of: Set(AgentID.allCases)))
    #expect(AgentID.scribe.roleDescription.contains("text"))
    #expect(AgentID.table.roleDescription.contains("data"))
    #expect(AgentID.lens.colorHex != AgentID.scribe.colorHex)
    #expect(AgentID.scout.colorHex != AgentID.table.colorHex)
    #expect(AgentID.patch.colorHex != AgentID.kio.colorHex)
}

@Test func pixelSmartCropAndEchoClipConversionRouteToRegisteredOperations() throws {
    let image = try makeArtifact(name: "portrait.png", kind: .image)
    let crop = FastPathPlanner().plan(request: "Smart crop this around the subject", artifacts: [image])
    #expect(crop.steps.map(\.operation) == [.smartCropImage])
    #expect(crop.steps.first?.owner == .pixel)
    #expect(FastPathPlanner.hasValidArguments(.none, for: .smartCropImage))

    let video = try makeArtifact(name: "interview.mp4", kind: .video)
    let clip = FastPathPlanner().plan(request: "Extract clip from 2 seconds to 8 seconds", artifacts: [video])
    #expect(clip.steps.map(\.operation) == [.extractMediaClip])
    #expect(clip.steps.first?.owner == .echo)

    let audio = try makeArtifact(name: "voice.wav", kind: .audio)
    let convert = FastPathPlanner().plan(request: "Convert this audio", artifacts: [audio])
    #expect(convert.steps.isEmpty)
    #expect(convert.clarification?.contains("MP3, M4A, WAV, or FLAC") == true)
    #expect(FastPathPlanner.outputKinds(for: .convertAudio, inputKinds: [.audio]) == [.audio])
}

@Test func scribeRoutesTextAndPDFRequestsToRegisteredLocalOperations() throws {
    let text = try makeArtifact(name: "notes.md", kind: .text)
    let textPlan = FastPathPlanner().plan(request: "Summarize this", artifacts: [text])
    #expect(textPlan.steps.map(\.operation) == [.summarizeText])
    #expect(textPlan.steps.first?.owner == .scribe)
    #expect(textPlan.steps.first?.arguments == .textPrompt("Summarize this"))

    let pdf = try makeArtifact(name: "report.pdf", kind: .pdf)
    let pdfPlan = FastPathPlanner().plan(request: "Summarize this PDF", artifacts: [pdf])
    #expect(pdfPlan.steps.map(\.operation) == [.extractPDFText, .summarizeText])
    #expect(pdfPlan.steps.last?.source == .previousStep(pdfPlan.steps[0].id))
}

@Test func tableFastPathBuildsMergeDeduplicateAndStatisticsPipeline() throws {
    let first = try makeArtifact(name: "january.csv", kind: .csv)
    let second = try makeArtifact(name: "february.csv", kind: .csv)
    let plan = FastPathPlanner().plan(
        request: "Merge these, remove duplicate rows and tell me the average amount",
        artifacts: [first, second]
    )
    #expect(plan.steps.map(\.operation) == [.mergeData, .deduplicateData, .dataStatistics])
    #expect(plan.steps.allSatisfy { $0.owner == .table })
    #expect(plan.steps[1].source == .previousStep(plan.steps[0].id))
    #expect(plan.steps[2].source == .previousStep(plan.steps[1].id))
}

@Test func xlsxPlannerImportsBeforeTableOperations() throws {
    let workbook = try makeArtifact(name: "expenses.xlsx", kind: .table)
    let inspect = FastPathPlanner().plan(request: "Inspect this workbook", artifacts: [workbook])
    #expect(inspect.steps.map(\.operation) == [.importXLSX, .dataStatistics])
    #expect(inspect.steps[0].owner == .table)
    #expect(inspect.steps[1].source == .previousStep(inspect.steps[0].id))

    let csv = FastPathPlanner().plan(request: "Convert this workbook to CSV", artifacts: [workbook])
    #expect(csv.steps.map(\.operation) == [.importXLSX])
    #expect(FastPathPlanner.outputKinds(for: .importXLSX, inputKinds: [.table]) == [.csv])
}

@Test func clerkRoutesFolderSearchAndOrganizationByName() throws {
    let downloads = try makeArtifact(name: "Downloads", kind: .folder)
    let organizeDownloads = FastPathPlanner().plan(request: "Organize Downloads", artifacts: [downloads])
    #expect(organizeDownloads.steps.map(\.operation) == [.organizeDownloads])

    let recent = FastPathPlanner().plan(request: "Find recent files", artifacts: [downloads])
    #expect(recent.steps.map(\.operation) == [.findRecent])
    #expect(recent.steps[0].owner == .clerk)

    let csv = try makeArtifact(name: "Finance_invoice.csv", kind: .csv)
    let findName = FastPathPlanner().plan(request: "Find the file named invoice", artifacts: [csv])
    #expect(findName.steps.map(\.operation) == [.findByName])

    let module = FastPathPlanner().plan(request: "Organize these files by filename module prefix", artifacts: [csv])
    #expect(module.steps.map(\.operation) == [.organizeByModulePattern])
}

@Test func patchAndJSONFormatRequestsSelectTypedOperations() throws {
    let source = try makeArtifact(name: "sample.swift", kind: .text)
    let patchPlan = FastPathPlanner().plan(request: "Fix this bug in the code", artifacts: [source])
    #expect(patchPlan.steps.map(\.operation) == [.proposePatch])
    #expect(patchPlan.steps.first?.owner == .patch)

    let explainPlan = FastPathPlanner().plan(request: "Explain this code file", artifacts: [source])
    #expect(explainPlan.steps.map(\.operation) == [.explainCode])

    let json = try makeArtifact(name: "data.json", kind: .table)
    let formatPlan = FastPathPlanner().plan(request: "Format this JSON", artifacts: [json])
    #expect(formatPlan.steps.map(\.operation) == [.formatJSON])
    #expect(formatPlan.steps.first?.owner == .patch)
}

@Test func explicitCodeEditVerbsRouteToReviewablePatchWorkflow() throws {
    let source = try makeArtifact(name: "greeting.py", kind: .text)

    let addAnnotations = FastPathPlanner().plan(
        request: "Add string type annotations to this function and show me the proposed changes first.",
        artifacts: [source]
    )
    #expect(addAnnotations.steps.map(\.operation) == [.proposePatch])
    #expect(addAnnotations.steps.first?.source == .artifacts([source.id]))
    #expect(addAnnotations.steps.first?.arguments == .textPrompt("Add string type annotations to this function and show me the proposed changes first."))

    let refactor = FastPathPlanner().plan(request: "Refactor this function", artifacts: [source])
    #expect(refactor.steps.map(\.operation) == [.proposePatch])

    let explanation = FastPathPlanner().plan(request: "Explain what changes in this function", artifacts: [source])
    #expect(explanation.steps.map(\.operation) == [.explainCode])
}

@Test func echoRoutesLocalTranscriptsAndSubtitlesForAudioAndVideo() throws {
    let audio = try makeArtifact(name: "meeting.m4a", kind: .audio)
    let transcript = FastPathPlanner().plan(request: "Transcribe this audio", artifacts: [audio])
    let subtitles = FastPathPlanner().plan(request: "Generate subtitles for this audio", artifacts: [audio])
    #expect(transcript.steps.map(\.operation) == [.transcribeAudio])
    #expect(transcript.steps.first?.owner == .echo)
    #expect(subtitles.steps.map(\.operation) == [.generateSubtitles])

    let video = try makeArtifact(name: "clip.mp4", kind: .video)
    let videoSubtitles = FastPathPlanner().plan(request: "Create VTT subtitles for this video", artifacts: [video])
    #expect(videoSubtitles.steps.map(\.operation) == [.extractAudio, .generateSubtitles])
    #expect(videoSubtitles.steps[1].source == .previousStep(videoSubtitles.steps[0].id))
}

@Test func pipRoutesTargetedPDFPhraseSearch() throws {
    let pdf = try makeArtifact(name: "research.pdf", kind: .pdf)
    let plan = FastPathPlanner().plan(request: "Where does this mention branch-and-bound?", artifacts: [pdf])
    #expect(plan.steps.map(\.operation) == [.searchPDFText])
    #expect(plan.steps.first?.owner == .pip)
    #expect(plan.steps.first?.arguments == .textPrompt("Where does this mention branch-and-bound?"))
}

@Test func pixelRoutesBatchActionsAndImageComparisons() throws {
    let first = try makeArtifact(name: "first.png", kind: .image)
    let second = try makeArtifact(name: "second.png", kind: .image)
    let resize = FastPathPlanner().plan(request: "Resize these images to 800 pixels wide", artifacts: [first, second])
    let convert = FastPathPlanner().plan(request: "Convert these images to PNG", artifacts: [first, second])
    let compare = FastPathPlanner().plan(request: "Compare these images", artifacts: [first, second])
    let similar = FastPathPlanner().plan(request: "Find similar images", artifacts: [first, second])
    let background = FastPathPlanner().plan(request: "Remove the background from this image", artifacts: [first])
    #expect(resize.steps.first?.operation == .batchResizeImages)
    #expect(convert.steps.first?.operation == .batchConvertImages)
    #expect(compare.steps.first?.operation == .compareImages)
    #expect(similar.steps.first?.operation == .findSimilarImages)
    #expect(background.steps.first?.operation == .removeImageBackground)
}

@Test func artifactContextResolvesOrdinalsLatestKindsAndAsksWhenAmbiguous() throws {
    let firstPDF = try makeArtifact(name: "first.pdf", kind: .pdf)
    let secondPDF = try makeArtifact(name: "second.pdf", kind: .pdf)
    let table = try makeArtifact(name: "receipt.csv", kind: .csv)
    let now = Date.now
    let history = [
        ArtifactContextEntry(artifact: firstPDF, operation: .mergePDFs, speaker: "Pip", createdAt: now.addingTimeInterval(-30)),
        ArtifactContextEntry(artifact: secondPDF, operation: .removePDFPages, speaker: "Pip", createdAt: now.addingTimeInterval(-20)),
        ArtifactContextEntry(artifact: table, operation: .extractReceipt, speaker: "Lens", createdAt: now.addingTimeInterval(-10))
    ]
    let resolver = ArtifactContextResolver()
    if case .resolved(let artifact) = resolver.resolve(request: "Use the second one", history: history, mostRecentTaskResults: Array(history.prefix(2))) {
        #expect(artifact.id == secondPDF.id)
    } else { Issue.record("Expected the second local result to resolve") }
    if case .resolved(let artifact) = resolver.resolve(request: "Use the latest PDF", history: history, mostRecentTaskResults: [history[2]]) {
        #expect(artifact.id == secondPDF.id)
    } else { Issue.record("Expected the latest PDF to resolve") }
    if case .resolved(let artifact) = resolver.resolve(request: "Find the CSV from the receipt", history: history, mostRecentTaskResults: [history[2]]) {
        #expect(artifact.id == table.id)
    } else { Issue.record("Expected the receipt table to resolve") }
    if case .clarify(let question) = resolver.resolve(request: "Use the PDF Pip made", history: history, mostRecentTaskResults: []) {
        #expect(question.contains("first.pdf"))
        #expect(question.contains("second.pdf"))
    } else { Issue.record("Expected an ambiguous PDF reference to ask which file") }
}

@Test func artifactContextFiltersRecentResultsByAgentOperationAndDate() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12)))
    let today = calendar.startOfDay(for: now)
    let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
    let yesterdayMorning = try #require(calendar.date(byAdding: .hour, value: 9, to: yesterday))
    let todayMorning = try #require(calendar.date(byAdding: .hour, value: 9, to: today))
    let oldCompressed = try makeArtifact(name: "old-compressed.pdf", kind: .pdf)
    let todayCompressed = try makeArtifact(name: "today-compressed.pdf", kind: .pdf)
    let todayReceipt = try makeArtifact(name: "today-receipt.pdf", kind: .pdf)
    let history = [
        ArtifactContextEntry(artifact: oldCompressed, operation: .compressPDF, speaker: "Zip", createdAt: yesterdayMorning),
        ArtifactContextEntry(artifact: todayCompressed, operation: .compressPDF, speaker: "Zip", createdAt: todayMorning),
        ArtifactContextEntry(artifact: todayReceipt, operation: .extractReceipt, speaker: "Lens", createdAt: todayMorning)
    ]
    let resolver = ArtifactContextResolver()

    if case .resolved(let artifact) = resolver.resolve(
        request: "Find the PDF Zip compressed yesterday", history: history,
        mostRecentTaskResults: [], now: now, calendar: calendar
    ) {
        #expect(artifact.id == oldCompressed.id)
    } else { Issue.record("Expected date, producing agent, and operation filters to select the old compressed PDF") }

    if case .resolved(let artifact) = resolver.resolve(
        request: "Use the PDF Lens extracted a receipt today", history: history,
        mostRecentTaskResults: [], now: now, calendar: calendar
    ) {
        #expect(artifact.id == todayReceipt.id)
    } else { Issue.record("Expected today's receipt PDF from Lens to resolve") }

    if case .clarify = resolver.resolve(
        request: "Use the PDF Zip compressed yesterday", history: [history[1]],
        mostRecentTaskResults: [], now: now, calendar: calendar
    ) {
        #expect(true)
    } else { Issue.record("Expected an unavailable dated result to request clarification") }
}

@Test func conversationHistorySearchMatchesFilenameDateOperationAndAgent() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12)))
    let startOfToday = calendar.startOfDay(for: now)
    let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: startOfToday))
    let yesterdayMorning = try #require(calendar.date(byAdding: .hour, value: 10, to: yesterday))
    let todayMorning = try #require(calendar.date(byAdding: .hour, value: 9, to: startOfToday))
    let receipt = try makeArtifact(name: "client-receipt.pdf", kind: .pdf)
    let research = try makeArtifact(name: "research.pdf", kind: .pdf)
    let oldReceiptID = UUID()
    let todayReceiptID = UUID()
    let researchID = UUID()
    let records = [
        ConversationHistoryRecord(id: oldReceiptID, speaker: "Zip", message: "Compressed the receipt PDF.", artifact: receipt, operation: .compressPDF, createdAt: yesterdayMorning),
        ConversationHistoryRecord(id: todayReceiptID, speaker: "Zip", message: "Compressed the receipt PDF.", artifact: receipt, operation: .compressPDF, createdAt: todayMorning),
        ConversationHistoryRecord(id: researchID, speaker: "Pip", message: "Inspected the research PDF.", artifact: research, operation: .inspectPDF, createdAt: yesterdayMorning)
    ]

    #expect(ConversationHistorySearch.filter(records, query: "client-receipt", now: now, calendar: calendar).map(\.id) == [oldReceiptID, todayReceiptID])
    #expect(ConversationHistorySearch.filter(records, query: "Find the compressed PDF from yesterday", now: now, calendar: calendar).map(\.id) == [oldReceiptID])
    #expect(ConversationHistorySearch.filter(records, query: "Find the PDF Pip inspected yesterday", now: now, calendar: calendar).map(\.id) == [researchID])
}

@Test func clipboardInputResolverClassifiesTextURLImageAndFileWithoutReadingThePasteboard() {
    let fileURL = URL(fileURLWithPath: "/tmp/clipboard-report.pdf")
    let image = Data([0x89, 0x50, 0x4e, 0x47])

    #expect(ClipboardInputResolver.resolve(fileURLs: [], imageData: nil, urlString: nil, text: "Notes to summarize") == .text("Notes to summarize"))
    #expect(ClipboardInputResolver.resolve(fileURLs: [], imageData: nil, urlString: nil, text: "https://example.com/report") == .webURL("https://example.com/report"))
    #expect(ClipboardInputResolver.resolve(fileURLs: [], imageData: image, urlString: nil, text: "ignored while an image is pasted") == .image(image))
    #expect(ClipboardInputResolver.resolve(fileURLs: [fileURL], imageData: image, urlString: nil, text: nil) == .files([fileURL]))
    #expect(ClipboardInputResolver.resolve(fileURLs: [], imageData: nil, urlString: "javascript:alert(1)", text: nil) == nil)
}

@Test func clipboardComposerKeepsPastedTextSeparateFromItsTaskInstruction() {
    let pasted = "Maya will send the draft by Friday."
    let submission = ClipboardComposerResolver.resolve(message: "Summarize this:\n\(pasted)", pastedTexts: [pasted])
    #expect(submission.request == "Summarize this")
    #expect(submission.pastedText == pasted)

    let multiple = ClipboardComposerResolver.resolve(message: "\(pasted)\nRewrite this more formally", pastedTexts: [pasted])
    #expect(multiple.request == "Rewrite this more formally")
    #expect(multiple.pastedText == pasted)

    let untouched = ClipboardComposerResolver.resolve(message: "Summarize this file", pastedTexts: ["different clipboard content"])
    #expect(untouched.request == "Summarize this file")
    #expect(untouched.pastedText == nil)
}

@Test func inlineTextSubmissionSeparatesOnlyExplicitBoundedTextSources() {
    let summary = InlineTextSubmissionResolver.resolve(
        message: "Summarize this note in three bullets: Kio keeps documents on the Mac. Scribe makes concise summaries."
    )
    #expect(summary?.request == "Summarize this note in three bullets")
    #expect(summary?.pastedText == "Kio keeps documents on the Mac. Scribe makes concise summaries.")

    let multiline = InlineTextSubmissionResolver.resolve(message: "Rewrite this more formally\nThe meeting starts at noon.")
    #expect(multiline?.request == "Rewrite this more formally")
    #expect(multiline?.pastedText == "The meeting starts at noon.")

    #expect(InlineTextSubmissionResolver.resolve(message: "Summarize https://example.com") == nil)
    #expect(InlineTextSubmissionResolver.resolve(message: "Move this file: report.pdf") == nil)
    #expect(InlineTextSubmissionResolver.resolve(message: "Summarize this note:") == nil)
}

@Test func workflowTemplatesSaveTypedGraphsRebindInputsAndRejectIncompatibleFiles() throws {
    let originalA = try makeArtifact(name: "one.csv", kind: .csv)
    let originalB = try makeArtifact(name: "two.csv", kind: .csv)
    let merge = TaskStep(operation: .mergeData, source: .artifacts([originalA.id, originalB.id]))
    let deduplicate = TaskStep(operation: .deduplicateData, source: .previousStep(merge.id))
    let task = TaskPlan(request: "Merge and deduplicate", steps: [merge, deduplicate])
    let suite = "KioWorkflowTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = WorkflowTemplateStore(key: "templates", defaults: defaults)

    let saved = try store.save(name: "Clean tables", plan: task, inputs: [originalA, originalB])
    let template = try #require(saved.first)
    let encoded = String(decoding: try #require(defaults.data(forKey: "templates")), as: UTF8.self)
    #expect(!encoded.contains(originalA.fileURL.path))
    #expect(WorkflowTemplateStore.requestedName(in: "Run Clean tables on these.") == "Clean tables")

    let nextA = try makeArtifact(name: "three.csv", kind: .csv)
    let nextB = try makeArtifact(name: "four.csv", kind: .csv)
    let replay = try store.instantiate(template, request: "Run Clean tables on these", inputs: [nextA, nextB])
    #expect(replay.steps.count == 2)
    #expect(replay.steps[0].source == .artifacts([nextA.id, nextB.id]))
    #expect(replay.steps[1].source == .previousStep(replay.steps[0].id))

    let wrong = try makeArtifact(name: "photo.png", kind: .image)
    #expect(throws: (any Error).self) { try store.instantiate(template, request: "Run Clean tables", inputs: [nextA, wrong]) }
    #expect(try store.rename(id: template.id, to: "Expenses").first?.name == "Expenses")
    #expect(try store.delete(id: template.id).isEmpty)
}

@Test func workflowTemplatesCanBeListedForTheMobileClientWithoutModelPlanning() {
    #expect(WorkflowTemplateStore.isListingRequest("List my saved workflow templates"))
    #expect(WorkflowTemplateStore.isListingRequest("Show workflows"))
    #expect(!WorkflowTemplateStore.isListingRequest("Run Clean PDF on these"))
    let template = WorkflowTemplate(name: "Clean PDF", inputKinds: [.pdf, .pdf], steps: [
        WorkflowTemplateStep(operation: .mergePDFs, source: .inputs([0, 1]), arguments: .none)
    ])
    let reply = WorkflowTemplateStore.listingReply(for: [template])
    #expect(reply.contains("Clean PDF"))
    #expect(reply.contains("1 step"))
    #expect(WorkflowTemplateStore.listingReply(for: []).contains("don't have any saved workflow templates"))
}

@Test func tableFastPathExtractsSortAndFilterArguments() throws {
    let csv = try makeArtifact(name: "expenses.csv", kind: .csv)
    let sort = FastPathPlanner().plan(request: "Sort by amount descending", artifacts: [csv])
    let filter = FastPathPlanner().plan(request: "Filter where status is paid", artifacts: [csv])
    #expect(sort.steps.first?.operation == .sortData)
    #expect(sort.steps.first?.arguments == .tableSort(column: "amount", ascending: false))
    #expect(filter.steps.first?.operation == .filterData)
    #expect(filter.steps.first?.arguments == .tableFilter(column: "status", value: "paid"))
}

@Test func modelPlanDecoderAcceptsTypedTableOperationsAndRejectsInvalidColumns() throws {
    let csv = try makeArtifact(name: "expenses.csv", kind: .csv)
    let sort = #"{"steps":[{"operation":"data.sort","inputIndexes":[0],"arguments":{"column":"amount","ascending":false}}]}"#
    #expect(ModelPlanDecoder.decode(sort, request: "Sort by amount", artifacts: [csv])?.steps.first?.arguments == .tableSort(column: "amount", ascending: false))
    let invalid = #"{"steps":[{"operation":"data.sort","inputIndexes":[0],"arguments":{"column":"","ascending":false}}]}"#
    #expect(ModelPlanDecoder.decode(invalid, request: "Sort by amount", artifacts: [csv]) == nil)
}

@Test func scribeComparisonRequiresAndAcceptsTwoSources() throws {
    let first = try makeArtifact(name: "one.md", kind: .text)
    let second = try makeArtifact(name: "two.md", kind: .text)
    let plan = FastPathPlanner().plan(request: "Compare these", artifacts: [first, second])
    #expect(plan.steps.first?.operation == .compareText)
    #expect(plan.steps.first?.source == .artifacts([first.id, second.id]))
    #expect(FastPathPlanner().plan(request: "Compare these", artifacts: [first]).steps.isEmpty)

    let wire = #"{"steps":[{"operation":"text.compare","inputIndexes":[0,1],"arguments":{}}]}"#
    #expect(ModelPlanDecoder.decode(wire, request: "Compare these", artifacts: [first, second])?.steps.first?.owner == .scribe)
}

@Test func fastResponseAnswersMacOnlineQuestionsWithoutAFilePlan() {
    let resolver = FastPathResponseResolver()
    #expect(resolver.response(to: "Is my Mac online?") == "Your Mac is online—it received this request just now.")
    #expect(resolver.response(to: "Check whether my Mac is online") == "Your Mac is online—it received this request just now.")
    #expect(resolver.response(to: "Make my Mac online") == nil)
}

@Test func scoutResearchUsesOnlyTheTypedInternalQueryAndKeepsScribeCompositionOptional() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KioResearchPlan-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let queryURL = directory.appendingPathComponent("topic.kio-query")
    try Data("perovskite solar stability".utf8).write(to: queryURL)
    let query = try ArtifactRef.inspect(queryURL)

    let search = FastPathPlanner().plan(request: "Find research papers about perovskite solar stability", artifacts: [query])
    #expect(search.steps.map(\.operation) == [.researchOpenSources])
    #expect(search.steps.first?.owner == .scout)
    #expect(FastPathPlanner.outputKinds(for: .researchOpenSources, inputKinds: [.url]) == [.text])

    let wire = #"{"steps":[{"operation":"web.researchOpenSources","inputIndexes":[0],"arguments":{}}]}"#
    #expect(ModelPlanDecoder.decode(wire, request: "Find research papers about perovskite solar stability", artifacts: [query])?.steps.first?.owner == .scout)
    let ordinaryURL = try makeArtifact(name: "article.kio-url", kind: .url)
    #expect(ModelPlanDecoder.decode(wire, request: "Research this", artifacts: [ordinaryURL]) == nil)
}

@Test func plannerSummaryDoesNotContainLocalPath() throws {
    let artifact = try makeArtifact(name: "report.pdf", kind: .pdf)
    let encoded = String(decoding: try JSONEncoder().encode(artifact.plannerSummary), as: UTF8.self)
    #expect(!encoded.contains(artifact.fileURL.path))
    #expect(encoded.contains("report.pdf"))
}

@Test func mergeWithSizeTargetBuildsMergeThenCompressionPipeline() throws {
    let a = try makeArtifact(name: "report.pdf", kind: .pdf)
    let b = try makeArtifact(name: "appendix.pdf", kind: .pdf)
    let plan = FastPathPlanner().plan(request: "Merge these PDFs and make the result under 3 MB", artifacts: [a, b])
    #expect(plan.steps.map(\.operation) == [.mergePDFs, .compressPDF])
    #expect(plan.steps.last?.source == .previousStep(plan.steps[0].id))
    #expect(plan.steps.last?.arguments == .pdfCompression(maxBytes: 3_000_000))
}

@Test func removePageRangeTargetsInclusivePages() throws {
    let pdf = try makeArtifact(name: "handout.pdf", kind: .pdf)
    let plan = FastPathPlanner().plan(request: "Remove pages 4 through 7", artifacts: [pdf])
    #expect(plan.steps.first?.operation == .removePDFPages)
    #expect(plan.steps.first?.arguments == .removePages(indices: [4, 5, 6, 7]))
}

@Test func removeDistinctPagesDoesNotExpandToAnAccidentalRange() throws {
    let pdf = try makeArtifact(name: "handout.pdf", kind: .pdf)
    let plan = FastPathPlanner().plan(request: "Remove pages 2 and 4", artifacts: [pdf])
    #expect(plan.steps.first?.arguments == .removePages(indices: [2, 4]))
}

@Test func resizePlannerSelectsTheWidthFromAnOrderedRequest() throws {
    let image = try makeArtifact(name: "photo.png", kind: .image)
    let plan = FastPathPlanner().plan(request: "Resize image 2 to 1200 pixels wide", artifacts: [image])
    #expect(plan.steps.first?.arguments == .imageResize(width: 1200))
}

@Test func pipAndPixelInspectionAndRotationRequestsUseRegisteredTools() throws {
    let pdf = try makeArtifact(name: "report.pdf", kind: .pdf)
    let image = try makeArtifact(name: "photo.png", kind: .image)

    let split = FastPathPlanner().plan(request: "Split this PDF into pages", artifacts: [pdf])
    let inspectPDF = FastPathPlanner().plan(request: "Inspect this PDF", artifacts: [pdf])
    let rotatePDF = FastPathPlanner().plan(request: "Rotate pages 2-3 90 degrees", artifacts: [pdf])
    let rotateImage = FastPathPlanner().plan(request: "Rotate this image clockwise", artifacts: [image])
    let rotateCounterclockwise = FastPathPlanner().plan(request: "Rotate this image counter clockwise", artifacts: [image])
    let inspectImage = FastPathPlanner().plan(request: "Inspect this image", artifacts: [image])

    #expect(split.steps.first?.operation == .splitPDF)
    #expect(inspectPDF.steps.first?.operation == .inspectPDF)
    #expect(rotatePDF.steps.first?.operation == .rotatePDFPages)
    #expect(rotatePDF.steps.first?.arguments == .pdfRotation(indices: [2, 3], degrees: 90))
    #expect(rotateImage.steps.first?.operation == .rotateImage)
    #expect(rotateImage.steps.first?.arguments == .imageRotation(degrees: 90))
    #expect(rotateCounterclockwise.steps.first?.arguments == .imageRotation(degrees: 270))
    #expect(inspectImage.steps.first?.operation == .inspectImage)
}

@Test func imageRotationRequiresDirectionOrAngle() throws {
    let image = try makeArtifact(name: "photo.png", kind: .image)
    let plan = FastPathPlanner().plan(request: "Rotate this image", artifacts: [image])
    #expect(plan.steps.isEmpty)
    #expect(plan.clarification != nil)
}

@Test func archiveExtractionAndInspectionUseRegisteredZIPOperations() throws {
    let zip = try makeArtifact(name: "archive.zip", kind: .other)
    let inspect = FastPathPlanner().plan(request: "Inspect this ZIP", artifacts: [zip])
    let extract = FastPathPlanner().plan(request: "Extract this ZIP", artifacts: [zip])
    #expect(inspect.steps.first?.operation == .inspectArchive)
    #expect(extract.steps.first?.operation == .extractZip)
    #expect(extract.steps.first?.owner == .zip)
}

@Test func scannedPDFOCRUsesBoundedRegisteredPipTool() throws {
    let pdf = try makeArtifact(name: "scan.pdf", kind: .pdf)
    let plan = FastPathPlanner().plan(request: "OCR this scanned PDF", artifacts: [pdf])
    #expect(plan.steps.first?.operation == .ocrPDFText)
    #expect(plan.steps.first?.owner == .pip)
    let wire = #"{"steps":[{"operation":"pdf.ocrText","inputIndexes":[0],"arguments":{}}]}"#
    #expect(ModelPlanDecoder.decode(wire, request: "OCR", artifacts: [pdf])?.steps.first?.operation == .ocrPDFText)
}

@Test func lensRoutesOCRReceiptAndTableImagesToTypedOperations() throws {
    let image = try makeArtifact(name: "receipt.png", kind: .image)
    let ocr = FastPathPlanner().plan(request: "Extract the text from this image", artifacts: [image])
    let receipt = FastPathPlanner().plan(request: "Turn this receipt into a CSV row", artifacts: [image])
    let table = FastPathPlanner().plan(request: "Extract the table rows and columns", artifacts: [image])
    #expect(ocr.steps.map(\.operation) == [.ocrImage])
    #expect(receipt.steps.map(\.operation) == [.extractReceipt])
    #expect(table.steps.map(\.operation) == [.extractImageTable])
    #expect(Set([ocr.steps[0].owner, receipt.steps[0].owner, table.steps[0].owner]) == [.lens])

    let wire = #"{"steps":[{"operation":"visual.extractReceipt","inputIndexes":[0],"arguments":{}}]}"#
    #expect(ModelPlanDecoder.decode(wire, request: "extract receipt fields", artifacts: [image])?.steps.first?.owner == .lens)
}

@Test func pixelTaskPlannerSelectsCropCompressionAndContactSheetTools() throws {
    let first = try makeArtifact(name: "first.png", kind: .image)
    let second = try makeArtifact(name: "second.png", kind: .image)
    let crop = FastPathPlanner().plan(request: "Crop x=10 y=20 width=300 height=200", artifacts: [first])
    let compress = FastPathPlanner().plan(request: "Compress this image under 2 MB", artifacts: [first])
    let contact = FastPathPlanner().plan(request: "Make a contact sheet", artifacts: [first, second])
    #expect(crop.steps.first?.operation == .cropImage)
    #expect(crop.steps.first?.arguments == .imageCrop(x: 10, y: 20, width: 300, height: 200))
    #expect(compress.steps.first?.operation == .compressImage)
    #expect(compress.steps.first?.arguments == .imageCompression(maxBytes: 2_000_000))
    #expect(contact.steps.first?.operation == .imageContactSheet)
}

@Test func pipPlannerSelectsBlankPageRemovalAndCompletePageOrder() throws {
    let pdf = try makeArtifact(name: "report.pdf", kind: .pdf)
    let blank = FastPathPlanner().plan(request: "Remove blank pages", artifacts: [pdf])
    let reorder = FastPathPlanner().plan(request: "Reorder pages 3, 1, 2", artifacts: [pdf])
    #expect(blank.steps.first?.operation == .removeBlankPDFPages)
    #expect(reorder.steps.first?.operation == .reorderPDFPages)
    #expect(reorder.steps.first?.arguments == .pageOrder(indices: [3, 1, 2]))
    let wire = #"{"steps":[{"operation":"pdf.reorderPages","inputIndexes":[0],"arguments":{"pages":[3,1,2]}}]}"#
    #expect(ModelPlanDecoder.decode(wire, request: "reorder", artifacts: [pdf])?.steps.first?.arguments == .pageOrder(indices: [3, 1, 2]))
    let duplicatePages = #"{"steps":[{"operation":"pdf.reorderPages","inputIndexes":[0],"arguments":{"pages":[1,1,3]}}]}"#
    #expect(ModelPlanDecoder.decode(duplicatePages, request: "reorder", artifacts: [pdf]) == nil)
}

@Test func echoPlannerAndDecoderUseBoundedNativeMediaOperations() throws {
    let video = try makeArtifact(name: "clip.mov", kind: .video)
    let inspect = FastPathPlanner().plan(request: "Inspect this video", artifacts: [video])
    let thumbnail = FastPathPlanner().plan(request: "Make a thumbnail at 2.5 seconds", artifacts: [video])
    let trim = FastPathPlanner().plan(request: "Trim from 2 seconds to 8 seconds", artifacts: [video])
    let resize = FastPathPlanner().plan(request: "Resize video to 960 pixels wide", artifacts: [video])
    let transcode = FastPathPlanner().plan(request: "Transcode this video", artifacts: [video])
    let compress = FastPathPlanner().plan(request: "Compress this video under 10 MB", artifacts: [video])

    #expect(inspect.steps.first?.operation == .inspectMedia)
    #expect(thumbnail.steps.first?.arguments == .mediaThumbnail(timeMilliseconds: 2_500))
    #expect(trim.steps.first?.arguments == .mediaTrim(startMilliseconds: 2_000, durationMilliseconds: 6_000))
    #expect(resize.steps.first?.arguments == .mediaResize(width: 960))
    #expect(transcode.steps.first?.operation == .transcodeVideo)
    #expect(compress.steps.first?.arguments == .mediaCompression(maxBytes: 10_000_000))

    let wire = #"{"steps":[{"operation":"media.trim","inputIndexes":[0],"arguments":{"startMs":2000,"durationMs":6000}}]}"#
    #expect(ModelPlanDecoder.decode(wire, request: "trim", artifacts: [video])?.steps.first?.arguments == .mediaTrim(startMilliseconds: 2_000, durationMilliseconds: 6_000))
    let badResize = #"{"steps":[{"operation":"media.resizeVideo","inputIndexes":[0],"arguments":{"width":1920}}]}"#
    #expect(ModelPlanDecoder.decode(badResize, request: "resize", artifacts: [video]) == nil)
}

@Test func clerkPlannerRequiresExplicitCopyMoveAndDestinationFolder() throws {
    let file = try makeArtifact(name: "report.pdf", kind: .pdf)
    let folder = try makeArtifact(name: "Destination", kind: .folder)
    let copy = FastPathPlanner().plan(request: "Copy these files into the selected folder", artifacts: [file, folder])
    let move = FastPathPlanner().plan(request: "Move these files into the selected folder", artifacts: [file, folder])
    let find = FastPathPlanner().plan(request: "Find duplicate files", artifacts: [file, try makeArtifact(name: "copy.pdf", kind: .pdf)])
    let organizeType = FastPathPlanner().plan(request: "Organize these files by type", artifacts: [file])
    let organizeDate = FastPathPlanner().plan(request: "Organize these files by date", artifacts: [file])
    #expect(copy.steps.first?.operation == .copyFiles)
    #expect(copy.steps.first?.source == .artifacts([file.id, folder.id]))
    #expect(move.steps.first?.operation == .moveFiles)
    #expect(find.steps.first?.operation == .findDuplicates)
    #expect(organizeType.steps.first?.operation == .organizeByType)
    #expect(organizeDate.steps.first?.operation == .organizeByDate)

    let inventedMove = #"{"steps":[{"operation":"file.move","inputIndexes":[0,1],"arguments":{}}]}"#
    #expect(ModelPlanDecoder.decode(inventedMove, request: "Organize these files by type", artifacts: [file, folder]) == nil)
    #expect(ModelPlanDecoder.decode(inventedMove, request: "Move these files into this folder", artifacts: [file, folder])?.steps.first?.operation == .moveFiles)
}

@Test func modelPlanDecoderAcceptsOnlyTypedRegisteredWorkflow() throws {
    let first = try makeArtifact(name: "report.pdf", kind: .pdf)
    let second = try makeArtifact(name: "appendix.pdf", kind: .pdf)
    let mergeOnly = #"{"steps":[{"operation":"pdf.merge","inputIndexes":[0,1],"arguments":{}}]}"#
    #expect(ModelPlanDecoder.decode(mergeOnly, request: "Merge", artifacts: [first, second]) != nil)
    let response = #"{"steps":[{"operation":"pdf.merge","inputIndexes":[0,1],"arguments":{}},{"operation":"pdf.compress","previousStepIndex":0,"arguments":{"maxBytes":3000000}}],"clarification":null}"#

    let plan = try #require(ModelPlanDecoder.decode(response, request: "Merge and compress", artifacts: [first, second]))

    #expect(plan.steps.map(\.operation) == [.mergePDFs, .compressPDF])
    #expect(plan.steps[1].source == .previousStep(plan.steps[0].id))
    #expect(plan.steps[1].arguments == .pdfCompression(maxBytes: 3_000_000))
}

@Test func modelPlanDecoderRejectsInventedToolsAndInvalidArtifactIndexes() throws {
    let pdf = try makeArtifact(name: "report.pdf", kind: .pdf)
    let invented = #"{"steps":[{"operation":"shell.execute","inputIndexes":[0],"arguments":{}}]}"#
    let missingInput = #"{"steps":[{"operation":"pdf.compress","inputIndexes":[9],"arguments":{}}]}"#

    #expect(ModelPlanDecoder.decode(invented, request: "do this", artifacts: [pdf]) == nil)
    #expect(ModelPlanDecoder.decode(missingInput, request: "do this", artifacts: [pdf]) == nil)
}

@Test func modelPlanDecoderRejectsOutOfBoundsTypedArguments() throws {
    let image = try makeArtifact(name: "photo.png", kind: .image)
    let invalidWidth = #"{"steps":[{"operation":"image.resize","inputIndexes":[0],"arguments":{"width":999999}}]}"#

    #expect(ModelPlanDecoder.decode(invalidWidth, request: "resize", artifacts: [image]) == nil)
}

@Test func sizeFollowUpTargetsTheMostRecentPDF() throws {
    let result = try makeArtifact(name: "report-Merged.pdf", kind: .pdf)
    let plan = FastPathPlanner().plan(request: "Make it under 2 MB", artifacts: [], context: PlanningContext(activeOutput: result))
    #expect(plan.steps.count == 1)
    #expect(plan.steps[0].operation == .compressPDF)
    #expect(plan.steps[0].source == .artifacts([result.id]))
}

@Test func exactRenameFollowUpUsesTheRequestedNameAndRetainsExtension() throws {
    let result = try makeArtifact(name: "image-Images.pdf", kind: .pdf)
    let plan = FastPathPlanner().plan(request: "Rename it Kio-Mobile-Followup", artifacts: [], context: PlanningContext(activeOutput: result))

    #expect(plan.steps.count == 1)
    #expect(plan.steps[0].operation == .renameFile)
    #expect(plan.steps[0].owner == .clerk)
    #expect(plan.steps[0].source == .artifacts([result.id]))
    #expect(plan.steps[0].arguments == .exactRename(name: "Kio-Mobile-Followup"))
}

@Test func exactRenamePlannerReadsExplicitFileName() throws {
    let result = try makeArtifact(name: "report.pdf", kind: .pdf)
    let plan = FastPathPlanner().plan(request: "Rename the PDF you just made to final-submission.pdf.", artifacts: [result])
    #expect(plan.steps.first?.arguments == .exactRename(name: "final-submission.pdf"))
}

@Test func sameToTheseReusesOnlyThePreviouslyValidatedOperationAndArguments() throws {
    let original = try makeArtifact(name: "first.png", kind: .image)
    let selected = try makeArtifact(name: "second.png", kind: .image)
    let prior = TaskPlan(request: "Resize to 800 pixels", steps: [
        TaskStep(operation: .resizeImage, source: .artifacts([original.id]), arguments: .imageResize(width: 800))
    ])
    let plan = FastPathPlanner().plan(request: "Do the same to these files", artifacts: [selected],
                                      context: PlanningContext(activeOutput: original, previousOperation: .resizeImage, previousPlan: prior))
    #expect(plan.steps.count == 1)
    #expect(plan.steps[0].operation == .resizeImage)
    #expect(plan.steps[0].source == .artifacts([selected.id]))
    #expect(plan.steps[0].arguments == .imageResize(width: 800))
}

@Test func sameToTheseRebuildsSafeMergeAndCompressionPipeline() throws {
    let oldA = try makeArtifact(name: "old-a.pdf", kind: .pdf)
    let oldB = try makeArtifact(name: "old-b.pdf", kind: .pdf)
    let newA = try makeArtifact(name: "new-a.pdf", kind: .pdf)
    let newB = try makeArtifact(name: "new-b.pdf", kind: .pdf)
    let oldMerge = TaskStep(operation: .mergePDFs, source: .artifacts([oldA.id, oldB.id]))
    let oldCompress = TaskStep(operation: .compressPDF, source: .previousStep(oldMerge.id),
                               arguments: .pdfCompression(maxBytes: 3_000_000))
    let prior = TaskPlan(request: "Merge and compress these to 3 MB", steps: [oldMerge, oldCompress])

    let plan = FastPathPlanner().plan(request: "Do the same to these files", artifacts: [newA, newB],
                                      context: PlanningContext(previousPlan: prior))

    #expect(plan.steps.count == 2)
    #expect(plan.steps[0].operation == .mergePDFs)
    #expect(plan.steps[0].source == .artifacts([newA.id, newB.id]))
    #expect(plan.steps[0].id != oldMerge.id)
    #expect(plan.steps[1].operation == .compressPDF)
    #expect(plan.steps[1].source == .previousStep(plan.steps[0].id))
    #expect(plan.steps[1].id != oldCompress.id)
    #expect(plan.steps[1].arguments == .pdfCompression(maxBytes: 3_000_000))
}

@Test func sameToTheseRejectsPipelineWhenAnyStageDoesNotAcceptNewTypes() throws {
    let oldA = try makeArtifact(name: "old-a.pdf", kind: .pdf)
    let oldB = try makeArtifact(name: "old-b.pdf", kind: .pdf)
    let image = try makeArtifact(name: "new.png", kind: .image)
    let oldMerge = TaskStep(operation: .mergePDFs, source: .artifacts([oldA.id, oldB.id]))
    let oldCompress = TaskStep(operation: .compressPDF, source: .previousStep(oldMerge.id),
                               arguments: .pdfCompression(maxBytes: nil))
    let prior = TaskPlan(request: "Merge and compress", steps: [oldMerge, oldCompress])

    let plan = FastPathPlanner().plan(request: "Do the same to these files", artifacts: [image],
                                      context: PlanningContext(previousPlan: prior))

    #expect(plan.steps.isEmpty)
    #expect(plan.clarification?.contains("doesn't fit") == true)
}

@Test func sameWorkflowAsksWhenNewFilesDoNotMatchThePriorTool() throws {
    let original = try makeArtifact(name: "first.png", kind: .image)
    let selected = try makeArtifact(name: "report.pdf", kind: .pdf)
    let prior = TaskPlan(request: "Resize to 800 pixels", steps: [
        TaskStep(operation: .resizeImage, source: .artifacts([original.id]), arguments: .imageResize(width: 800))
    ])
    let plan = FastPathPlanner().plan(request: "Same thing with these files", artifacts: [selected],
                                      context: PlanningContext(previousOperation: .resizeImage, previousPlan: prior))
    #expect(plan.steps.isEmpty)
    #expect(plan.clarification?.contains("doesn't fit") == true)
}

@Test func resizeFollowupCanSupplyANewWidthWithoutRepeatingTheVerb() throws {
    let output = try makeArtifact(name: "photo-Resized.png", kind: .image)
    let plan = FastPathPlanner().plan(request: "Make this one 1200 pixels too", artifacts: [],
                                      context: PlanningContext(activeOutput: output, previousOperation: .resizeImage))
    #expect(plan.steps.first?.operation == .resizeImage)
    #expect(plan.steps.first?.arguments == .imageResize(width: 1200))
}

@Test func planArtifactSnapshotKeepsOriginalsAndEarlierStepOutputsResolvable() throws {
    let inputA = try makeArtifact(name: "one.png", kind: .image)
    let inputB = try makeArtifact(name: "two.png", kind: .image)
    let step1 = TaskStep(operation: .resizeImage, source: .artifacts([inputA.id]), arguments: .imageResize(width: 100))
    let step2 = TaskStep(operation: .convertImage, source: .artifacts([inputB.id]), arguments: .imageConvert(format: "jpeg"))
    let step3 = TaskStep(operation: .convertImage, source: .previousStep(step1.id), arguments: .imageConvert(format: "png"))
    var snapshot = PlanArtifactSnapshot(originals: [inputA, inputB])

    #expect(try snapshot.resolve(step1) == [inputA])
    let step1Output = try makeArtifact(name: "one-Resized.png", kind: .image)
    snapshot.record([step1Output], for: step1)
    #expect(try snapshot.resolve(step2) == [inputB])
    let step2Output = try makeArtifact(name: "two.jpg", kind: .image)
    snapshot.record([step2Output], for: step2)
    #expect(try snapshot.resolve(step3) == [step1Output])
}

@Test func modelPlanDecoderAcceptsRegisteredExactRename() throws {
    let pdf = try makeArtifact(name: "report.pdf", kind: .pdf)
    let wire = #"{"steps":[{"operation":"file.rename","inputIndexes":[0],"arguments":{"name":"final-submission.pdf"}}]}"#
    let plan = try #require(ModelPlanDecoder.decode(wire, request: "rename", artifacts: [pdf]))
    #expect(plan.steps[0].operation == .renameFile)
    #expect(plan.steps[0].arguments == .exactRename(name: "final-submission.pdf"))
}

@Test @MainActor func modelPlanRepairRetriesOnceAndReturnsOnlyAValidatedPlan() async throws {
    let image = try makeArtifact(name: "photo.png", kind: .image)
    let responses = RepairResponseQueue([
        #"{"steps":[{"operation":"image.resize","inputIndexes":[9],"arguments":{"width":100}}]}"#,
        #"{"steps":[{"operation":"image.resize","inputIndexes":[0],"arguments":{"width":100}}]}"#
    ])
    let plan = try await ModelPlanRepair.plan(request: "Resize this to 100 pixels", artifacts: [image], initialPrompt: "Plan safely.") { prompt in
        await responses.next(for: prompt)
    }

    #expect(plan?.steps.first?.operation == .resizeImage)
    #expect(await responses.prompts.count == 2)
    #expect(await responses.prompts.last?.contains("failed validation") == true)
    #expect(await responses.prompts.last?.contains("steps[0].inputIndexes") == true)
    #expect(await responses.prompts.last?.contains("Prior response (sanitized") == true)
}

@Test @MainActor func modelPlanRepairStopsAfterOneInvalidRepair() async throws {
    let image = try makeArtifact(name: "photo.png", kind: .image)
    let invalid = #"{"steps":[{"operation":"shell.execute","inputIndexes":[0],"arguments":{}}]}"#
    let responses = RepairResponseQueue([invalid, invalid, invalid])
    let plan = try await ModelPlanRepair.plan(request: "Do something", artifacts: [image], initialPrompt: "Plan safely.") { prompt in
        await responses.next(for: prompt)
    }

    #expect(plan == nil)
    #expect(await responses.prompts.count == 2)
}

@Test func restoredArtifactMustStillExistAndMatchItsRecordedKind() throws {
    let artifact = try makeArtifact(name: "report.pdf", kind: .pdf)
    #expect(artifact.isAvailableLocally)
    #expect(artifact.refreshedFromDisk()?.id == artifact.id)
    try FileManager.default.removeItem(at: artifact.fileURL)
    #expect(!artifact.isAvailableLocally)
    #expect(artifact.refreshedFromDisk() == nil)
}

@Test func notchRemainsOpenForAnyActiveInteractionReason() {
    var state = NotchInteractionState()
    state.set(.pointer, active: true)
    #expect(state.shouldRemainExpanded)
    state.set(.pointer, active: false)
    #expect(!state.shouldRemainExpanded)

    state.set(.composing, active: true)
    #expect(state.shouldRemainExpanded)
    state.set(.composing, active: false)

    for reason in [NotchInteractionReason.attachments, .dragging, .pinned, .working, .resultInteraction, .menuOrPopover, .cueSession] {
        state.set(reason, active: true)
        state.set(.pointer, active: true)
        state.set(.pointer, active: false)
        #expect(state.shouldRemainExpanded)
        state.set(reason, active: false)
    }

    #expect(!state.shouldRemainExpanded)
}

@Test func cueSessionPinsNotchFromSetupThroughCompletionAndCanReleaseForCollapse() {
    var state = NotchInteractionState()
    state.setCueSession(true) // Cue setup begins.
    #expect(state.isActive(.cueSession))
    #expect(state.shouldRemainExpanded)

    state.set(.pointer, active: true)
    state.set(.pointer, active: false)
    #expect(state.shouldRemainExpanded)

    // Start and mode changes do not relinquish Cue ownership.
    #expect(state.isActive(.cueSession))
    state.setCueSession(false) // Completion or manual Done.
    #expect(!state.shouldRemainExpanded)
    state.setCueSession(true)
    state.setCueSession(false)
    #expect(!state.shouldRemainExpanded)
}

@Test func collapsedNotchPresentationHasNoMascotOrContentPayload() {
    let collapsed = NotchPresentationState(expanded: false, mode: .result, activeAgent: .reel, progress: 1)
    #expect(!collapsed.exposesMascot)
    #expect(!collapsed.exposesContent)
    #expect(collapsed.clipsContentToShell)

    let opening = NotchPresentationState(expanded: true, mode: .idleComposer, activeAgent: .kio, progress: 0.12)
    #expect(!opening.exposesMascot)
    #expect(opening.exposesContent)
    let ready = NotchPresentationState(expanded: true, mode: .cueActive, activeAgent: .cue, progress: 1)
    #expect(!ready.exposesMascot)
    #expect(ready.exposesContent)
}

@Test func characterMotionPolicyKeepsSubtleBlinkTimingAndNewAgentsRegistered() {
    #expect(CharacterMotionPolicy.blinkDelay(sample: 0) == 2.5)
    #expect(CharacterMotionPolicy.blinkDelay(sample: 1) == 5.5)
    #expect(CharacterMotionPolicy.blinkCloseDuration(sample: 0) == 0.09)
    #expect(CharacterMotionPolicy.blinkCloseDuration(sample: 1) == 0.13)
    #expect(CharacterMotionPolicy.blinkOpenDuration(sample: 0) == 0.1)
    #expect(CharacterMotionPolicy.blinkOpenDuration(sample: 1) == 0.15)
    #expect(CharacterMotionPolicy.choosesDoubleBlink(sample: 0.179))
    #expect(!CharacterMotionPolicy.choosesDoubleBlink(sample: 0.18))
    #expect(AgentID.reel.colorHex == 0xD58B7C)
    #expect(AgentID.cue.colorHex == 0xA8C98D)
    #expect(AgentID.reel.roleDescription.contains("media"))
    #expect(AgentID.cue.roleDescription.contains("Teleprompter"))
}

@Test func reelRoutesExplicitAndUnderspecifiedRequestsWithoutModelPlanning() throws {
    let url = try makeArtifact(name: "public-video.kio-url", kind: .url)
    let inspect = FastPathPlanner().plan(request: "download this", artifacts: [url])
    #expect(inspect.steps.map(\.operation) == [.inspectRemoteMedia])
    #expect(inspect.steps.first?.owner == .reel)

    let video = FastPathPlanner().plan(request: "download this in 1080p mp4", artifacts: [url])
    #expect(video.steps.map(\.operation) == [.downloadRemoteVideo])
    #expect(video.steps.first?.arguments == .remoteMedia(quality: "1080p", format: "mp4"))

    let audio = FastPathPlanner().plan(request: "get this as mp3", artifacts: [url])
    #expect(audio.steps.map(\.operation) == [.downloadRemoteAudio])
    #expect(audio.steps.first?.arguments == .remoteMedia(quality: nil, format: "mp3"))
}

@Test func cueAlignmentHandlesPartialsRevisionsPunctuationFillersAndMonotonicProgress() {
    var cue = CueTextAlignment(script: "Welcome everyone to the Kio presentation today.")
    #expect(cue.consume("Welcome", confidence: 0.9) == 1)
    #expect(cue.consume("Welcome everyone to the", confidence: 0.9) == 4)
    #expect(cue.consume("Welcome everyone", confidence: 0.9) == 4)
    #expect(cue.consume("welcome everyone um to the Kio", confidence: 0.9) == 5)
    #expect(cue.consume("welcome everyone to the Kio presentation today", confidence: 0.9) == 7)
    #expect(cue.isFinished)

    var punctuation = CueTextAlignment(script: "Hello, everyone! Today we’re testing Kio.")
    #expect(punctuation.consume("hello everyone today we're testing kio", confidence: 0.95) == 6)
    #expect(punctuation.isFinished)
}

@Test func cueAlignmentRequiresAgreementForFarJumpAndRejectsStaleGeneration() {
    let script = (0..<30).map { "word\($0)" }.joined(separator: " ")
    var cue = CueTextAlignment(script: script)
    #expect(cue.consume("word0 word1", confidence: 0.9) == 2)
    #expect(cue.consume((2..<18).map { "word\($0)" }.joined(separator: " "), confidence: 0.9) == 2)
    #expect(cue.consume((2..<19).map { "word\($0)" }.joined(separator: " "), confidence: 0.9) == 19)
    let oldGeneration = cue.generation
    #expect(cue.jump(to: 25) == 25)
    #expect(cue.consume("word19 word20", confidence: 0.99, generation: oldGeneration) == 25)
    #expect(cue.consume("word25 word26", confidence: 0.1) == 25)
    #expect(cue.consume("word25 word26", confidence: 0.9, generation: cue.generation) == 27)
}

@Test func cueNewReadingSessionsCanRejectCallbacksFromAnEarlierSession() {
    let previous = CueTextAlignment(script: "old script", generation: 4)
    var current = CueTextAlignment(script: "new script", generation: 5)
    #expect(current.generation == 5)
    #expect(current.consume("new script", confidence: 0.95, generation: previous.generation) == 0)
    #expect(current.consume("new script", confidence: 0.95, generation: current.generation) == current.tokens.count)
}

@Test func cueContextClassicClockAndVoiceActivityStayBounded() {
    let cue = CueTextAlignment(script: "An uncommon phrase with an uncommon ending.")
    #expect(cue.upcomingContextWords == ["uncommon", "phrase", "ending"])
    #expect(CueTextAlignment.words("Um, uh, we're ready!") == ["we're", "ready"])
    var clock = CueClassicClock()
    #expect(clock.advance(elapsed: 30, wordsPerMinute: 120, totalWords: 10, paused: false) == 10)
    #expect(clock.advance(elapsed: 10, wordsPerMinute: 120, totalWords: 10, paused: true) == 10)
    var voice = CueVoiceActivityState()
    let quiet = voice.update(power: 0.01)
    #expect(!quiet)
    let speaking = voice.update(power: 0.05)
    #expect(speaking)
    let invalid = voice.update(power: .infinity)
    #expect(!invalid)
}

@Test func providerRequestConstructionUsesDirectProviderEndpointsAndNeverSerializesKeys() throws {
    let client = IntelligenceProviderClient()
    let providers: [(IntelligenceProviderID, String, String)] = [
        (.openAI, "https://api.openai.com/v1/chat/completions", "Bearer test-secret"),
        (.openRouter, "https://openrouter.ai/api/v1/chat/completions", "Bearer test-secret"),
        (.groq, "https://api.groq.com/openai/v1/chat/completions", "Bearer test-secret"),
        (.anthropic, "https://api.anthropic.com/v1/messages", "test-secret"),
        (.gemini, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent", "test-secret")
    ]
    for (provider, endpoint, keyHeader) in providers {
        let (request, _) = try client.makeRequest(provider: provider, model: "gemini-2.5-flash", key: "test-secret",
                                                  system: "bounded system", prompt: "metadata-only planner request", maxTokens: 200)
        #expect(request.url?.absoluteString == endpoint)
        let serializedBody = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(!serializedBody.contains("test-secret"))
        #expect(request.value(forHTTPHeaderField: provider == .anthropic ? "x-api-key" : provider == .gemini ? "x-goog-api-key" : "Authorization") == keyHeader)
        #expect(request.url?.scheme == "https")
    }
    let services = IntelligenceProviderID.allCases.compactMap(\.keychainService)
    #expect(Set(services).count == services.count)
    #expect(services.allSatisfy { $0.hasPrefix("app.kio.mac.ai.") })
}

@Test func remoteTaskLedgerRejectsRedeliveryAndStaysBounded() {
    var ledger = TaskDeduplicationLedger(knownIDs: ["already-seen"], maximumEntries: 2)
    let duplicate = ledger.insertIfNew("already-seen")
    let acceptedSecond = ledger.insertIfNew("task-2")
    let acceptedThird = ledger.insertIfNew("task-3")
    #expect(!duplicate)
    #expect(acceptedSecond)
    #expect(acceptedThird)
    #expect(ledger.entries == ["task-2", "task-3"])
    let acceptedAfterExpiry = ledger.insertIfNew("already-seen")
    #expect(acceptedAfterExpiry)
    #expect(ledger.entries.count == 2)
}

@Test @MainActor func taskInputSnapshotsAndProviderConsentRemainRequestScoped() throws {
    let local = try makeArtifact(name: "private-local.pdf", kind: .pdf)
    let phone = try makeArtifact(name: "phone-image.png", kind: .image)
    let snapshot = TaskInputSnapshot(request: "read the phone image", artifacts: [phone], surface: .phoneRemote)
    #expect(snapshot.artifacts.map(\.displayName) == ["phone-image.png"])
    #expect(snapshot.surface == .phoneRemote)
    #expect(!snapshot.artifacts.contains(local))

    let taskID = UUID()
    let approved = ProviderContentConsentScope(taskID: taskID, providerID: "openAI",
        sourceArtifactIDs: [phone.id, phone.id], sourceNames: [phone.displayName])
    let otherTask = ProviderContentConsentScope(taskID: UUID(), providerID: "openAI",
        sourceArtifactIDs: [phone.id], sourceNames: [phone.displayName])
    let otherProvider = ProviderContentConsentScope(taskID: taskID, providerID: "anthropic",
        sourceArtifactIDs: [phone.id], sourceNames: [phone.displayName])
    ProviderContentConsentLedger.shared.approve(approved)
    #expect(ProviderContentConsentLedger.shared.contains(approved))
    #expect(!ProviderContentConsentLedger.shared.contains(otherTask))
    #expect(!ProviderContentConsentLedger.shared.contains(otherProvider))
    ProviderContentConsentLedger.shared.clear(taskID: taskID)
    #expect(!ProviderContentConsentLedger.shared.contains(approved))
}

private func makeArtifact(name: String, kind: ArtifactKind) throws -> ArtifactRef {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([0x4b, 0x69, 0x6f]).write(to: url)
    return ArtifactRef(displayName: name, kind: kind, fileURL: url, sizeBytes: 3)
}

private actor RepairResponseQueue {
    private var responses: [String]
    private(set) var prompts: [String] = []

    init(_ responses: [String]) { self.responses = responses }

    func next(for prompt: String) -> String? {
        prompts.append(prompt)
        guard !responses.isEmpty else { return nil }
        return responses.removeFirst()
    }
}
