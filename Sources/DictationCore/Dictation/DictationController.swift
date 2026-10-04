import Foundation
import Observation

/// The dictation state machine: record → transcribe → insert (or offer copy).
///
/// Every recording/processing run gets a session number. Each asynchronous step
/// re-checks it, so a late network result after a cancel or a new recording is
/// dropped instead of being typed into whatever is focused at that moment.
@MainActor
@Observable
public final class DictationController {
    public struct Configuration: Sendable {
        /// Recording stops automatically at this length. 5 minutes of 16 kHz mono
        /// WAV stays well under the 20 MB inline request limit.
        public var maxRecordingDuration: TimeInterval
        /// Shorter recordings are discarded without contacting the API.
        public var minimumDuration: TimeInterval
        /// Recordings whose peak never exceeds this level are treated as silence and not sent.
        public var silenceThresholdDecibels: Double
        /// Interval for the elapsed-time/level meter. `nil` disables it (tests drive `updateMeter()`).
        public var meterInterval: Double?
        /// How long transient notices stay visible. `nil` keeps them until dismissed.
        public var noticeDuration: Double?
        public var retryPolicy: RetryPolicy

        public init(
            maxRecordingDuration: TimeInterval = 300,
            minimumDuration: TimeInterval = 0.5,
            silenceThresholdDecibels: Double = -50,
            meterInterval: Double? = 0.1,
            noticeDuration: Double? = 2.0,
            retryPolicy: RetryPolicy = RetryPolicy()
        ) {
            self.maxRecordingDuration = maxRecordingDuration
            self.minimumDuration = minimumDuration
            self.silenceThresholdDecibels = silenceThresholdDecibels
            self.meterInterval = meterInterval
            self.noticeDuration = noticeDuration
            self.retryPolicy = retryPolicy
        }
    }

    public private(set) var phase: DictationPhase = .idle
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var level: Double = 0
    /// Last successful transcript, kept in memory only so it can be copied. Never written to disk.
    public private(set) var lastTranscript: String?
    public private(set) var activeModel: GeminiModel?
    public private(set) var targetAppName: String?
    public private(set) var hasPendingAudio = false

    @ObservationIgnored public var onPhaseChange: (@MainActor (DictationPhase) -> Void)?
    @ObservationIgnored public let configuration: Configuration

    @ObservationIgnored private let recorder: AudioRecording
    @ObservationIgnored private let microphone: MicrophoneAuthorizing
    @ObservationIgnored private let apiKeys: APIKeyProviding
    @ObservationIgnored private let models: ModelProviding
    @ObservationIgnored private let transcriber: Transcribing
    @ObservationIgnored private let focus: FocusTracking
    @ObservationIgnored private let inserter: TextInserting
    @ObservationIgnored private let clipboard: ClipboardWriting
    @ObservationIgnored private let sleeper: Sleeping

    @ObservationIgnored private var session = 0
    @ObservationIgnored private var target: InsertionTarget?
    /// Audio kept only for an explicit retry after a failure.
    @ObservationIgnored private var pendingClip: AudioClip? {
        didSet { hasPendingAudio = pendingClip != nil }
    }
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var isInserting = false
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored var processingTask: Task<Void, Never>?

    public init(
        recorder: AudioRecording,
        microphone: MicrophoneAuthorizing,
        apiKeys: APIKeyProviding,
        models: ModelProviding,
        transcriber: Transcribing,
        focus: FocusTracking,
        inserter: TextInserting,
        clipboard: ClipboardWriting,
        sleeper: Sleeping = TaskSleeper(),
        configuration: Configuration = Configuration()
    ) {
        self.recorder = recorder
        self.microphone = microphone
        self.apiKeys = apiKeys
        self.models = models
        self.transcriber = transcriber
        self.focus = focus
        self.inserter = inserter
        self.clipboard = clipboard
        self.sleeper = sleeper
        self.configuration = configuration
    }

    public var canRetry: Bool {
        if case .failed = phase { return hasPendingAudio }
        return false
    }

    // MARK: - Commands

    /// Shortcut / menu action: start when idle, stop when recording, ignore while processing.
    public func toggle() async {
        switch phase {
        case .recording:
            stop()
        case .processing:
            break
        default:
            await start()
        }
    }

    public func start() async {
        guard !isStarting, !phase.isBusy else { return }
        isStarting = true
        defer { isStarting = false }
        cancelNoticeTimer()
        session += 1
        let current = session
        pendingClip = nil
        target = nil
        targetAppName = nil

        // Check the key before touching the microphone so nothing is recorded in vain.
        do {
            guard let key = try apiKeys.apiKey(), !key.isEmpty else {
                setPhase(.failed(.missingAPIKey))
                return
            }
        } catch {
            setPhase(.failed(.apiKeyUnavailable))
            return
        }

        switch microphone.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            // The system prompt appears here, after an explicit user action. Recording
            // does not start automatically afterwards; the user presses the shortcut again.
            let granted = await microphone.requestAccess()
            guard current == session else { return }
            if granted {
                showTransient(.notice(.microphoneGranted), durationScale: 2)
            } else {
                setPhase(.failed(.microphoneDenied))
            }
            return
        case .denied, .restricted:
            setPhase(.failed(.microphoneDenied))
            return
        }

        target = focus.captureTarget()
        targetAppName = target?.appName
        do {
            try recorder.startRecording()
        } catch {
            target = nil
            targetAppName = nil
            setPhase(.failed(.recordingFailed))
            return
        }
        elapsed = 0
        level = 0
        recorder.interruptionHandler = { [weak self] _ in
            self?.recordingInterrupted(session: current)
        }
        setPhase(.recording)
        startMeter(session: current)
    }

    public func stop() {
        guard phase == .recording else { return }
        stopMeter()
        recorder.interruptionHandler = nil
        let clip: AudioClip
        do {
            clip = try recorder.stopRecording()
        } catch {
            setPhase(.failed(.recordingFailed))
            return
        }
        if let info = try? WAVFile.analyze(clip.data) {
            if info.duration < configuration.minimumDuration {
                showTransient(.notice(.tooShort))
                return
            }
            if let peak = info.peakDecibels, peak < configuration.silenceThresholdDecibels {
                showTransient(.notice(.silence))
                return
            }
        }
        pendingClip = clip
        beginProcessing()
    }

    public func cancel() {
        switch phase {
        case .recording:
            stopMeter()
            recorder.interruptionHandler = nil
            recorder.cancelRecording()
            session += 1
            pendingClip = nil
            target = nil
            showTransient(.notice(.recordingDiscarded))
        case .processing:
            // Once the paste has been posted it cannot be taken back.
            guard !isInserting else { return }
            session += 1
            processingTask?.cancel()
            processingTask = nil
            pendingClip = nil
            target = nil
            showTransient(.notice(.processingCancelled))
        default:
            dismiss()
        }
    }

    /// Re-sends the kept recording after a failure (for example after fixing the key).
    public func retry() {
        guard case .failed = phase, pendingClip != nil else { return }
        cancelNoticeTimer()
        session += 1
        beginProcessing()
    }

    /// Closes a result, error or notice and drops any kept audio.
    public func dismiss() {
        guard !phase.isBusy else { return }
        cancelNoticeTimer()
        pendingClip = nil
        setPhase(.idle)
    }

    public func copyLastTranscript() {
        guard let lastTranscript else { return }
        clipboard.copy(lastTranscript)
        if !phase.isBusy {
            showTransient(.notice(.copied))
        }
    }

    /// Reads elapsed time and level from the recorder and enforces the length limit.
    func updateMeter() {
        guard phase == .recording else { return }
        elapsed = recorder.elapsedTime
        level = recorder.normalizedLevel()
        if elapsed >= configuration.maxRecordingDuration {
            stop()
        }
    }

    // MARK: - Processing

    private func beginProcessing() {
        guard let clip = pendingClip else { return }
        let current = session
        let model = models.selectedModel
        activeModel = model
        setPhase(.processing(attempt: 1))
        processingTask = Task { [weak self] in
            await self?.runTranscription(clip: clip, model: model, session: current)
        }
    }

    private func runTranscription(clip: AudioClip, model: GeminiModel, session current: Int) async {
        var attempt = 1
        while true {
            let key: String
            do {
                guard let stored = try apiKeys.apiKey(), !stored.isEmpty else {
                    if isProcessing(current) { setPhase(.failed(.missingAPIKey)) }
                    return
                }
                key = stored
            } catch {
                if isProcessing(current) { setPhase(.failed(.apiKeyUnavailable)) }
                return
            }

            do {
                let text = try await transcriber.transcribe(clip, model: model, apiKey: key)
                guard isProcessing(current), !Task.isCancelled else { return }
                await deliver(text, session: current)
                return
            } catch is CancellationError {
                // A cancellation this task did not ask for must not leave the panel spinning.
                if isProcessing(current), !Task.isCancelled {
                    setPhase(.failed(.transcription(.network(code: URLError.Code.cancelled.rawValue))))
                }
                return
            } catch {
                guard isProcessing(current), !Task.isCancelled else { return }
                if let delay = configuration.retryPolicy.delay(after: error, attempt: attempt) {
                    attempt += 1
                    setPhase(.processing(attempt: attempt))
                    do {
                        try await sleeper.sleep(seconds: delay)
                    } catch {
                        return
                    }
                    guard isProcessing(current), !Task.isCancelled else { return }
                    continue
                }
                if let geminiError = error as? GeminiError {
                    setPhase(.failed(.transcription(geminiError)))
                } else {
                    setPhase(.failed(.unexpected(String(describing: type(of: error)))))
                }
                return
            }
        }
    }

    private func deliver(_ text: String, session current: Int) async {
        pendingClip = nil
        guard !text.isEmpty else {
            showTransient(.notice(.noSpeechRecognized))
            return
        }
        lastTranscript = text

        let check = focus.check(target)
        guard check == .ok, let target else {
            setPhase(.resultReady(Self.reason(for: check)))
            return
        }
        isInserting = true
        defer { isInserting = false }
        do {
            try await inserter.insert(text, into: target)
            guard current == session else { return }
            showTransient(.inserted)
        } catch let error as InsertionError {
            guard current == session else { return }
            setPhase(.resultReady(ResultReason(error)))
        } catch {
            guard current == session else { return }
            setPhase(.resultReady(.insertionFailed))
        }
    }

    private static func reason(for check: TargetCheck) -> ResultReason {
        switch check {
        case .ok, .noTarget: return .noTarget
        case .appChanged(let name): return .appChanged(name)
        case .focusChanged: return .focusChanged
        case .focusUnknown: return .focusUnknown
        case .secureField: return .secureField
        }
    }

    // MARK: - Helpers

    private func isProcessing(_ candidate: Int) -> Bool {
        candidate == session && phase.isProcessing
    }

    private func setPhase(_ newPhase: DictationPhase) {
        guard newPhase != phase else { return }
        // Kept audio exists only for "retry"; leaving the failure any other way drops it.
        if case .failed = phase, !newPhase.isProcessing {
            pendingClip = nil
        }
        phase = newPhase
        onPhaseChange?(newPhase)
    }

    private func showTransient(_ newPhase: DictationPhase, durationScale: Double = 1) {
        setPhase(newPhase)
        cancelNoticeTimer()
        guard let duration = configuration.noticeDuration else { return }
        let current = session
        let sleeper = self.sleeper
        noticeTask = Task { [weak self] in
            do {
                try await sleeper.sleep(seconds: duration * durationScale)
            } catch {
                return
            }
            guard let self, self.session == current, self.phase == newPhase else { return }
            self.setPhase(.idle)
        }
    }

    private func cancelNoticeTimer() {
        noticeTask?.cancel()
        noticeTask = nil
    }

    private func startMeter(session current: Int) {
        guard let interval = configuration.meterInterval else { return }
        let sleeper = self.sleeper
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleeper.sleep(seconds: interval)
                } catch {
                    return
                }
                guard let self, self.session == current, self.phase == .recording else { return }
                self.updateMeter()
            }
        }
    }

    private func stopMeter() {
        meterTask?.cancel()
        meterTask = nil
    }

    private func recordingInterrupted(session current: Int) {
        guard current == session, phase == .recording else { return }
        stopMeter()
        recorder.interruptionHandler = nil
        recorder.cancelRecording()
        target = nil
        setPhase(.failed(.recordingFailed))
    }
}
