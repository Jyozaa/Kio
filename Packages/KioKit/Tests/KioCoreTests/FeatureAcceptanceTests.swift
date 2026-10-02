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

@Test func cueAudioCaptureAndAnalyzerFormatsRejectInvalidValuesAndKeepHardwareRate() {
    #expect(CueAudioFormatPolicy.captureFormat(for: .init(sampleRate: 0, channelCount: 2)) == nil)
    #expect(CueAudioFormatPolicy.captureFormat(for: .init(sampleRate: 48_000, channelCount: 0)) == nil)
    #expect(CueAudioFormatPolicy.captureFormat(for: .init(sampleRate: .nan, channelCount: 1)) == nil)
    #expect(CueAudioFormatPolicy.captureFormat(for: .init(sampleRate: 48_000, channelCount: 2)) == .init(sampleRate: 48_000, channelCount: 1))
    #expect(CueAudioFormatPolicy.captureFormat(for: .init(sampleRate: 44_100, channelCount: 1)) == .init(sampleRate: 44_100, channelCount: 1))

    #expect(CueAudioFormatPolicy.analyzerFormat(preferred: nil) == nil)
    #expect(CueAudioFormatPolicy.analyzerFormat(preferred: .init(sampleRate: 16_000, channelCount: 1)) == .init(sampleRate: 16_000, channelCount: 1))
    #expect(CueAudioFormatPolicy.analyzerFormat(preferred: .init(sampleRate: -1, channelCount: 1)) == nil)
}

@Test func cueAudioLifecycleGuardsTapsAndSupportsStopFailureAndRepeatedRestart() {
    var session = CueAudioSessionLifecycle()
    session.stop() // Stop before the first start is harmless.
    #expect(session.phase == .stopped)
    #expect(!session.tapInstalled)

    for _ in 0..<3 {
        guard let attempt = session.beginStart() else { Issue.record("An idle Cue session should be startable."); return }
        #expect(session.phase == .starting)
        let installed = session.installTap(for: attempt)
        let duplicateInstall = session.installTap(for: attempt)
        let started = session.didStart(attempt)
        #expect(installed)
        #expect(!duplicateInstall)
        #expect(started)
        #expect(session.phase == .running)
        #expect(session.tapInstalled)
        session.stop()
        #expect(session.phase == .stopped)
        #expect(!session.tapInstalled)
    }

    guard let failed = session.beginStart() else { Issue.record("A stopped Cue session should be startable after failure."); return }
    let failedTapInstalled = session.installTap(for: failed)
    #expect(failedTapInstalled)
    session.failStart(failed)
    #expect(session.phase == .stopped)
    #expect(!session.tapInstalled)
    #expect(!session.isCurrent(failed))

    guard let restartedAfterJump = session.beginStart() else { Issue.record("Cue should restart after a jump stop."); return }
    let jumpTapInstalled = session.installTap(for: restartedAfterJump)
    let jumpStarted = session.didStart(restartedAfterJump)
    #expect(jumpTapInstalled)
    #expect(jumpStarted)
    let fallbackStarted = session.beginFallback(restartedAfterJump)
    #expect(fallbackStarted)
    #expect(session.phase == .starting)
    let fallbackTapInstalled = session.installTap(for: restartedAfterJump)
    let fallbackEngineStarted = session.didStart(restartedAfterJump)
    #expect(fallbackTapInstalled)
    #expect(fallbackEngineStarted)
    session.stop()
    guard let restartedAgain = session.beginStart() else { Issue.record("Repeated Cue restart should be allowed."); return }
    let repeatedTapInstalled = session.installTap(for: restartedAgain)
    let repeatedStarted = session.didStart(restartedAgain)
    #expect(repeatedTapInstalled)
    #expect(repeatedStarted)
}

@Test func cueSpeechBackendSelectionFallsBackToLegacyWhenModernPreparationFails() {
    #expect(CueSpeechBackendPolicy.select(modernPrepared: true, legacyAvailable: true) == .speechAnalyzer)
    #expect(CueSpeechBackendPolicy.select(modernPrepared: false, legacyAvailable: true) == .speechRecognizer)
    #expect(CueSpeechBackendPolicy.select(modernPrepared: false, legacyAvailable: false) == nil)
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

@Test func cueResponsiveTrackingFollowsPartialSpeechQuicklyAndMonotonically() {
    var cue = CueTextAlignment(script: "Welcome to Kio. Today I am testing the teleprompter. The words should follow my voice in real time.")
    let partials = ["Welcome", "Welcome to Kio", "Welcome to Kio today", "today I am testing",
                    "today I am testing the teleprompter", "the words should follow",
                    "the words should follow my voice", "my voice in real time"]
    var positions: [Int] = []
    for partial in partials {
        positions.append(cue.consume(partial, confidence: 0.9, policy: .responsive))
    }
    #expect(positions == positions.sorted())
    #expect(positions.last == cue.tokens.count)
    #expect(positions[1] >= 3)
    #expect(positions[4] >= 9)
    #expect(cue.recentSpokenWords == "my voice in real time")
}

@Test func cueResponsiveTrackingToleratesRevisionsOmissionsFillersAndSmallSubstitutions() {
    var cue = CueTextAlignment(script: "The words should follow my voice smoothly. I want to show you how Kio works.")
    let start = cue.consume("the words should follow my boys", confidence: 0.9, policy: .responsive)
    let corrected = cue.consume("the words should follow my voice", confidence: 0.9, policy: .responsive)
    #expect(start > 0)
    #expect(corrected >= start)
    #expect(cue.consume("smoothly I want uh to show you how Kio works", confidence: 0.9, policy: .responsive) == cue.tokens.count)

    var skipped = CueTextAlignment(script: "I want to show you how Kio works")
    #expect(skipped.consume("I want show you how Kio works", confidence: 0.9, policy: .responsive) == skipped.tokens.count)

    var repeated = CueTextAlignment(script: "that that example is intentional")
    #expect(repeated.consume("that that example", confidence: 0.9, policy: .responsive) == 3)
}

@Test func cueResponsiveTrackingRequiresConfirmationForLargeAccidentalJumps() {
    let script = (0..<40).map { "unique\($0)" }.joined(separator: " ")
    var cue = CueTextAlignment(script: script)
    let farPhrase = (30..<38).map { "unique\($0)" }.joined(separator: " ")
    #expect(cue.consume(farPhrase, confidence: 0.9, policy: .responsive) == 0)
    #expect(cue.consume(farPhrase, confidence: 0.9, policy: .responsive) == 0)
    #expect(cue.consume((31..<39).map { "unique\($0)" }.joined(separator: " "), confidence: 0.9, policy: .responsive) == 39)
}

@Test func cueAlignmentFollowsTheExactJoeRegressionWithoutWeakWordTeleporting() {
    var cue = CueTextAlignment(script: "testing, testing, 1, 2, 3, my name is joe and today i am testing cue in my productivity app kio")
    #expect(cue.consume("testing", confidence: 0.95, policy: .responsive) == 1)
    #expect(cue.consume("testing testing", confidence: 0.95, policy: .responsive) == 2)
    #expect(cue.consume("testing testing 1", confidence: 0.95, policy: .responsive) == 3)
    #expect(cue.consume("one", confidence: 0.95, policy: .responsive) == 3)
    #expect(cue.recentSpokenWords == "one")
    #expect(cue.consume("my", confidence: 0.95, policy: .responsive) == 6)
    #expect(cue.consume("testing testing one two three my", confidence: 0.95, policy: .responsive) == 6)
    #expect(cue.consume("my name is joe", confidence: 0.95, policy: .responsive) == 9)
    #expect(cue.consume("my productivity app kio", confidence: 0.95, policy: .responsive) == cue.tokens.count)
}

@Test func cueNumberExpansionsMatchOnlyTheNearbyScriptInterpretation() {
    let script = "testing, testing, 1, 2, 3, my name is joe and today i am testing cue in my productivity app kio"
    var digits = CueTextAlignment(script: script)
    #expect(digits.consume("testing", confidence: 0.9, policy: .responsive) == 1)
    #expect(digits.consume("testing testing", confidence: 0.9, policy: .responsive) == 2)
    #expect(digits.consume("testing testing 1", confidence: 0.9, policy: .responsive) == 3)
    #expect(digits.consume("testing testing 123", confidence: 0.9, policy: .responsive) == 5)
    #expect(digits.confirmedReadPosition == 5)

    var cardinal = CueTextAlignment(script: "one hundred twenty three people attended")
    #expect(cardinal.consume("123", confidence: 0.9, policy: .responsive) == 4)

    var distant = CueTextAlignment(script: "start " + Array(repeating: "different", count: 20).joined(separator: " ") + " one two three")
    #expect(distant.consume("123", confidence: 0.9, policy: .responsive) == 0)
    #expect(distant.consume("123", confidence: 0.9, policy: .responsive) == 0)
}

@Test func cueKioPhoneticVariantsAreDistinctiveAndNearOnly() {
    for variant in ["kyo", "keo"] {
        var singleNearby = CueTextAlignment(script: "kio")
        #expect(singleNearby.consume(variant, confidence: 0.9, policy: .responsive) == 1)

        var nearby = CueTextAlignment(script: "my productivity app kio")
        #expect(nearby.consume("my productivity app \(variant)", confidence: 0.9, policy: .responsive) == nearby.tokens.count)

        var distant = CueTextAlignment(script: Array(repeating: "different", count: 16).joined(separator: " ") + " kio")
        #expect(distant.consume(variant, confidence: 0.9, policy: .responsive) == 0)
    }

    var commonShortWord = CueTextAlignment(script: "the end")
    #expect(commonShortWord.consume("they", confidence: 0.9, policy: .responsive) == 0)
}

@Test func cueWaveformSmoothingBoundsAndThrottlesSamples() {
    var waveform = CueWaveformState(capacity: 4, smoothing: 0.5, minimumInterval: 0.04)
    #expect(waveform.levels.count == 4)
    let firstAccepted = waveform.append(power: 0.25, at: 1)
    #expect(firstAccepted)
    let first = waveform.displayedLevel
    #expect(first > 0 && first < 1)
    let throttled = waveform.append(power: 1, at: 1.01)
    #expect(!throttled)
    let secondAccepted = waveform.append(power: 1, at: 1.05)
    #expect(secondAccepted)
    #expect(waveform.levels.count == 4)
    #expect(waveform.displayedLevel > first)
    let nanAccepted = waveform.append(power: .nan, at: 1.10)
    #expect(nanAccepted)
    #expect(waveform.displayedLevel.isFinite)
    #expect(waveform.levels.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
    let silenceAccepted = waveform.append(power: 0, at: 1.15)
    #expect(silenceAccepted)
    #expect(waveform.displayedLevel < 1)
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
