import Foundation
import Testing
@testable import DictationCore

@MainActor
@Suite("Dictation state machine")
struct DictationControllerTests {
    @Test func fnHoldStartsAndANewTapStopsRecording() async {
        let transcriber = GatedTranscriber()
        let harness = Harness(transcriber: transcriber)
        var detector = FnHoldDetector()
        _ = detector.handle(.fnDown(otherModifiers: [], at: 10))
        if detector.confirm(at: 10.5, lastOtherInputAt: nil) == .fire {
            await harness.controller.toggle()
        }
        #expect(harness.controller.phase == .recording)
        #expect(detector.confirm(at: 12, lastOtherInputAt: nil) == .none)
        detector.allowsTap = true
        #expect(detector.handle(.fnUp(at: 12.1, lastOtherInputAt: nil)) == .none)
        #expect(harness.controller.phase == .recording)
        #expect(harness.recorder.stopCount == 0)

        _ = detector.handle(.fnDown(otherModifiers: [], at: 15))
        if detector.handle(.fnUp(at: 15.1, lastOtherInputAt: nil)) == .fire {
            await harness.controller.toggle()
        }
        #expect(harness.controller.phase.isProcessing)
        #expect(harness.recorder.startCount == 1)
        #expect(harness.recorder.stopCount == 1)
        detector.allowsTap = false
        _ = detector.handle(.fnUp(at: 16, lastOtherInputAt: nil))
        _ = detector.handle(.fnDown(otherModifiers: [], at: 20))
        if detector.confirm(at: 20.5, lastOtherInputAt: nil) == .fire {
            await harness.controller.toggle()
        }
        #expect(harness.controller.phase.isProcessing)
        #expect(harness.recorder.startCount == 1)
        harness.controller.cancel()
        await transcriber.gate.open(with: .success("test"))
    }

    // MARK: Preconditions

    @Test func missingKeyStopsBeforeTheMicrophoneIsTouched() async {
        let harness = Harness(transcriber: ScriptedTranscriber([]))
        harness.apiKeys.key = nil
        await harness.controller.toggle()
        #expect(harness.controller.phase == .failed(.missingAPIKey))
        #expect(harness.controller.phase.isBusy == false)
        #expect(harness.microphone.statusChecks == 0)
        #expect(harness.microphone.requests == 0)
        #expect(harness.recorder.startCount == 0)
        if case .failed(let failure) = harness.controller.phase {
            #expect(failure.needsSettings)
        }
    }

    @Test func keychainFailureIsReported() async {
        let harness = Harness(transcriber: ScriptedTranscriber([]))
        harness.apiKeys.error = KeychainReadError()
        await harness.controller.toggle()
        #expect(harness.controller.phase == .failed(.apiKeyUnavailable))
        #expect(harness.recorder.startCount == 0)
    }

    @Test func firstUseAsksForTheMicrophoneOnceAndDoesNotStartRecording() async {
        let harness = Harness(transcriber: ScriptedTranscriber([]))
        harness.microphone.status = .notDetermined
        await harness.controller.toggle()
        #expect(harness.microphone.requests == 1)
        #expect(harness.recorder.startCount == 0)
        #expect(harness.controller.phase == .notice(.microphoneGranted))

        // The next explicit press records.
        await harness.controller.toggle()
        #expect(harness.microphone.requests == 1)
        #expect(harness.controller.phase == .recording)
    }

    @Test func deniedMicrophoneNeverPromptsOrRecords() async {
        let harness = Harness(transcriber: ScriptedTranscriber([]))
        harness.microphone.status = .denied
        await harness.controller.toggle()
        #expect(harness.controller.phase == .failed(.microphoneDenied))
        #expect(harness.microphone.requests == 0)
        #expect(harness.recorder.startCount == 0)
    }

    @Test func refusedPromptIsReported() async {
        let harness = Harness(transcriber: ScriptedTranscriber([]))
        harness.microphone.status = .notDetermined
        harness.microphone.grantOnRequest = false
        await harness.controller.toggle()
        #expect(harness.controller.phase == .failed(.microphoneDenied))
        #expect(harness.recorder.startCount == 0)
    }

    @Test func recorderStartFailureIsReported() async {
        let harness = Harness(transcriber: ScriptedTranscriber([]))
        harness.recorder.startError = KeychainReadError()
        await harness.controller.toggle()
        #expect(harness.controller.phase == .failed(.recordingFailed))
    }

    // MARK: Happy path

    @Test func dictationIsInsertedIntoTheOriginalTarget() async throws {
        let transcriber = ScriptedTranscriber([.success("今日は晴れです。")])
        let harness = Harness(transcriber: transcriber)
        var phases: [DictationPhase] = []
        harness.controller.onPhaseChange = { phases.append($0) }

        await harness.controller.toggle()
        #expect(harness.controller.phase == .recording)
        #expect(harness.focus.captureCount == 1)
        #expect(harness.controller.targetAppName == "Editor")

        await harness.controller.toggle()
        await harness.controller.processingTask?.value

        #expect(harness.controller.phase == .inserted)
        #expect(phases == [.recording, .processing(attempt: 1), .inserted])
        #expect(harness.inserter.inserted.map(\.text) == ["今日は晴れです。"])
        #expect(harness.inserter.inserted.first?.processID == 4242)
        #expect(harness.controller.lastTranscript == "今日は晴れです。")
        #expect(harness.controller.hasPendingAudio == false)

        let calls = await transcriber.calls
        #expect(calls.count == 1)
        #expect(calls.first?.modelID == ModelCatalog.defaultModelID)
        #expect(calls.first?.apiKey == Fixtures.apiKey)
        #expect(calls.first?.audio == harness.recorder.clip.data)
    }

    @Test func shortcutIsIgnoredWhileProcessing() async {
        let transcriber = GatedTranscriber()
        let harness = Harness(transcriber: transcriber)
        await harness.controller.toggle()
        await harness.controller.toggle()
        await transcriber.gate.waitForArrivals(1)

        await harness.controller.toggle()
        #expect(harness.controller.phase == .processing(attempt: 1))
        #expect(harness.recorder.startCount == 1)

        await transcriber.gate.open(with: .success("完了"))
        await harness.controller.processingTask?.value
        #expect(harness.controller.phase == .inserted)
    }

    // MARK: Cancellation and races

    @Test func cancellingWhileRecordingDiscardsTheAudio() async {
        let transcriber = ScriptedTranscriber([.success("送られてはいけない")])
        let harness = Harness(transcriber: transcriber)
        await harness.controller.toggle()
        harness.controller.cancel()
        #expect(harness.recorder.cancelCount == 1)
        #expect(harness.recorder.stopCount == 0)
        #expect(harness.controller.phase == .notice(.recordingDiscarded))
        #expect(await transcriber.calls.isEmpty)
    }

    @Test func aResultArrivingAfterCancelIsNeverInserted() async {
        let transcriber = GatedTranscriber()
        let harness = Harness(transcriber: transcriber)
        await harness.controller.toggle()
        await harness.controller.toggle()
        await transcriber.gate.waitForArrivals(1)
        let task = harness.controller.processingTask

        harness.controller.cancel()
        #expect(harness.controller.phase == .notice(.processingCancelled))

        // The response still comes back (the mock ignores cancellation).
        await transcriber.gate.open(with: .success("遅れて届いた結果"))
        await task?.value

        #expect(harness.inserter.inserted.isEmpty)
        #expect(harness.controller.lastTranscript == nil)
        #expect(harness.controller.phase == .notice(.processingCancelled))
    }

    @Test func anOldResultCannotLandInANewRecording() async {
        let transcriber = GatedTranscriber()
        let harness = Harness(transcriber: transcriber)
        await harness.controller.toggle()
        await harness.controller.toggle()
        await transcriber.gate.waitForArrivals(1)
        let oldTask = harness.controller.processingTask

        harness.controller.cancel()
        await harness.controller.toggle()
        #expect(harness.controller.phase == .recording)

        await transcriber.gate.open(with: .success("前回の結果"))
        await oldTask?.value
        #expect(harness.controller.phase == .recording)
        #expect(harness.inserter.inserted.isEmpty)
    }

    @Test func cancelDuringRetryBackoffStopsFurtherRequests() async {
        let transcriber = ScriptedTranscriber([.failure(.server(status: 503, message: nil)), .success("x")])
        let harness = Harness(transcriber: transcriber)
        var cancelled = false
        harness.controller.onPhaseChange = { phase in
            // Cancel as soon as the automatic retry is announced.
            if phase == .processing(attempt: 2), !cancelled {
                cancelled = true
                harness.controller.cancel()
            }
        }
        await harness.dictate()
        #expect(await transcriber.calls.count == 1)
        #expect(harness.inserter.inserted.isEmpty)
        #expect(harness.controller.phase == .notice(.processingCancelled))
    }

    // MARK: Wrong-target protection

    @Test func focusChangeOffersCopyInsteadOfTyping() async {
        let harness = Harness(transcriber: ScriptedTranscriber([.success("コピー用の結果")]))
        harness.focus.checkResult = .focusChanged
        await harness.dictate()
        #expect(harness.controller.phase == .resultReady(.focusChanged))
        #expect(harness.inserter.inserted.isEmpty)
        #expect(harness.clipboard.copied.isEmpty)

        harness.controller.copyLastTranscript()
        #expect(harness.clipboard.copied == ["コピー用の結果"])
        #expect(harness.controller.phase == .notice(.copied))
    }

    @Test func appSwitchOffersCopy() async {
        let harness = Harness(transcriber: ScriptedTranscriber([.success("結果")]))
        harness.focus.checkResult = .appChanged("Safari")
        await harness.dictate()
        #expect(harness.controller.phase == .resultReady(.appChanged("Safari")))
        #expect(harness.inserter.inserted.isEmpty)
    }

    @Test func noTargetOffersCopy() async {
        let harness = Harness(transcriber: ScriptedTranscriber([.success("結果")]))
        harness.focus.captured = nil
        await harness.dictate()
        #expect(harness.controller.phase == .resultReady(.noTarget))
        #expect(harness.inserter.inserted.isEmpty)
    }

    @Test func passwordFieldIsNeverTypedInto() async {
        let harness = Harness(transcriber: ScriptedTranscriber([.success("秘密")]))
        harness.focus.checkResult = .secureField
        await harness.dictate()
        #expect(harness.controller.phase == .resultReady(.secureField))
        #expect(harness.inserter.inserted.isEmpty)
    }

    @Test func clipboardThatCannotBePreservedOffersCopy() async {
        let harness = Harness(transcriber: ScriptedTranscriber([.success("結果")]))
        harness.inserter.error = .clipboardNotPreservable
        await harness.dictate()
        #expect(harness.controller.phase == .resultReady(.clipboardNotPreservable))
        #expect(harness.clipboard.copied.isEmpty)
        harness.controller.copyLastTranscript()
        #expect(harness.clipboard.copied == ["結果"])
    }

    @Test func missingAccessibilityPermissionOffersCopy() async {
        let harness = Harness(transcriber: ScriptedTranscriber([.success("結果")]))
        harness.inserter.error = .notPermitted
        await harness.dictate()
        #expect(harness.controller.phase == .resultReady(.accessibilityNotGranted))
        #expect(harness.controller.lastTranscript == "結果")
    }

    // MARK: Nothing worth sending

    @Test func tooShortRecordingIsNotSent() async {
        let transcriber = ScriptedTranscriber([.success("x")])
        let harness = Harness(transcriber: transcriber)
        harness.recorder.clip = Fixtures.clip(seconds: 0.2)
        await harness.dictate()
        #expect(harness.controller.phase == .notice(.tooShort))
        #expect(await transcriber.calls.isEmpty)
    }

    @Test func silentRecordingIsNotSent() async {
        let transcriber = ScriptedTranscriber([.success("x")])
        let harness = Harness(transcriber: transcriber)
        harness.recorder.clip = AudioClip(data: Fixtures.silentWAV(seconds: 2), mimeType: "audio/wav")
        await harness.dictate()
        #expect(harness.controller.phase == .notice(.silence))
        #expect(await transcriber.calls.isEmpty)
    }

    @Test func veryQuietButAudibleSpeechIsSent() async {
        let transcriber = ScriptedTranscriber([.success("小さな声")])
        let harness = Harness(transcriber: transcriber)
        harness.recorder.clip = Fixtures.clip(seconds: 1, amplitude: 0.01) // about -40 dBFS
        await harness.dictate()
        #expect(await transcriber.calls.count == 1)
    }

    @Test func emptyTranscriptIsNotInserted() async {
        let harness = Harness(transcriber: ScriptedTranscriber([.success("")]))
        await harness.dictate()
        #expect(harness.controller.phase == .notice(.noSpeechRecognized))
        #expect(harness.inserter.inserted.isEmpty)
    }

    // MARK: Errors and retry

    @Test func transientErrorsAreRetriedAutomatically() async {
        let transcriber = ScriptedTranscriber([.failure(.server(status: 503, message: nil)), .success("再試行で成功")])
        let harness = Harness(transcriber: transcriber)
        var phases: [DictationPhase] = []
        harness.controller.onPhaseChange = { phases.append($0) }
        await harness.dictate()
        #expect(harness.controller.phase == .inserted)
        #expect(phases.contains(.processing(attempt: 2)))
        #expect(harness.sleeper.delays == [1.0])
        #expect(await transcriber.calls.count == 2)
    }

    @Test func automaticRetriesStopAtThreeAttempts() async {
        let transcriber = ScriptedTranscriber(Array(repeating: .failure(.rateLimited(nil)), count: 5))
        let harness = Harness(transcriber: transcriber)
        await harness.dictate()
        #expect(harness.controller.phase == .failed(.transcription(.rateLimited(nil))))
        #expect(await transcriber.calls.count == 3)
        #expect(harness.sleeper.delays == [1.0, 3.0])
    }

    @Test func permanentErrorKeepsTheAudioForAnExplicitRetry() async {
        let transcriber = ScriptedTranscriber([.failure(.authentication(nil)), .success("キー修正後")])
        let harness = Harness(transcriber: transcriber)
        await harness.dictate()
        #expect(harness.controller.phase == .failed(.transcription(.authentication(nil))))
        #expect(harness.controller.canRetry)
        #expect(await transcriber.calls.count == 1)

        harness.controller.retry()
        await harness.controller.processingTask?.value
        #expect(harness.controller.phase == .inserted)
        let calls = await transcriber.calls
        #expect(calls.count == 2)
        #expect(calls[0].audio == calls[1].audio)
        #expect(harness.controller.canRetry == false)
    }

    @Test func retryUsesTheModelSelectedNow() async {
        let transcriber = ScriptedTranscriber([.failure(.modelNotFound(nil)), .success("ok")])
        let harness = Harness(transcriber: transcriber)
        await harness.dictate()
        harness.models.selectedModel = ModelCatalog.model(for: "gemini-3.1-flash-lite")
        harness.controller.retry()
        await harness.controller.processingTask?.value
        #expect(await transcriber.calls.map(\.modelID) == [ModelCatalog.defaultModelID, "gemini-3.1-flash-lite"])
    }

    @Test func dismissingAFailureDropsTheAudio() async {
        let harness = Harness(transcriber: ScriptedTranscriber([.failure(.timedOut)]))
        await harness.dictate()
        #expect(harness.controller.canRetry)
        harness.controller.dismiss()
        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.canRetry == false)
        harness.controller.retry()
        #expect(harness.controller.phase == .idle)
    }

    @Test func anUnrequestedCancellationDoesNotLeaveTheAppProcessing() async {
        let harness = Harness(transcriber: SpuriouslyCancellingTranscriber())
        await harness.dictate()
        #expect(harness.controller.phase == .failed(.transcription(.network(code: URLError.Code.cancelled.rawValue))))
        #expect(harness.controller.canRetry)
    }

    @Test func leavingAFailureOtherThanByRetryDropsTheKeptAudio() async {
        let harness = Harness(transcriber: ScriptedTranscriber([.success("前回の結果"), .failure(.timedOut)]))
        await harness.dictate()
        await harness.dictate()
        #expect(harness.controller.phase == .failed(.transcription(.timedOut)))
        #expect(harness.controller.hasPendingAudio)

        // "Copy last result" from the menu leaves the failure without retrying.
        harness.controller.copyLastTranscript()
        #expect(harness.clipboard.copied == ["前回の結果"])
        #expect(harness.controller.phase == .notice(.copied))
        #expect(harness.controller.hasPendingAudio == false)
    }

    @Test func keyRemovedBeforeSendingIsReported() async {
        let transcriber = GatedTranscriber()
        let harness = Harness(transcriber: transcriber)
        await harness.controller.toggle()
        harness.apiKeys.key = nil
        await harness.controller.toggle()
        await harness.controller.processingTask?.value
        #expect(harness.controller.phase == .failed(.missingAPIKey))
    }

    // MARK: Recording lifecycle

    @Test func recordingStopsAutomaticallyAtTheLengthLimit() async {
        let transcriber = ScriptedTranscriber([.success("長い口述")])
        let harness = Harness(transcriber: transcriber)
        await harness.controller.toggle()
        harness.recorder.elapsedTime = 120
        harness.controller.updateMeter()
        #expect(harness.controller.phase == .recording)
        #expect(harness.controller.elapsed == 120)

        harness.recorder.elapsedTime = 300
        harness.controller.updateMeter()
        #expect(harness.controller.phase == .processing(attempt: 1))
        await harness.controller.processingTask?.value
        #expect(harness.controller.phase == .inserted)
    }

    @Test func deviceInterruptionEndsTheRecording() async {
        let transcriber = ScriptedTranscriber([.success("x")])
        let harness = Harness(transcriber: transcriber)
        await harness.controller.toggle()
        harness.recorder.interruptionHandler?(KeychainReadError())
        #expect(harness.controller.phase == .failed(.recordingFailed))
        #expect(harness.recorder.cancelCount == 1)
        #expect(await transcriber.calls.isEmpty)
    }

    @Test func noticesReturnToIdleOnTheirOwn() async {
        let harness = Harness(
            transcriber: ScriptedTranscriber([.success("x")]),
            configuration: .init(meterInterval: nil, noticeDuration: 0.01)
        )
        await harness.dictate()
        #expect(harness.controller.phase == .inserted)
        for _ in 0..<50 where harness.controller.phase != .idle {
            await Task.yield()
        }
        #expect(harness.controller.phase == .idle)
    }

    @Test func meterRunsWhileRecording() async throws {
        let harness = Harness(
            transcriber: ScriptedTranscriber([]),
            configuration: .init(meterInterval: 0.01, noticeDuration: nil)
        )
        harness.recorder.elapsedTime = 3
        harness.recorder.level = 0.7
        await harness.controller.toggle()
        for _ in 0..<50 where harness.controller.elapsed == 0 {
            await Task.yield()
        }
        #expect(harness.controller.elapsed == 3)
        #expect(harness.controller.level == 0.7)
        harness.controller.cancel()
    }
}
