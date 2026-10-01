import Foundation
import Testing
import KioCore
@testable import KioModel

@Test func notchPresentationUsesOneClampedProgressForContentMaskOpacityAndHitTesting() {
    let collapsed = NotchPresentationState(expanded: false, mode: .result, activeAgent: .reel, progress: 1)
    #expect(!collapsed.exposesContent)
    #expect(!collapsed.exposesMascot)
    #expect(!collapsed.allowsContentHitTesting)
    #expect(collapsed.clipsContentToShell)

    let beforeContent = NotchPresentationState(expanded: true, mode: .idleComposer, activeAgent: .kio, progress: 0.08)
    #expect(!beforeContent.exposesContent)
    let contentOnly = NotchPresentationState(expanded: true, mode: .idleComposer, activeAgent: .kio, progress: 0.2)
    #expect(contentOnly.exposesContent)
    #expect(!contentOnly.exposesMascot)
    #expect(contentOnly.contentOpacity == 0.25)
    #expect(!contentOnly.allowsContentHitTesting)

    let interactive = NotchPresentationState(expanded: true, mode: .result, activeAgent: .pixel, progress: 0.9)
    #expect(interactive.exposesMascot)
    #expect(interactive.allowsContentHitTesting)
    #expect(interactive.contentOpacity == 1)
    let clamped = NotchPresentationState(expanded: true, mode: .result, activeAgent: .pixel, progress: 4)
    #expect(clamped.progress == 1)
    #expect(NotchPresentationState(expanded: true, mode: .cueActive, activeAgent: .cue, progress: 1).exposesContent)
    #expect(!NotchPresentationState(expanded: true, mode: .cueActive, activeAgent: .cue, progress: 1).exposesMascot)
}

@Test func notchModeAndActiveAgentResolveEveryLifecycleTransition() {
    #expect(NotchPresentationState.mode(cueActive: false, cueSetup: false, preparing: false, taskStatus: nil) == .idleComposer)
    #expect(NotchPresentationState.mode(cueActive: false, cueSetup: false, preparing: true, taskStatus: .completed) == .preparing)
    #expect(NotchPresentationState.mode(cueActive: false, cueSetup: false, preparing: false, taskStatus: .planning) == .preparing)
    #expect(NotchPresentationState.mode(cueActive: false, cueSetup: false, preparing: false, taskStatus: .running) == .working)
    #expect(NotchPresentationState.mode(cueActive: false, cueSetup: false, preparing: false, taskStatus: .completed) == .result)
    #expect(NotchPresentationState.mode(cueActive: false, cueSetup: false, preparing: false, taskStatus: .waitingForUser) == .clarificationError)
    #expect(NotchPresentationState.mode(cueActive: false, cueSetup: false, preparing: false, taskStatus: .failed) == .clarificationError)
    #expect(NotchPresentationState.mode(cueActive: false, cueSetup: false, preparing: false, taskStatus: .cancelled) == .clarificationError)
    #expect(NotchPresentationState.mode(cueActive: false, cueSetup: true, preparing: false, taskStatus: .running) == .cueSetup)
    #expect(NotchPresentationState.mode(cueActive: true, cueSetup: true, preparing: true, taskStatus: .running) == .cueActive)

    let step = TaskStep(operation: .convertImage, source: .artifacts([UUID()]))
    let plan = TaskPlan(request: "Convert this image", steps: [step])
    let planning = TaskExecutionState(taskID: UUID(), plan: plan, status: .planning, statusText: "Planning")
    #expect(NotchPresentationState.activeAgent(for: nil) == .kio)
    #expect(NotchPresentationState.activeAgent(for: planning) == .pixel)
    let running = TaskExecutionState(taskID: UUID(), plan: plan, currentStepIndex: 0, activeAgent: .reel,
                                     status: .running, statusText: "Downloading")
    #expect(NotchPresentationState.activeAgent(for: running) == .reel)
}

@Test func mascotHandoffRunsCoordinatorDepartureLandingAndStableSpecialistSequence() {
    var handoff = MascotHandoffState()
    #expect(handoff.phase == .coordinator)
    #expect(handoff.displayedAgent == .kio)
    #expect(!handoff.launchSmokeVisible)

    handoff.beginDeparture(to: .pixel)
    #expect(handoff.phase == .departing)
    #expect(handoff.displayedAgent == .kio)
    #expect(handoff.coordinatorHasDeparted)
    #expect(handoff.launchSmokeVisible)
    #expect(!handoff.agentHasArrived)

    handoff.landTarget()
    #expect(handoff.phase == .landing)
    #expect(handoff.activeAgent == .pixel)
    #expect(handoff.displayedAgent == .pixel)
    #expect(handoff.agentHasArrived)
    #expect(handoff.launchSmokeVisible)

    handoff.settle()
    #expect(handoff.phase == .assigned)
    #expect(handoff.displayedAgent == .pixel)
    #expect(!handoff.launchSmokeVisible)
    #expect(handoff.coordinatorHasDeparted)

    handoff.assignImmediately(.cue)
    #expect(handoff.displayedAgent == .cue)
    #expect(handoff.agentHasArrived)
    handoff.resetToCoordinator()
    #expect(handoff.phase == .coordinator)
    #expect(handoff.displayedAgent == .kio)
    #expect(!handoff.coordinatorHasDeparted)
    #expect(!handoff.agentHasArrived)
    #expect(!handoff.launchSmokeVisible)

    #expect(MascotHandoffMotionPolicy.coordinatorDepartureDuration >= 1.2)
    #expect(MascotHandoffMotionPolicy.landingSpringResponse >= 0.6)
}

@Test func characterMotionPoliciesBoundBlinkingAndRespectBothReduceMotionSettings() {
    #expect(CharacterMotionPolicy.blinkDelay(sample: -5) == CharacterMotionPolicy.blinkDelaySeconds.lowerBound)
    #expect(CharacterMotionPolicy.blinkDelay(sample: 5) == CharacterMotionPolicy.blinkDelaySeconds.upperBound)
    #expect(CharacterMotionPolicy.blinkDelay(sample: .nan) == CharacterMotionPolicy.blinkDelaySeconds.lowerBound)
    #expect(CharacterMotionPolicy.blinkCloseDuration(sample: 0) == 0.09)
    #expect(CharacterMotionPolicy.blinkCloseDuration(sample: 1) == 0.13)
    #expect(CharacterMotionPolicy.blinkOpenDuration(sample: 0) == 0.1)
    #expect(CharacterMotionPolicy.blinkOpenDuration(sample: 1) == 0.15)
    #expect(CharacterMotionPolicy.choosesDoubleBlink(sample: 0.179))
    #expect(!CharacterMotionPolicy.choosesDoubleBlink(sample: 0.18))
    #expect(!CharacterMotionPolicy.choosesDoubleBlink(sample: .nan))
    #expect(CharacterMotionPolicy.motionEnabled(systemReduceMotion: false, userReduceMotion: false))
    #expect(!CharacterMotionPolicy.motionEnabled(systemReduceMotion: true, userReduceMotion: false))
    #expect(!CharacterMotionPolicy.motionEnabled(systemReduceMotion: false, userReduceMotion: true))

    for agent in [AgentID.pixel, .zip, .echo, .table, .lens, .reel, .cue, .pip, .clerk, .courier, .patch, .scribe, .scout] {
        let rest = CharacterMotionPolicy.rolePose(for: agent, beat: false, reduceMotion: false)
        let beat = CharacterMotionPolicy.rolePose(for: agent, beat: true, reduceMotion: false)
        #expect(rest != beat, "\(agent.name) should have a distinct active role pose.")
        #expect(CharacterMotionPolicy.rolePose(for: agent, beat: true, reduceMotion: true) == CharacterRolePose())
    }
    #expect(CharacterMotionPolicy.rolePose(for: .cue, beat: true, reduceMotion: false).rotationDegrees == -0.5)
    #expect(AgentID.reel.colorHex == 0xD58B7C)
    #expect(AgentID.cue.colorHex == 0xA8C98D)
}

@Test func cueAlignmentHandlesSkippedWordsRepeatedWordsAndStalePartials() {
    var skipped = CueTextAlignment(script: "I really like the presentation today.")
    #expect(skipped.consume("I really like", confidence: 0.9) == 3)
    #expect(skipped.consume("presentation today", confidence: 0.9) == 6)
    #expect(skipped.isFinished)

    var repeated = CueTextAlignment(script: "Go go go now, go slowly.")
    #expect(repeated.consume("go", confidence: 0.9) == 1)
    #expect(repeated.consume("go go", confidence: 0.9) == 2)
    #expect(repeated.consume("go now", confidence: 0.9) == 4)
    let confirmed = repeated.confirmedReadPosition
    #expect(repeated.consume("go go", confidence: 0.95) == confirmed)
    #expect(repeated.consume("um uh", confidence: 0.99) == confirmed)
    #expect(repeated.consume("go slowly", confidence: 0.9) == 6)
    #expect(repeated.isFinished)
}

@Test func cueConfidenceManualJumpAndCompletionBoundsAreDeterministic() {
    var cue = CueTextAlignment(script: "One two three four five.")
    #expect(!cue.isFinished)
    #expect(cue.consume("one two", confidence: 0.29) == 0)
    #expect(cue.consume("um uh", confidence: 0.99) == 0)
    #expect(cue.consume("one two", confidence: 0.9) == 2)
    let previousGeneration = cue.generation
    #expect(cue.jump(to: 4) == 4)
    #expect(cue.generation == previousGeneration + 1)
    #expect(cue.consume("three four", confidence: 0.99, generation: previousGeneration) == 4)
    #expect(cue.consume("five", confidence: 0.9, generation: cue.generation) == 5)
    #expect(cue.isFinished)
    #expect(cue.jump(to: 500) == cue.tokens.count)
    #expect(cue.jump(to: -4) == 0)
    #expect(!CueTextAlignment(script: " \n … ").isFinished)
}

@Test func cueContextClassicScrollAndVoiceActivityRemainBounded() {
    let cue = CueTextAlignment(script: (0..<100).map { "distinctive\($0)" }.joined(separator: " "))
    #expect(cue.upcomingContextWords.count == 32)
    #expect(Set(cue.upcomingContextWords).count == 32)
    #expect(CueTextAlignment.words("Hello, everyone! We're ready.") == ["hello", "everyone", "we're", "ready"])

    var clock = CueClassicClock()
    #expect(clock.advance(elapsed: 1, wordsPerMinute: 30, totalWords: 20, paused: false) == 0.5)
    #expect(clock.advance(elapsed: 2, wordsPerMinute: 2_000, totalWords: 20, paused: false) == 13.833333333333334)
    let afterAdvance = clock.position
    #expect(clock.advance(elapsed: 10, wordsPerMinute: 120, totalWords: 20, paused: true) == afterAdvance)
    #expect(clock.advance(elapsed: -.infinity, wordsPerMinute: 120, totalWords: 20, paused: false) == afterAdvance)
    #expect(clock.advance(elapsed: 1, wordsPerMinute: 120, totalWords: 5, paused: false) == 5)

    var voice = CueVoiceActivityState()
    let belowVoiceThreshold = voice.update(power: 0.034)
    let aboveVoiceThreshold = voice.update(power: 0.035)
    let nanVoicePower = voice.update(power: .nan)
    let infiniteVoicePower = voice.update(power: .infinity)
    #expect(!belowVoiceThreshold)
    #expect(aboveVoiceThreshold)
    #expect(!nanVoicePower)
    #expect(!infiniteVoicePower)
}
