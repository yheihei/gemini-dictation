import AVFoundation
import Carbon.HIToolbox
import DictationCore
import Foundation
import Testing
@testable import DictationMac

@Suite("Shortcut presets")
struct HotKeyPresetTests {
    @Test func everyPresetUsesSpaceWithAModifier() {
        for preset in HotKeyPreset.allCases {
            #expect(preset.keyCode == UInt32(kVK_Space))
            #expect(preset.carbonModifiers != 0)
        }
        #expect(Set(HotKeyPreset.allCases.map(\.displayName)).count == HotKeyPreset.allCases.count)
    }

    @Test func modifierMapping() {
        #expect(HotKeyPreset.optionSpace.carbonModifiers == UInt32(optionKey))
        #expect(HotKeyPreset.optionShiftSpace.carbonModifiers == UInt32(optionKey | shiftKey))
        #expect(HotKeyPreset.controlShiftSpace.carbonModifiers == UInt32(controlKey | shiftKey))
        #expect(HotKeyPreset.controlOptionCommandSpace.carbonModifiers == UInt32(controlKey | optionKey | cmdKey))
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
    }

    @Test func recordingShowsTargetTimeAndControls() throws {
        let content = try #require(make(.recording))
        #expect(content.tone == .recording)
        #expect(content.message == "入力先: Editor")
        #expect(content.elapsed == 65)
        #expect(content.hint?.contains("⌥ Space") == true)
        #expect(content.actions == [.cancel, .stop])
        #expect(make(.recording, target: nil)?.message?.contains("入力先なし") == true)
    }

    @Test func processingCanBeCancelled() {
        #expect(make(.processing(attempt: 1))?.actions == [.cancel])
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
