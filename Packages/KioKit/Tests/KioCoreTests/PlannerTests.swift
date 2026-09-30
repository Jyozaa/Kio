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

@Test func sameWorkflowAsksWhenNewFilesDoNotMatchThePriorTool() throws {
    let original = try makeArtifact(name: "first.png", kind: .image)
    let selected = try makeArtifact(name: "report.pdf", kind: .pdf)
    let prior = TaskPlan(request: "Resize to 800 pixels", steps: [
        TaskStep(operation: .resizeImage, source: .artifacts([original.id]), arguments: .imageResize(width: 800))
    ])
    let plan = FastPathPlanner().plan(request: "Same thing with these files", artifacts: [selected],
                                      context: PlanningContext(previousOperation: .resizeImage, previousPlan: prior))
    #expect(plan.steps.isEmpty)
    #expect(plan.clarification?.contains("does not accept") == true)
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
    #expect(await responses.prompts.last?.contains("strict typed-plan validation") == true)
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
    state.set(.inputFocus, active: true)
    state.set(.composing, active: true)
    state.set(.inputFocus, active: false)
    #expect(state.shouldRemainExpanded)
    state.set(.composing, active: false)
    state.set(.working, active: true)
    #expect(state.shouldRemainExpanded)
    state.set(.working, active: false)
    state.set(.pinned, active: true)
    #expect(state.shouldRemainExpanded)
    state.set(.pinned, active: false)
    #expect(!state.shouldRemainExpanded)
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
