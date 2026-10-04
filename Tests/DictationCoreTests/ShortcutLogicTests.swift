import Foundation
import Testing
@testable import DictationCore

@Suite("fn tap detection")
struct FnTapDetectorTests {
    var detector = FnTapDetector()
    let window = FnTapDetector.Configuration().doubleTapWindow

    /// Press at `down`, release at `up`; returns the actions of both events.
    mutating func tap(down: Double, up: Double, others: ShortcutModifiers = [], lastOtherInputAt: Double? = nil) -> [FnTapDetector.Action] {
        [
            detector.handle(.fnDown(otherModifiers: others, at: down)),
            detector.handle(.fnUp(otherModifiers: [], at: up, lastOtherInputAt: lastOtherInputAt)),
        ]
    }

    @Test mutating func aCleanTapFiresAfterTheDoubleTapWindow() {
        #expect(tap(down: 10, up: 10.1) == [.none, .confirmAt(10.1 + window)])
        #expect(detector.confirm(at: 10.2) == .none)
        #expect(detector.confirm(at: 10.1 + window) == .fire)
        // Only once.
        #expect(detector.confirm(at: 11) == .none)
    }

    @Test mutating func aKeyPressedWhileFnIsHeldIsACombination() {
        // e.g. fn + Delete (forward delete) or fn + arrow (Home/End).
        #expect(tap(down: 10, up: 10.2, lastOtherInputAt: 10.1) == [.none, .none])
        #expect(detector.confirm(at: 11) == .none)
    }

    @Test mutating func aKeyPressedAtTheSameMomentCountsAsDuringThePress() {
        #expect(tap(down: 10, up: 10.2, lastOtherInputAt: 9.99) == [.none, .none])
    }

    @Test mutating func typingRightAfterTheReleaseDoesNotBlockTheTap() {
        // The key came after fn was released but before the release was handled.
        #expect(tap(down: 10, up: 10.1, lastOtherInputAt: 10.3) == [.none, .confirmAt(10.1 + window)])
    }

    @Test mutating func typingShortlyBeforeFnDoesNotBlockTheTap() {
        #expect(tap(down: 10, up: 10.1, lastOtherInputAt: 9.5) == [.none, .confirmAt(10.1 + window)])
    }

    @Test mutating func aModifierPressedDuringTheHoldIsACombination() {
        _ = detector.handle(.fnDown(otherModifiers: [], at: 10))
        _ = detector.handle(.modifiersChanged(otherModifiers: [.command], at: 10.05))
        _ = detector.handle(.modifiersChanged(otherModifiers: [], at: 10.1))
        #expect(detector.handle(.fnUp(otherModifiers: [], at: 10.15, lastOtherInputAt: nil)) == .none)
    }

    @Test mutating func aModifierHeldBeforeFnIsACombination() {
        #expect(tap(down: 10, up: 10.1, others: [.shift]) == [.none, .none])
    }

    @Test mutating func releasingFnBeforeTheOtherModifierIsACombination() {
        _ = detector.handle(.fnDown(otherModifiers: [], at: 10))
        _ = detector.handle(.modifiersChanged(otherModifiers: [.option], at: 10.05))
        #expect(detector.handle(.fnUp(otherModifiers: [.option], at: 10.1, lastOtherInputAt: nil)) == .none)
        #expect(detector.handle(.modifiersChanged(otherModifiers: [], at: 10.2)) == .none)
        #expect(detector.confirm(at: 11) == .none)
    }

    @Test mutating func aLongHoldIsNotATap() {
        #expect(tap(down: 10, up: 11.5) == [.none, .none])
    }

    @Test mutating func aQuickDoublePressIsLeftToMacOS() {
        #expect(tap(down: 10, up: 10.08) == [.none, .confirmAt(10.08 + window)])
        #expect(tap(down: 10.2, up: 10.28) == [.none, .none])
        #expect(detector.confirm(at: 10.08 + window) == .none)
        #expect(detector.confirm(at: 12) == .none)
    }

    @Test mutating func aThirdPressAfterADoublePressCountsAgain() {
        _ = tap(down: 10, up: 10.08)
        _ = tap(down: 10.2, up: 10.28)
        #expect(tap(down: 11, up: 11.1) == [.none, .confirmAt(11.1 + window)])
        #expect(detector.confirm(at: 11.1 + window) == .fire)
    }

    @Test mutating func twoSeparateTapsBothFire() {
        _ = tap(down: 10, up: 10.1)
        #expect(detector.confirm(at: 10.1 + window) == .fire)
        _ = tap(down: 12, up: 12.1)
        #expect(detector.confirm(at: 12.1 + window) == .fire)
    }

    @Test mutating func aLateConfirmationStillFiresWhenTheNextPressBegins() {
        _ = tap(down: 10, up: 10.1)
        // The timer was delayed; the next press arrives after the window.
        #expect(detector.handle(.fnDown(otherModifiers: [], at: 10.9)) == .fire)
        #expect(detector.handle(.fnUp(otherModifiers: [], at: 11.0, lastOtherInputAt: nil)) == .confirmAt(11.0 + window))
    }

    @Test mutating func repeatedDownEventsAndStrayReleasesAreIgnored() {
        #expect(detector.handle(.fnUp(otherModifiers: [], at: 9, lastOtherInputAt: nil)) == .none)
        _ = detector.handle(.fnDown(otherModifiers: [], at: 10))
        #expect(detector.handle(.fnDown(otherModifiers: [], at: 10.05)) == .none)
        #expect(detector.isFnHeld)
        #expect(detector.handle(.fnUp(otherModifiers: [], at: 10.1, lastOtherInputAt: nil)) == .confirmAt(10.1 + window))
    }

    @Test mutating func resetDropsAPendingTap() {
        _ = tap(down: 10, up: 10.1)
        detector.reset()
        #expect(detector.confirm(at: 11) == .none)
        #expect(!detector.isFnHeld)
    }
}

@Suite("Shortcut validation")
struct ShortcutValidatorTests {
    func combo(_ keyCode: UInt16, _ modifiers: ShortcutModifiers) -> KeyCombo {
        KeyCombo(keyCode: keyCode, modifiers: modifiers, keyLabel: "K")
    }

    @Test(arguments: [
        (KeyCode.space, ShortcutModifiers([.option])),
        (KeyCode.space, ShortcutModifiers([.control, .shift])),
        (KeyCode.space, ShortcutModifiers([.control, .option, .command])),
        (UInt16(0x02), ShortcutModifiers([.option, .shift])),
        (UInt16(0x69), ShortcutModifiers([])), // F13 alone
        (UInt16(0x60), ShortcutModifiers([.control])), // ⌃F5
        (UInt16(0x02), ShortcutModifiers([.command, .shift])),
    ])
    func acceptsUsableCombinations(keyCode: UInt16, modifiers: ShortcutModifiers) {
        #expect(ShortcutValidator.validate(combo(keyCode, modifiers), systemShortcuts: []) == nil)
    }

    @Test(arguments: [
        (UInt16(0x02), ShortcutModifiers([]), ShortcutRejection.needsModifier),
        (UInt16(0x02), ShortcutModifiers([.shift]), .needsModifier),
        (KeyCode.space, ShortcutModifiers([]), .needsModifier),
        (UInt16(0x02), ShortcutModifiers([.command]), .appStandardShortcut),
        (UInt16(0x09), ShortcutModifiers([.command]), .appStandardShortcut), // ⌘V, used for pasting
        (KeyCode.space, ShortcutModifiers([.command]), .appStandardShortcut), // ⌘Space (Spotlight)
        (KeyCode.space, ShortcutModifiers([.control]), .systemShortcut), // input source
        (KeyCode.space, ShortcutModifiers([.control, .command]), .systemShortcut), // emoji viewer
        (KeyCode.ansi4, ShortcutModifiers([.command, .shift]), .systemShortcut), // screenshot
        (KeyCode.tab, ShortcutModifiers([.command, .shift]), .systemShortcut),
        (KeyCode.escape, ShortcutModifiers([]), .reservedKey),
        (KeyCode.escape, ShortcutModifiers([.option, .command]), .reservedKey),
        (KeyCode.jisEisu, ShortcutModifiers([.control]), .reservedKey),
        (KeyCode.jisKana, ShortcutModifiers([.option]), .reservedKey),
    ])
    func rejectsUnsafeCombinations(keyCode: UInt16, modifiers: ShortcutModifiers, expected: ShortcutRejection) {
        #expect(ShortcutValidator.validate(combo(keyCode, modifiers), systemShortcuts: []) == expected)
    }

    @Test func rejectsShortcutsEnabledInSystemSettings() {
        let taken = SystemShortcut(keyCode: 0x02, modifiers: [.control, .option])
        #expect(ShortcutValidator.validate(combo(0x02, [.control, .option]), systemShortcuts: [taken]) == .systemShortcut)
        #expect(ShortcutValidator.validate(combo(0x02, [.control, .option, .shift]), systemShortcuts: [taken]) == nil)
    }

    @Test func everyRejectionExplainsItselfInJapanese() {
        let all: [ShortcutRejection] = [.modifierOnly, .needsModifier, .fnCombination, .reservedKey, .appStandardShortcut, .systemShortcut, .registrationFailed]
        for rejection in all {
            #expect(!rejection.message.isEmpty)
        }
    }
}

@Suite("Shortcut recorder")
struct ShortcutRecordingTests {
    var recording = ShortcutRecording(systemShortcuts: [])

    mutating func key(_ keyCode: UInt16, _ modifiers: ShortcutModifiers = [], label: String = "K", isRepeat: Bool = false) -> ShortcutRecording.Outcome {
        recording.handle(.keyDown(keyCode: keyCode, modifiers: modifiers, label: label, isRepeat: isRepeat))
    }

    mutating func flags(_ keyCode: UInt16, _ modifiers: ShortcutModifiers, fn: Bool = false) -> ShortcutRecording.Outcome {
        recording.handle(.flagsChanged(keyCode: keyCode, modifiers: modifiers, fnDown: fn))
    }

    @Test mutating func fnAloneIsRecordedOnRelease() {
        #expect(flags(KeyCode.function, [], fn: true) == .none)
        #expect(flags(KeyCode.function, [], fn: false) == .recorded(.fn))
    }

    @Test mutating func fnWithAnotherKeyIsRejected() {
        _ = flags(KeyCode.function, [], fn: true)
        #expect(key(KeyCode.space, label: "Space") == .rejected(.fnCombination))
        #expect(flags(KeyCode.function, [], fn: false) == .none)
    }

    @Test mutating func fnWithAModifierIsRejectedOnRelease() {
        _ = flags(KeyCode.function, [], fn: true)
        _ = flags(0x37, [.command], fn: true)
        _ = flags(0x37, [], fn: true)
        #expect(flags(KeyCode.function, [], fn: false) == .rejected(.fnCombination))
    }

    @Test mutating func fnPressedWhileAModifierIsHeldIsRejected() {
        _ = flags(0x3A, [.option])
        _ = flags(KeyCode.function, [.option], fn: true)
        #expect(flags(KeyCode.function, [.option], fn: false) == .rejected(.fnCombination))
    }

    @Test mutating func fnPlusAFunctionKeyRecordsTheFunctionKey() {
        _ = flags(KeyCode.function, [], fn: true)
        #expect(key(0x60, label: "F5") == .recorded(.key(KeyCombo(keyCode: 0x60, modifiers: [], keyLabel: "F5"))))
    }

    @Test mutating func aModifiedKeyIsRecorded() {
        _ = flags(0x3A, [.option])
        #expect(key(KeyCode.space, [.option], label: "Space") == .recorded(.key(KeyCombo(keyCode: KeyCode.space, modifiers: [.option], keyLabel: "Space"))))
    }

    @Test mutating func escapeCancels() {
        #expect(key(KeyCode.escape) == .cancelled)
    }

    @Test mutating func aModifierAloneIsRejected() {
        #expect(flags(0x37, [.command]) == .none)
        #expect(flags(0x37, []) == .rejected(.modifierOnly))
        #expect(flags(0x38, [.shift]) == .none)
        #expect(flags(0x38, []) == .rejected(.modifierOnly))
    }

    @Test mutating func releasingModifiersAfterAKeyIsNotModifierOnly() {
        _ = flags(0x37, [.command])
        _ = key(0x02, [.command])
        #expect(flags(0x37, []) == .none)
    }

    @Test mutating func invalidThenValidInTheSameSession() {
        #expect(key(0x02, label: "D") == .rejected(.needsModifier))
        #expect(key(0x02, [.command], label: "D") == .rejected(.appStandardShortcut))
        #expect(key(0x02, [.control, .option], label: "D") == .recorded(.key(KeyCombo(keyCode: 0x02, modifiers: [.control, .option], keyLabel: "D"))))
    }

    @Test mutating func keyRepeatsAreIgnored() {
        #expect(key(0x02, [.control, .option], isRepeat: true) == .none)
    }

    @Test mutating func systemShortcutsFromSettingsAreRejected() {
        recording = ShortcutRecording(systemShortcuts: [SystemShortcut(keyCode: 0x7B, modifiers: [.control])])
        #expect(key(0x7B, [.control], label: "←") == .rejected(.systemShortcut))
    }
}

@Suite("Shortcut model")
struct ShortcutModelTests {
    @Test func displayNames() {
        #expect(Shortcut.fn.displayName == "fn")
        #expect(Shortcut.key(KeyCombo(keyCode: KeyCode.space, modifiers: [.command, .option, .control, .shift], keyLabel: "Space")).displayName == "⌃⌥⇧⌘ Space")
        #expect(Shortcut.key(KeyCombo(keyCode: 0x69, modifiers: [], keyLabel: "F13")).displayName == "F13")
        #expect(Shortcut.default == .fn)
    }

    @Test(arguments: [
        Shortcut.fn,
        Shortcut.key(KeyCombo(keyCode: KeyCode.space, modifiers: [.option], keyLabel: "Space")),
        Shortcut.key(KeyCombo(keyCode: 0x02, modifiers: [.control, .shift, .command], keyLabel: "D")),
    ])
    func encodesAndDecodes(shortcut: Shortcut) throws {
        let data = try JSONEncoder().encode(shortcut)
        #expect(try JSONDecoder().decode(Shortcut.self, from: data) == shortcut)
    }

    @Test func unknownKindsFailToDecode() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Shortcut.self, from: Data(#"{"kind":"hyper"}"#.utf8))
        }
    }
}

extension Shortcut: CustomTestStringConvertible {
    public var testDescription: String { displayName }
}
