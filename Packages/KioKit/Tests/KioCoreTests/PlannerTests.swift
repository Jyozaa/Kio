import Foundation
import Testing
import KioCore
import KioModel

@Test func mergeRequestSelectsRegisteredPDFOperation() throws {
    let a = try makeArtifact(name: "report.pdf", kind: .pdf)
    let b = try makeArtifact(name: "appendix.pdf", kind: .pdf)
    let plan = FastPathPlanner().plan(request: "Merge these PDFs", artifacts: [a, b])
    #expect(plan.steps.count == 1)
    #expect(plan.steps.first?.operation == .mergePDFs)
    #expect(plan.steps.first?.owner == .pip)
}

@Test func unsupportedRequestDoesNotInventTools() throws {
    let image = try makeArtifact(name: "photo.png", kind: .image)
    let plan = FastPathPlanner().plan(request: "Make this look cinematic", artifacts: [image])
    #expect(plan.steps.isEmpty)
    #expect(plan.clarification != nil)
}

@Test func fastResponseAnswersMacOnlineQuestionsWithoutAFilePlan() {
    let resolver = FastPathResponseResolver()
    #expect(resolver.response(to: "Is my Mac online?") == "Your Mac is online—it received this request just now.")
    #expect(resolver.response(to: "Check whether my Mac is online") == "Your Mac is online—it received this request just now.")
    #expect(resolver.response(to: "Make my Mac online") == nil)
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

private func makeArtifact(name: String, kind: ArtifactKind) throws -> ArtifactRef {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([0x4b, 0x69, 0x6f]).write(to: url)
    return ArtifactRef(displayName: name, kind: kind, fileURL: url, sizeBytes: 3)
}
