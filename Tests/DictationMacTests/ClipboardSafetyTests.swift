import AppKit
import DictationCore
import Testing
@testable import DictationMac

/// Every test uses its own named pasteboard. The general (user) clipboard is never touched.
@MainActor
final class PrivatePasteboard {
    // Only used from the main actor; the deinit needs it to release the pasteboard.
    nonisolated(unsafe) let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.yheihei.GeminiDictation.tests.\(UUID().uuidString)"))

    deinit {
        pasteboard.releaseGlobally()
    }

    /// Two items, several types each, including binary data.
    func fillWithUserContent() {
        pasteboard.clearContents()
        let first = NSPasteboardItem()
        first.setString("ユーザーがコピーした文章", forType: .string)
        first.setString("<b>ユーザー</b>", forType: .html)
        let second = NSPasteboardItem()
        second.setData(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF]), forType: .png)
        second.setString("https://example.com/", forType: .URL)
        pasteboard.writeObjects([first, second])
    }
}

/// Declares a representation but never delivers its data, like a promise from an app
/// that has quit. Reading that type returns nil.
final class UndeliverableProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {}
}

extension PrivatePasteboard {
    static let promisedType = NSPasteboard.PasteboardType("com.example.promised-representation")

    /// One readable string plus one representation that cannot be read.
    func fillWithPartlyUnreadableContent(_ provider: UndeliverableProvider) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("読める部分", forType: .string)
        item.setDataProvider(provider, forTypes: [Self.promisedType])
        pasteboard.writeObjects([item])
    }
}

var target: InsertionTarget {
    InsertionTarget(processID: 777, bundleIdentifier: "com.example.editor", appName: "Editor", focusToken: nil)
}

@MainActor
@Suite("Clipboard snapshot and paste safety")
struct ClipboardSafetyTests {
    @Test func snapshotRestoresEveryItemAndTypeExactly() throws {
        let board = PrivatePasteboard()
        board.fillWithUserContent()
        let snapshot = try #require(PasteboardSnapshot.capture(board.pasteboard))
        #expect(snapshot.items.count == 2)

        board.pasteboard.clearContents()
        board.pasteboard.setString("別の内容", forType: .string)
        snapshot.restore(to: board.pasteboard)

        #expect(PasteboardSnapshot.capture(board.pasteboard) == snapshot)
        #expect(board.pasteboard.string(forType: .string) == "ユーザーがコピーした文章")
    }

    @Test func emptyClipboardStaysEmpty() throws {
        let board = PrivatePasteboard()
        board.pasteboard.clearContents()
        let snapshot = try #require(PasteboardSnapshot.capture(board.pasteboard))
        board.pasteboard.setString("一時的な内容", forType: .string)
        snapshot.restore(to: board.pasteboard)
        #expect(board.pasteboard.pasteboardItems?.isEmpty ?? true)
    }

    @Test func aSnapshotIsNeverPartial() {
        let board = PrivatePasteboard()
        let provider = UndeliverableProvider()
        board.fillWithPartlyUnreadableContent(provider)
        #expect(board.pasteboard.types?.contains(PrivatePasteboard.promisedType) == true)
        // Precondition: this representation is declared but reads back as nil.
        #expect(board.pasteboard.pasteboardItems?.first?.data(forType: PrivatePasteboard.promisedType) == nil)
        // Dropping the unreadable representation would lose it on restore, so no snapshot at all.
        #expect(PasteboardSnapshot.capture(board.pasteboard) == nil)
    }

    @Test func unreadableClipboardIsNeverOverwrittenByAutomaticInsertion() async {
        let board = PrivatePasteboard()
        let provider = UndeliverableProvider()
        board.fillWithPartlyUnreadableContent(provider)
        let changeCount = board.pasteboard.changeCount
        let types = board.pasteboard.types
        var posted = false
        let inserter = makeInserter(board, onPost: { posted = true })

        await #expect(throws: InsertionError.clipboardNotPreservable) {
            try await inserter.insert("結果", into: target)
        }
        #expect(!posted)
        #expect(!inserter.hasPendingRestore)
        #expect(board.pasteboard.changeCount == changeCount)
        #expect(board.pasteboard.types == types)
        #expect(board.pasteboard.string(forType: .string) == "読める部分")
    }

    @Test func transcriptIsMarkedTransientAndHandedOutOnDemand() {
        let board = PrivatePasteboard()
        let provider = TranscriptProvider(text: "文字起こし")
        let count = TransientPasteboardWriter.write(provider, to: board.pasteboard, source: "io.github.yheihei.GeminiDictation")
        #expect(count == board.pasteboard.changeCount)
        let types = board.pasteboard.types ?? []
        #expect(types.contains(.string))
        #expect(types.contains(TransientPasteboardWriter.transientType))
        #expect(types.contains(TransientPasteboardWriter.autoGeneratedType))
        #expect(board.pasteboard.string(forType: TransientPasteboardWriter.sourceType) == "io.github.yheihei.GeminiDictation")
        // Listing types does not count as reading the text.
        #expect(provider.firstReadUptime == nil)
        #expect(board.pasteboard.string(forType: .string) == "文字起こし")
        #expect(provider.firstReadUptime != nil)
    }

    static let manualRestore = PasteInserter.RestorePolicy(minimumDelay: 60, graceAfterRead: 60, maximumWait: 60, pollInterval: 0.05)

    func makeInserter(
        _ board: PrivatePasteboard,
        permitted: Bool = true,
        frontmost: pid_t? = 777,
        postSucceeds: Bool = true,
        policy: PasteInserter.RestorePolicy = manualRestore,
        onPost: @escaping @MainActor () -> Void = {}
    ) -> PasteInserter {
        PasteInserter(
            pasteboard: board.pasteboard,
            policy: policy,
            source: "tests",
            isPermitted: { permitted },
            frontmostProcessID: { frontmost },
            postPaste: {
                onPost()
                return postSucceeds
            }
        )
    }

    @Test func pastesTheTranscriptThenRestoresTheUsersClipboard() async throws {
        let board = PrivatePasteboard()
        board.fillWithUserContent()
        let original = try #require(PasteboardSnapshot.capture(board.pasteboard))
        var clipboardAtPaste: String?
        let inserter = makeInserter(board, onPost: { clipboardAtPaste = board.pasteboard.string(forType: .string) })

        try await inserter.insert("音声入力の結果", into: target)
        #expect(clipboardAtPaste == "音声入力の結果")
        #expect(inserter.hasPendingRestore)

        inserter.restorePendingNow()
        #expect(PasteboardSnapshot.capture(board.pasteboard) == original)
        #expect(!inserter.hasPendingRestore)
    }

    func waitForRestore(_ inserter: PasteInserter, upTo seconds: Double = 3) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while inserter.hasPendingRestore, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test func restoresSoonAfterTheTargetReadsTheText() async throws {
        let board = PrivatePasteboard()
        board.fillWithUserContent()
        let original = try #require(PasteboardSnapshot.capture(board.pasteboard))
        let policy = PasteInserter.RestorePolicy(minimumDelay: 0.05, graceAfterRead: 0.05, maximumWait: 30, pollInterval: 0.01)
        let inserter = makeInserter(board, policy: policy, onPost: { _ = board.pasteboard.string(forType: .string) })

        let started = ProcessInfo.processInfo.systemUptime
        try await inserter.insert("結果", into: target)
        try await waitForRestore(inserter)
        #expect(!inserter.hasPendingRestore)
        #expect(ProcessInfo.processInfo.systemUptime - started < 3)
        #expect(PasteboardSnapshot.capture(board.pasteboard) == original)
    }

    @Test func waitsForASlowAppToReadBeforeRestoring() async throws {
        let board = PrivatePasteboard()
        board.fillWithUserContent()
        let original = try #require(PasteboardSnapshot.capture(board.pasteboard))
        let policy = PasteInserter.RestorePolicy(minimumDelay: 0.02, graceAfterRead: 0.05, maximumWait: 30, pollInterval: 0.01)
        let inserter = makeInserter(board, policy: policy)

        try await inserter.insert("遅いアプリへの結果", into: target)
        try await Task.sleep(nanoseconds: 300_000_000)
        // Past the minimum delay, but nobody has read the text yet: keep it in place.
        #expect(inserter.hasPendingRestore)
        #expect(board.pasteboard.types?.contains(TransientPasteboardWriter.transientType) == true)

        // The slow app finally reads it, and only then is the clipboard put back.
        #expect(board.pasteboard.string(forType: .string) == "遅いアプリへの結果")
        try await waitForRestore(inserter)
        #expect(!inserter.hasPendingRestore)
        #expect(PasteboardSnapshot.capture(board.pasteboard) == original)
    }

    @Test func restoresAfterTheTimeLimitWhenNobodyReads() async throws {
        let board = PrivatePasteboard()
        board.fillWithUserContent()
        let original = try #require(PasteboardSnapshot.capture(board.pasteboard))
        let policy = PasteInserter.RestorePolicy(minimumDelay: 0.02, graceAfterRead: 0.02, maximumWait: 0.2, pollInterval: 0.01)
        let inserter = makeInserter(board, policy: policy)

        try await inserter.insert("結果", into: target)
        try await waitForRestore(inserter)
        #expect(!inserter.hasPendingRestore)
        #expect(PasteboardSnapshot.capture(board.pasteboard) == original)
    }

    @Test func newerClipboardContentIsNeverOverwritten() async throws {
        let board = PrivatePasteboard()
        board.fillWithUserContent()
        let inserter = makeInserter(board)
        try await inserter.insert("結果", into: target)

        // The user copies something else before the restore runs.
        board.pasteboard.clearContents()
        board.pasteboard.setString("あとからコピーした内容", forType: .string)
        inserter.restorePendingNow()

        #expect(board.pasteboard.string(forType: .string) == "あとからコピーした内容")
    }

    @Test func secondPasteKeepsTheOriginalClipboard() async throws {
        let board = PrivatePasteboard()
        board.fillWithUserContent()
        let original = try #require(PasteboardSnapshot.capture(board.pasteboard))
        let inserter = makeInserter(board)

        try await inserter.insert("一回目", into: target)
        try await inserter.insert("二回目", into: target)
        inserter.restorePendingNow()

        #expect(PasteboardSnapshot.capture(board.pasteboard) == original)
    }

    @Test func withoutAccessibilityNothingIsTouched() async {
        let board = PrivatePasteboard()
        board.fillWithUserContent()
        let before = board.pasteboard.changeCount
        var posted = false
        let inserter = makeInserter(board, permitted: false, onPost: { posted = true })

        await #expect(throws: InsertionError.notPermitted) {
            try await inserter.insert("結果", into: target)
        }
        #expect(board.pasteboard.changeCount == before)
        #expect(!posted)
    }

    @Test func anotherAppInFrontIsRefusedBeforeTouchingTheClipboard() async {
        let board = PrivatePasteboard()
        board.fillWithUserContent()
        let before = board.pasteboard.changeCount
        var posted = false
        let inserter = makeInserter(board, frontmost: 999, onPost: { posted = true })

        await #expect(throws: InsertionError.targetChanged) {
            try await inserter.insert("結果", into: target)
        }
        #expect(board.pasteboard.changeCount == before)
        #expect(!posted)
    }

    @Test func failedKeystrokeRestoresImmediately() async throws {
        let board = PrivatePasteboard()
        board.fillWithUserContent()
        let original = try #require(PasteboardSnapshot.capture(board.pasteboard))
        let inserter = makeInserter(board, postSucceeds: false)

        await #expect(throws: InsertionError.eventPostingFailed) {
            try await inserter.insert("結果", into: target)
        }
        #expect(PasteboardSnapshot.capture(board.pasteboard) == original)
        #expect(!inserter.hasPendingRestore)
    }

    @Test func explicitCopyReplacesTheClipboard() {
        let board = PrivatePasteboard()
        board.fillWithUserContent()
        SystemClipboardWriter(pasteboard: board.pasteboard).copy("コピーした結果")
        #expect(board.pasteboard.string(forType: .string) == "コピーした結果")
        #expect(board.pasteboard.pasteboardItems?.count == 1)
    }
}
