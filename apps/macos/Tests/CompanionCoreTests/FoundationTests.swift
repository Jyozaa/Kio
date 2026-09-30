import XCTest
@testable import CompanionCore
final class FoundationTests: XCTestCase {
    func testEmbeddedDriverSpecUsesPinnedBoundedHostMode() {
        let spec = EmbeddedDriverSpec.make(
            executablePath: "/Kio.app/Contents/Helpers/cua-driver",
            socketPath: "/tmp/Kio/driver-42/mcp.sock",
            hostBundleIdentifier: "local.companion.dev"
        )
        XCTAssertEqual(
            spec?.daemonArguments,
            ["serve", "--embedded", "--socket", "/tmp/Kio/driver-42/mcp.sock", "--permission-mode", "standard"]
        )
        XCTAssertEqual(spec?.environment["CUA_DRIVER_EMBEDDED"], "1")
        XCTAssertEqual(spec?.environment["CUA_DRIVER_HOST_BUNDLE_ID"], "local.companion.dev")
    }

    func testEmbeddedDriverSpecRejectsUnsafeOrUnboundedPaths() {
        XCTAssertNil(EmbeddedDriverSpec.make(
            executablePath: "cua-driver", socketPath: "/tmp/socket", hostBundleIdentifier: "local.kio"
        ))
        XCTAssertNil(EmbeddedDriverSpec.make(
            executablePath: "/driver", socketPath: "/tmp/" + String(repeating: "x", count: 110), hostBundleIdentifier: "local.kio"
        ))
        XCTAssertNil(EmbeddedDriverSpec.make(
            executablePath: "/driver", socketPath: "/tmp/socket", hostBundleIdentifier: "../kio"
        ))
    }

    func testEmbeddedDriverSpecAddsExistingProfileGrantOnlyWhenRequested() {
        let spec = EmbeddedDriverSpec.make(
            executablePath: "/Kio.app/Contents/Helpers/cua-driver",
            socketPath: "/tmp/Kio/driver-42/mcp.sock",
            hostBundleIdentifier: "local.companion.dev",
            allowExistingProfile: true
        )
        XCTAssertEqual(Array(spec?.daemonArguments.suffix(2) ?? []), ["--grant", "existing-profile"])
    }

    func testVersion() { XCTAssertEqual(protocolVersion, 1) }

    func testSetupProgressVersionedRoundTripAndOptionalSkip() {
        var progress = KioSetupProgress()
        XCTAssertTrue(progress.needsFirstRun)
        progress.advance(to: .microphone)
        progress.skip(.microphone)
        let decoded = KioSetupProgress.decode(progress.encoded())
        XCTAssertEqual(decoded, progress)
        XCTAssertTrue(decoded?.skippedOptionalStages.contains(.microphone) == true)
        XCTAssertFalse(KioSetupStage.inputMonitoring.isOptional)
        XCTAssertFalse(decoded?.skippedOptionalStages.contains(.accessibility) == true)
    }

    func testSetupProgressMigratesLegacyCompletionAndRejectsUnknownSchema() {
        let suite = "KioSetupProgressTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "kioSetupComplete")
        XCTAssertEqual(KioSetupProgress.load(from: defaults).completedVersion, KioSetupProgress.currentSetupVersion)
        XCTAssertEqual(KioSetupProgress.decode(defaults.data(forKey: KioSetupProgress.storageKey))?.stage, .ready)

        let unsupported = KioSetupProgress(schemaVersion: 99).encoded()
        XCTAssertNil(KioSetupProgress.decode(unsupported))
        defaults.set(unsupported, forKey: KioSetupProgress.storageKey)
        XCTAssertTrue(KioSetupProgress.load(from: defaults).needsFirstRun)
        XCTAssertEqual(KioSetupStage.allCases, [.welcome, .kioRuntime, .accessibility, .screenCapture, .inputMonitoring, .microphone, .layaModel, .voiceModel, .selfTest, .ready])
    }

    func testBundledSpeechRuntimeCannotBeOverriddenByEnvironment() {
        let bundled = URL(fileURLWithPath: "/Kio.app/Contents/Helpers/whisper-cli")
        let selected = SpeechRuntimeResolver.whisperExecutable(
            isBundled: true,
            bundledExecutable: bundled,
            environmentPath: "/unexpected/whisper-cli",
            developmentFallback: URL(fileURLWithPath: "/Users/test/whisper-cli")
        ) { $0 == bundled.path || $0 == "/unexpected/whisper-cli" }
        XCTAssertEqual(selected, bundled)
    }

    func testBundledSpeechRuntimeFailsClosedWhenHelperIsMissing() {
        let selected = SpeechRuntimeResolver.whisperExecutable(
            isBundled: true,
            bundledExecutable: URL(fileURLWithPath: "/Kio.app/Contents/Helpers/whisper-cli"),
            environmentPath: "/Users/test/whisper-cli",
            developmentFallback: URL(fileURLWithPath: "/Users/test/whisper-cli")
        ) { _ in false }
        XCTAssertNil(selected)
    }

    func testDevelopmentSpeechRuntimeUsesValidOverrideThenLocalFallback() {
        let fallback = URL(fileURLWithPath: "/Users/test/Library/Caches/Kio/whisper-cli")
        let overridden = SpeechRuntimeResolver.whisperExecutable(
            isBundled: false,
            bundledExecutable: URL(fileURLWithPath: "/Kio.app/Contents/Helpers/whisper-cli"),
            environmentPath: "/tmp/custom-whisper",
            developmentFallback: fallback
        ) { $0 == "/tmp/custom-whisper" || $0 == fallback.path }
        XCTAssertEqual(overridden?.path, "/tmp/custom-whisper")

        let fallbackSelected = SpeechRuntimeResolver.whisperExecutable(
            isBundled: false,
            bundledExecutable: URL(fileURLWithPath: "/Kio.app/Contents/Helpers/whisper-cli"),
            environmentPath: "relative/whisper-cli",
            developmentFallback: fallback
        ) { $0 == fallback.path }
        XCTAssertEqual(fallbackSelected, fallback)
    }

    func testStableTranscriptDetectorRequiresRepeatedCompleteClause() {
        var detector = StableTranscriptDetector()
        XCTAssertNil(detector.observe("open Calc"))
        XCTAssertNil(detector.observe("open Calculator"))
        XCTAssertEqual(detector.observe("open Calculator"), "open Calculator")
        XCTAssertNil(detector.observe("open Calculator"))
    }

    func testStableTranscriptDetectorDoesNotCommitIncompleteSearch() {
        var detector = StableTranscriptDetector()
        XCTAssertNil(detector.observe("search for"))
        XCTAssertNil(detector.observe("search for"))
        XCTAssertNil(detector.observe("search for Norbert Wiener"))
        XCTAssertEqual(detector.observe("search for Norbert Wiener"), "search for Norbert Wiener")
    }

    func testSemanticVoiceStepNormalizesWakeWordsAndConjunctions() {
        let first = SemanticVoiceStepParser.parse("Hey Kio, please open Calculator and work it out")
        let second = SemanticVoiceStepParser.parse("open calculator")
        XCTAssertEqual(first?.kind, .ensureApp)
        XCTAssertEqual(first?.argument, "calculator")
        XCTAssertEqual(first?.id, second?.id)
    }

    func testSemanticVoiceStepSeparatesMediaAndNewTabFromAppPreparation() {
        XCTAssertEqual(
            SemanticVoiceStepParser.parse("start playing whatever is on Spotify")?.kind,
            .mediaState
        )
        XCTAssertEqual(SemanticVoiceStepParser.parse("Press the play button")?.id, "media_state:playing")
        XCTAssertNil(SemanticVoiceStepParser.parse("Where is the play button?"))
        XCTAssertNil(SemanticVoiceStepParser.parse("Don't play the song"))
        XCTAssertNil(SemanticVoiceStepParser.parse("Don't create a new note"))
        XCTAssertEqual(SemanticVoiceStepParser.parse("open a new tab")?.kind, .newTab)
    }

    func testSemanticVoiceStepNormalizesNaturalAppLaunchPhrases() {
        for text in [
            "Open Notes",
            "Open up Notes",
            "Open the Notes app",
            "Can you open Notes?",
            "Can you open up Notes for me?",
            "Alright, can you open up the Notes app for me?",
            "Bring Notes up",
            "Launch Notes",
            "Show me Notes",
        ] {
            let step = SemanticVoiceStepParser.parse(text)
            XCTAssertEqual(step?.kind, .ensureApp, text)
            XCTAssertEqual(step?.argument, "notes", text)
            XCTAssertEqual(step?.id, "ensure_app:notes", text)
        }
    }

    func testSemanticVoiceStepCoversSearchMediaCreationAndExactFields() {
        let search = SemanticVoiceStepParser.parse("Can you Google search Norbert Wiener?")
        XCTAssertEqual(search?.kind, .webSearch)
        XCTAssertEqual(search?.id, "web_search:norbert wiener")

        let play = SemanticVoiceStepParser.parse("Play the song")
        XCTAssertEqual(play?.kind, .mediaState)
        XCTAssertEqual(play?.id, "media_state:playing")
        XCTAssertEqual(play?.argument, "play the song")

        let note = SemanticVoiceStepParser.parse("And once you're there, create a new note")
        XCTAssertEqual(note?.kind, .createNote)

        let recipient = SemanticVoiceStepParser.parse("Draft an email to example@gmail.com")
        XCTAssertEqual(recipient?.kind, .createEmailDraft)
        XCTAssertEqual(recipient?.id, "create_email_draft:example@gmail.com")

        let title = SemanticVoiceStepParser.parse(
            "Inside this new note, let's make the title say Hello"
        )
        XCTAssertEqual(title?.kind, .setField)
        XCTAssertEqual(title?.id, "set_field:title:hello")

        let body = SemanticVoiceStepParser.parse("Put Testing in the note")
        XCTAssertEqual(body?.kind, .setField)
        XCTAssertEqual(body?.id, "set_field:body:testing")

        XCTAssertEqual(SemanticVoiceStepParser.parse("Take a picture of me")?.kind, .capturePhoto)
        XCTAssertEqual(SemanticVoiceStepParser.parse("Open up x dot com")?.id, "navigate:https://x.com")
    }

    func testSemanticVoiceStepSplitsSafeSequentialClausesForReconciliation() {
        let steps = SemanticVoiceStepParser.parseAll(
            "Open Notes and create a new note, then name it Hello"
        )
        XCTAssertEqual(steps.map(\.id), [
            "ensure_app:notes", "create_note", "set_field:title:hello",
        ])
        XCTAssertEqual(steps.map(\.sourceText), [
            "Open Notes", "create a new note", "name it Hello",
        ])
    }

    func testSemanticVoiceStepIDsIgnorePunctuationAndWakeWordChanges() {
        let first = SemanticVoiceStepParser.parse("Hey Kio, play the song!")
        let second = SemanticVoiceStepParser.parse("Play the song.")
        XCTAssertEqual(first?.id, second?.id)
        XCTAssertNil(SemanticVoiceStepParser.parse("send the email"))
        XCTAssertNil(SemanticVoiceStepParser.parse("delete the folder"))
    }

    func testStableTranscriptDetectorUsesSemanticIdentityAcrossPunctuation() {
        var detector = StableTranscriptDetector()
        XCTAssertNil(detector.observe("Hey Kio, open Calculator"))
        XCTAssertEqual(detector.observe("open calculator."), "open calculator")
    }

    func testStableTranscriptDetectorEmitsNewClausesFromExpandedRollingHypothesis() {
        var detector = StableTranscriptDetector()
        XCTAssertTrue(detector.observeSteps("Open Notes").isEmpty)
        XCTAssertEqual(detector.observeSteps("Open Notes").map(\.id), ["ensure_app:notes"])
        XCTAssertTrue(detector.observeSteps("Open Notes and create a new note").isEmpty)
        XCTAssertEqual(
            detector.observeSteps("Open Notes and create a new note").map(\.id),
            ["create_note"]
        )
    }

    func testStreamingTranscriptAssemblerHandlesSplitAnsiAndRollingHypotheses() {
        var assembler = StreamingTranscriptAssembler()
        XCTAssertEqual(assembler.append("[Start speaking]\n\u{001B}[2"), "")
        XCTAssertEqual(assembler.append("K\r\u{001B}[2K\ropen Notes"), "open Notes")
        XCTAssertEqual(
            assembler.append("\u{001B}[2K\ropen Notes and create a new note"),
            "open Notes and create a new note"
        )
        XCTAssertEqual(assembler.append("\n"), "open Notes and create a new note")
        XCTAssertEqual(
            assembler.append("\u{001B}[2K\rcreate a new note and name it Hello"),
            "open Notes and create a new note and name it Hello"
        )
        XCTAssertEqual(
            assembler.finish(),
            "open Notes and create a new note and name it Hello"
        )
    }

    func testStreamingTranscriptAssemblerSuppressesDuplicateRollingSegments() {
        var assembler = StreamingTranscriptAssembler()
        _ = assembler.append("Hello from the current window\n")
        _ = assembler.append("Hello from the current window\n")
        XCTAssertEqual(assembler.finish(), "Hello from the current window")
    }
}
