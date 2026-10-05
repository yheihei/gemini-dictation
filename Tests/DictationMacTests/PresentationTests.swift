import AppKit
import AVFoundation
import Carbon.HIToolbox
import DictationCore
import Foundation
import Testing
@testable import DictationMac

@Suite("Key codes and modifier mapping")
struct KeyMappingTests {
    @Test func coreKeyCodesMatchTheSDKConstants() {
        #expect(KeyCode.function == UInt16(kVK_Function))
        #expect(KeyCode.escape == UInt16(kVK_Escape))
        #expect(KeyCode.space == UInt16(kVK_Space))
        #expect(KeyCode.tab == UInt16(kVK_Tab))
        #expect(KeyCode.jisEisu == UInt16(kVK_JIS_Eisu))
        #expect(KeyCode.jisKana == UInt16(kVK_JIS_Kana))
        #expect(KeyCode.ansi3 == UInt16(kVK_ANSI_3))
        #expect(KeyCode.ansi5 == UInt16(kVK_ANSI_5))
        #expect(KeyCode.ansiQ == UInt16(kVK_ANSI_Q))
        let sdkFunctionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                               kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (index, code) in sdkFunctionKeys.enumerated() {
            #expect(KeyCode.functionKeyNames[UInt16(code)] == "F\(index + 1)")
        }
    }

    @Test func carbonModifierBitsRoundTrip() {
        #expect(CarbonModifiers.from([.option]) == UInt32(optionKey))
        #expect(CarbonModifiers.from([.option, .shift]) == UInt32(optionKey | shiftKey))
        #expect(CarbonModifiers.from([.control, .option, .command]) == UInt32(controlKey | optionKey | cmdKey))
        let all: ShortcutModifiers = [.control, .option, .shift, .command]
        #expect(CarbonModifiers.toShortcutModifiers(Int(CarbonModifiers.from(all))) == all)
        // Unrelated bits (for example Caps Lock) are ignored.
        #expect(CarbonModifiers.toShortcutModifiers(alphaLock | cmdKey) == [.command])
    }

    @Test func eventFlagsIgnoreCapsLockFnAndKeypad() {
        let flags: NSEvent.ModifierFlags = [.capsLock, .function, .numericPad, .option]
        #expect(KeyEventTranslation.modifiers(flags) == [.option])
        #expect(KeyEventTranslation.modifiers([.command, .shift, .control]) == [.command, .shift, .control])
    }

    @Test func keyLabels() {
        #expect(KeyEventTranslation.label(keyCode: UInt16(kVK_Space), characters: " ") == "Space")
        #expect(KeyEventTranslation.label(keyCode: UInt16(kVK_F13), characters: nil) == "F13")
        #expect(KeyEventTranslation.label(keyCode: UInt16(kVK_LeftArrow), characters: "\u{F702}") == "←")
        #expect(KeyEventTranslation.label(keyCode: UInt16(kVK_ANSI_D), characters: "d") == "D")
        #expect(KeyEventTranslation.label(keyCode: 0x5D, characters: "¥") == "¥")
        #expect(KeyEventTranslation.label(keyCode: 0x7F, characters: "\u{1B}") == "Key 127")
    }

    @Test func fnFlagsChangeCarriesOnlyModifierMetadata() {
        let change = FnKeyMonitor.FlagsChange(keyCode: KeyCode.function, fnDown: true, otherModifiers: [], timestamp: 12.5)
        #expect(change.keyCode == 63)
        #expect(change.fnDown)
        #expect(change.timestamp == 12.5)
    }
}

@Suite("Status panel content")
struct HUDContentTests {
    func make(_ phase: DictationPhase, transcript: String? = nil, canRetry: Bool = false, target: String? = "Editor") -> HUDContent? {
        HUDContent.make(
            phase: phase, elapsed: 65, limit: 300, level: 0.4, transcript: transcript,
            modelName: "Model", targetAppName: target, canRetry: canRetry, shortcut: "⌥ Space"
        )
    }

    @Test func idleHidesThePanel() {
        #expect(make(.idle) == nil)
        #expect(make(.inserted) == nil)
        #expect(make(.notice(.copied)) == nil)
        #expect(make(.notice(.recordingDiscarded)) == nil)
        #expect(make(.notice(.processingCancelled)) == nil)
    }

    @Test func recordingShowsOnlyASmallIndicator() throws {
        let content = try #require(make(.recording))
        #expect(content.tone == .recording)
        #expect(content.isCompact)
        #expect(content.title == "録音中")
        #expect(content.message == nil)
        #expect(content.elapsed == nil)
        #expect(content.level == nil)
        #expect(content.hint == nil)
        #expect(content.actions.isEmpty)
        #expect(make(.recording, target: nil) == content)
    }

    @Test func processingUsesASmallIndicator() {
        #expect(make(.processing(attempt: 1))?.isCompact == true)
        #expect(make(.processing(attempt: 1))?.actions.isEmpty == true)
        #expect(make(.processing(attempt: 2))?.title.contains("再試行") == true)
    }

    @Test func resultOffersCopyWithThePreview() throws {
        let content = try #require(make(.resultReady(.focusChanged), transcript: "本文"))
        #expect(content.transcript == "本文")
        #expect(content.actions.contains(.copy))
        #expect(!content.actions.contains(.openAccessibilitySettings))
        #expect(make(.resultReady(.accessibilityNotGranted), transcript: "x")?.actions.contains(.openAccessibilitySettings) == true)
    }

    @Test func failureActionsMatchTheProblem() {
        #expect(make(.failed(.missingAPIKey))?.actions == [.dismiss, .openSettings])
        #expect(make(.failed(.microphoneDenied))?.actions == [.dismiss, .openMicrophoneSettings])
        #expect(make(.failed(.transcription(.rateLimited(nil))), canRetry: true)?.actions == [.dismiss, .retry])
        #expect(make(.failed(.transcription(.authentication(nil))), canRetry: true)?.actions == [.dismiss, .openSettings, .retry])
    }

    @Test func serverDetailIsShownButNotTheKey() {
        let content = make(.failed(.transcription(.authentication("Key [redacted] is expired"))))
        #expect(content?.detail == "Key [redacted] is expired")
    }

    @Test func logNamesNeverContainTranscriptsOrServerText() {
        let phases: [DictationPhase] = [
            .resultReady(.appChanged("SecretApp")),
            .failed(.transcription(.authentication("secret server text"))),
            .failed(.transcription(.failed(code: "api_error", message: "secret server text"))),
            .failed(.unexpected("secret detail")),
        ]
        for phase in phases {
            #expect(!phase.logName.contains("secret"))
            #expect(!phase.logName.contains("SecretApp"))
        }
        #expect(DictationPhase.processing(attempt: 2).logName == "processing(2)")
    }

    @Test func elapsedFormatting() {
        #expect(formatElapsed(0) == "0:00")
        #expect(formatElapsed(65.9) == "1:05")
        #expect(formatElapsed(300) == "5:00")
    }

    @Test @MainActor func menuStateTitles() {
        #expect(StatusItemController.stateTitle(.recording, elapsed: 12) == "録音中 0:12")
        #expect(StatusItemController.stateTitle(.idle, elapsed: 0) == "待機中")
    }
}

@Suite("Recording format and temporary files")
struct RecordingFormatTests {
    @Test @MainActor func recordsSixteenKilohertzMonoPCM() {
        let settings = SystemAudioRecorder.settings
        #expect(settings[AVFormatIDKey] as? AudioFormatID == kAudioFormatLinearPCM)
        #expect(settings[AVSampleRateKey] as? Double == 16_000)
        #expect(settings[AVNumberOfChannelsKey] as? Int == 1)
        #expect(settings[AVLinearPCMBitDepthKey] as? Int == 16)
        #expect(settings[AVLinearPCMIsFloatKey] as? Bool == false)
        #expect(settings[AVLinearPCMIsBigEndianKey] as? Bool == false)
    }

    @Test func purgeRemovesOnlyLeftoverRecordings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gd-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try TemporaryAudioFiles.prepare(directory)
        let wav = directory.appendingPathComponent("left.wav")
        let other = directory.appendingPathComponent("keep.txt")
        try WAVFile.encodePCM16(samples: [0, 1, 2], sampleRate: 16_000).write(to: wav)
        try Data("x".utf8).write(to: other)

        TemporaryAudioFiles.purge(directory)
        #expect(!FileManager.default.fileExists(atPath: wav.path))
        #expect(FileManager.default.fileExists(atPath: other.path))

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
}

@Suite("Focus verification before typing")
struct FocusDecisionTests {
    func decide(
        front: pid_t? = 777,
        trustedAtCapture: Bool = true,
        elementCaptured: Bool = true,
        trustedNow: Bool = true,
        focusedProcess: pid_t? = 777,
        sameElement: Bool = true,
        secure: Bool = false
    ) -> TargetCheck {
        FocusDecision.evaluate(
            targetProcessID: 777,
            frontmostProcessID: front,
            frontmostName: front.map { $0 == 777 ? "Editor" : "Other" },
            trustedAtCapture: trustedAtCapture,
            elementCaptured: elementCaptured,
            trustedNow: trustedNow,
            focusedProcessID: focusedProcess,
            sameElement: sameElement,
            focusedIsSecure: secure
        )
    }

    @Test func sameAppAndSameFieldIsOK() {
        #expect(decide() == .ok)
    }

    @Test func anotherFrontmostAppIsRefused() {
        #expect(decide(front: 888) == .appChanged("Other"))
        #expect(decide(front: nil) == .appChanged(nil))
    }

    @Test func aLauncherPanelOfAnotherProcessIsRefused() {
        // Frontmost app unchanged, but keyboard focus sits in another process's panel.
        #expect(decide(focusedProcess: 999, sameElement: false) == .focusChanged)
    }

    @Test func anotherFieldInTheSameAppIsRefused() {
        #expect(decide(sameElement: false) == .focusChanged)
    }

    @Test func unidentifiedFieldsAreNotGuessed() {
        #expect(decide(elementCaptured: false) == .focusUnknown)
        #expect(decide(focusedProcess: nil, sameElement: false) == .focusUnknown)
        #expect(decide(trustedAtCapture: false, elementCaptured: false) == .focusUnknown)
    }

    @Test func onlyTextInputsOfTheFrontmostAppIdentifyTheTarget() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            #expect(FocusDecision.isVerifiableInput(ownerProcessID: 777, frontmostProcessID: 777, role: role))
        }
        // Containers can stay the same object while a channel or document changes inside them.
        for role in ["AXWebArea", "AXGroup", "AXWindow", "AXScrollArea", "AXStaticText", "AXList"] {
            #expect(!FocusDecision.isVerifiableInput(ownerProcessID: 777, frontmostProcessID: 777, role: role))
        }
        #expect(!FocusDecision.isVerifiableInput(ownerProcessID: 777, frontmostProcessID: 777, role: nil))
        #expect(!FocusDecision.isVerifiableInput(ownerProcessID: nil, frontmostProcessID: 777, role: "AXTextArea"))
        #expect(!FocusDecision.isVerifiableInput(ownerProcessID: 999, frontmostProcessID: 777, role: "AXTextArea"))
    }

    @Test func aCoarseWebAreaFallsBackToCopyEvenIfItStaysTheSame() {
        // The whole web view is focused: it is not recorded as the target...
        let captured = FocusDecision.isVerifiableInput(ownerProcessID: 777, frontmostProcessID: 777, role: "AXWebArea")
        #expect(!captured)
        // ...so even an unchanged element later cannot authorize a paste.
        #expect(decide(elementCaptured: captured, sameElement: true) == .focusUnknown)
    }

    @Test func passwordFieldsAreRefused() {
        #expect(decide(secure: true) == .secureField)
    }

    @Test func withoutAccessibilityTheInserterDecides() {
        // The paste is then refused for lack of permission, which also ends in the copy panel.
        #expect(decide(trustedAtCapture: false, elementCaptured: false, trustedNow: false, focusedProcess: nil) == .ok)
    }
}
