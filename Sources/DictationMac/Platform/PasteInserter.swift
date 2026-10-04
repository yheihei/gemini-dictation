import AppKit
import ApplicationServices
import Carbon.HIToolbox
import DictationCore

/// Types text into the focused field by pasting it, then puts the user's clipboard back.
///
/// 1. Refuses without Accessibility access or if another app came to the front.
/// 2. Snapshots every clipboard item and type.
/// 3. Declares the transcript (marked transient) and posts ⌘V. The text itself is only
///    handed out when an app reads it, so the inserter knows when the paste happened.
/// 4. Restores the snapshot shortly after that read (or after a time limit if nobody
///    reads it), unless something else changed the clipboard in the meantime.
@MainActor
public final class PasteInserter: TextInserting {
    public typealias Check = @MainActor () -> Bool
    public typealias FrontmostProcess = @MainActor () -> pid_t?
    public typealias KeystrokePoster = @MainActor () -> Bool

    public struct RestorePolicy: Sendable {
        /// Never restore sooner than this after posting ⌘V.
        public var minimumDelay: TimeInterval
        /// Extra time after the target app has read the text.
        public var graceAfterRead: TimeInterval
        /// Restore anyway if nobody reads the text (for example the paste was ignored).
        public var maximumWait: TimeInterval
        public var pollInterval: TimeInterval

        public init(minimumDelay: TimeInterval = 0.6, graceAfterRead: TimeInterval = 0.4, maximumWait: TimeInterval = 5, pollInterval: TimeInterval = 0.05) {
            self.minimumDelay = minimumDelay
            self.graceAfterRead = graceAfterRead
            self.maximumWait = maximumWait
            self.pollInterval = pollInterval
        }
    }

    private struct Pending {
        var snapshot: PasteboardSnapshot
        var changeCount: Int
        var provider: TranscriptProvider
        var task: Task<Void, Never>
    }

    private let pasteboard: NSPasteboard
    private let policy: RestorePolicy
    private let source: String
    private let isPermitted: Check
    private let frontmostProcessID: FrontmostProcess
    private let postPaste: KeystrokePoster
    private var pending: Pending?

    public init(
        pasteboard: NSPasteboard = .general,
        policy: RestorePolicy = RestorePolicy(),
        source: String,
        isPermitted: @escaping Check = { AXIsProcessTrusted() },
        frontmostProcessID: @escaping FrontmostProcess = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        postPaste: @escaping KeystrokePoster = { PasteInserter.postCommandV() }
    ) {
        self.pasteboard = pasteboard
        self.policy = policy
        self.source = source
        self.isPermitted = isPermitted
        self.frontmostProcessID = frontmostProcessID
        self.postPaste = postPaste
    }

    public var hasPendingRestore: Bool {
        pending != nil
    }

    public func insert(_ text: String, into target: InsertionTarget) async throws {
        guard isPermitted() else { throw InsertionError.notPermitted }
        guard frontmostProcessID() == target.processID else { throw InsertionError.targetChanged }

        // A previous paste may still be waiting to restore; finish it first so the
        // snapshot below captures the user's real clipboard, not our transcript.
        restorePendingNow()
        // If any representation cannot be copied it could not be put back, so leave
        // the clipboard untouched and let the user copy the result explicitly instead.
        guard let snapshot = PasteboardSnapshot.capture(pasteboard) else {
            throw InsertionError.clipboardNotPreservable
        }
        let provider = TranscriptProvider(text: text)
        let changeCount = TransientPasteboardWriter.write(provider, to: pasteboard, source: source)
        guard postPaste() else {
            restore(snapshot, ifChangeCountIs: changeCount)
            throw InsertionError.eventPostingFailed
        }

        let policy = self.policy
        let postedAt = ProcessInfo.processInfo.systemUptime
        let task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                if let readAt = provider.firstReadUptime {
                    if now >= max(postedAt + policy.minimumDelay, readAt + policy.graceAfterRead) { break }
                } else if now >= postedAt + policy.maximumWait {
                    break
                }
                try? await Task.sleep(nanoseconds: UInt64(policy.pollInterval * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.restorePendingNow()
        }
        pending = Pending(snapshot: snapshot, changeCount: changeCount, provider: provider, task: task)
    }

    /// Restores a waiting snapshot immediately (also called when the app quits).
    public func restorePendingNow() {
        guard let pending else { return }
        self.pending = nil
        pending.task.cancel()
        restore(pending.snapshot, ifChangeCountIs: pending.changeCount)
    }

    @discardableResult
    func restore(_ snapshot: PasteboardSnapshot, ifChangeCountIs expected: Int) -> Bool {
        guard pasteboard.changeCount == expected else { return false }
        snapshot.restore(to: pasteboard)
        return true
    }

    /// Posts ⌘V. Requires the Accessibility permission; without it macOS drops the events.
    public static func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
