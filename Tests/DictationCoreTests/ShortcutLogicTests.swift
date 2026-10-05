import Foundation
import Testing
@testable import DictationCore

@Suite("fn hold detection")
struct FnHoldDetectorTests {
    var detector = FnHoldDetector()

    @Test mutating func aHoldFiresAtTheThresholdOnlyOnceUntilReleased() {
        #expect(detector.handle(.fnDown(otherModifiers: [], at: 10)) == .confirmAt(10.5))
        #expect(detector.confirm(at: 10.499, lastOtherInputAt: nil) == .none)
        #expect(detector.confirm(at: 10.5, lastOtherInputAt: nil) == .fire)
        #expect(detector.confirm(at: 15, lastOtherInputAt: nil) == .none)
        #expect(detector.handle(.fnDown(otherModifiers: [], at: 15)) == .none)
        #expect(detector.handle(.fnUp(at: 15.1, lastOtherInputAt: nil)) == .none)
        #expect(detector.confirm(at: 20, lastOtherInputAt: nil) == .none)
        #expect(detector.handle(.fnDown(otherModifiers: [], at: 21)) == .confirmAt(21.5))
        #expect(detector.confirm(at: 21.5, lastOtherInputAt: nil) == .fire)
    }

    @Test mutating func shortAndDoublePressesNeverFire() {
        _ = detector.handle(.fnDown(otherModifiers: [], at: 10))
        _ = detector.handle(.fnUp(at: 10.1, lastOtherInputAt: nil))
        #expect(detector.confirm(at: 10.5, lastOtherInputAt: nil) == .none)
        _ = detector.handle(.fnDown(otherModifiers: [], at: 10.2))
        _ = detector.handle(.fnUp(at: 10.3, lastOtherInputAt: nil))
        #expect(detector.confirm(at: 10.7, lastOtherInputAt: nil) == .none)
    }

    @Test(arguments: [ShortcutModifiers.command, .option, .control, .shift])
    mutating func aModifierHeldBeforeFnBlocksTheHold(_ modifier: ShortcutModifiers) {
        #expect(detector.handle(.fnDown(otherModifiers: modifier, at: 10)) == .none)
        _ = detector.handle(.modifiersChanged(otherModifiers: []))
        #expect(detector.confirm(at: 10.5, lastOtherInputAt: nil) == .none)
    }

    @Test mutating func aModifierPressedAndReleasedDuringTheHoldBlocksIt() {
        _ = detector.handle(.fnDown(otherModifiers: [], at: 10))
        _ = detector.handle(.modifiersChanged(otherModifiers: [.option]))
        _ = detector.handle(.modifiersChanged(otherModifiers: []))
        #expect(detector.confirm(at: 10.5, lastOtherInputAt: nil) == .none)
        _ = detector.handle(.fnUp(at: 10.6, lastOtherInputAt: nil))
        _ = detector.handle(.fnDown(otherModifiers: [], at: 12))
        #expect(detector.confirm(at: 12.5, lastOtherInputAt: nil) == .fire)
    }

    @Test(arguments: [9.99, 10.0, 10.2, 10.5])
    mutating func otherInputBeforeConfirmationBlocksTheHold(_ time: Double) {
        _ = detector.handle(.fnDown(otherModifiers: [], at: 10))
        #expect(detector.confirm(at: 10.5, lastOtherInputAt: time) == .none)
        #expect(detector.confirm(at: 11, lastOtherInputAt: nil) == .none)
    }

    @Test mutating func olderTypingDoesNotBlockTheHold() {
        _ = detector.handle(.fnDown(otherModifiers: [], at: 10))
        #expect(detector.confirm(at: 10.5, lastOtherInputAt: 9.5) == .fire)
    }

    @Test mutating func aLateTimerStillFiresIfFnIsHeld() {
        _ = detector.handle(.fnDown(otherModifiers: [], at: 10))
        #expect(detector.confirm(at: 12, lastOtherInputAt: nil) == .fire)
    }

    @Test mutating func resetOrReleaseDropsAPendingHold() {
        #expect(detector.handle(.fnUp(at: 10.1, lastOtherInputAt: nil)) == .none)
        _ = detector.handle(.fnDown(otherModifiers: [], at: 10))
        detector.reset()
        #expect(!detector.isFnHeld)
        #expect(detector.confirm(at: 11, lastOtherInputAt: nil) == .none)
    }

    @Test mutating func aNewTapDuringRecordingFiresOnRelease() {
        detector.allowsTap = true
        _ = detector.handle(.fnDown(otherModifiers: [], at: 10))
        #expect(detector.confirm(at: 10.1, lastOtherInputAt: nil) == .none)
        #expect(detector.handle(.fnUp(at: 10.15, lastOtherInputAt: nil)) == .fire)
        #expect(detector.confirm(at: 10.5, lastOtherInputAt: nil) == .none)
    }

    @Test mutating func releasingTheStartingHoldDoesNotStopTheRecording() {
        _ = detector.handle(.fnDown(otherModifiers: [], at: 10))
        #expect(detector.confirm(at: 10.5, lastOtherInputAt: nil) == .fire)
        detector.allowsTap = true
        #expect(detector.handle(.fnUp(at: 10.6, lastOtherInputAt: nil)) == .none)
    }

    @Test mutating func aStoppingHoldDoesNotFireAgainOnRelease() {
        detector.allowsTap = true
        _ = detector.handle(.fnDown(otherModifiers: [], at: 10))
        #expect(detector.confirm(at: 10.5, lastOtherInputAt: nil) == .fire)
        detector.allowsTap = false
        #expect(detector.confirm(at: 11, lastOtherInputAt: nil) == .none)
        #expect(detector.handle(.fnUp(at: 11.1, lastOtherInputAt: nil)) == .none)
    }

    @Test mutating func aStoppingTapWithAnotherModifierIsIgnored() {
        detector.allowsTap = true
        _ = detector.handle(.fnDown(otherModifiers: [], at: 10))
        _ = detector.handle(.modifiersChanged(otherModifiers: [.command]))
        _ = detector.handle(.modifiersChanged(otherModifiers: []))
        #expect(detector.handle(.fnUp(at: 10.2, lastOtherInputAt: nil)) == .none)
    }

    @Test(arguments: [9.99, 10.0, 10.1, 10.2])
    mutating func aStoppingTapWithOtherInputIsIgnored(_ time: Double) {
        detector.allowsTap = true
        _ = detector.handle(.fnDown(otherModifiers: [], at: 10))
        #expect(detector.handle(.fnUp(at: 10.2, lastOtherInputAt: time)) == .none)
    }

    @Test mutating func endingRecordingDuringAPressCannotStopANewRecording() {
        detector.allowsTap = true
        _ = detector.handle(.fnDown(otherModifiers: [], at: 10))
        detector.allowsTap = false
        detector.allowsTap = true
        #expect(detector.confirm(at: 10.5, lastOtherInputAt: nil) == .none)
        #expect(detector.handle(.fnUp(at: 10.6, lastOtherInputAt: nil)) == .none)
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
        #expect(Shortcut.fn.displayName == "fn 長押し")
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
