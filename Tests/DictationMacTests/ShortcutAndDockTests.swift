import Carbon.HIToolbox
import DictationCore
import Foundation
import Testing
@testable import DictationMac

@MainActor
@Suite("Shortcut controller")
struct ShortcutControllerTests {
    let id = ShortcutHarness.toggleID

    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            await Task.yield()
        }
    }

    @Test func fnIsTheDefaultAndUsesTheFnMonitorOnly() {
        let harness = ShortcutHarness()
        harness.controller.activate()
        #expect(harness.controller.status == .active)
        #expect(harness.fnMonitor.isRunning)
        #expect(!harness.hotKeys.isRegistered(id: id))
        harness.fnMonitor.hold()
        #expect(harness.toggles.count == 1)
    }

    @Test func fnWaitsForAccessibilityAndStartsByItself() async {
        let harness = ShortcutHarness(trusted: false)
        harness.controller.activate()
        #expect(harness.controller.status == .needsAccessibility)
        #expect(!harness.fnMonitor.isRunning)
        #expect(harness.controller.isPollingForPermission)

        harness.trust.value = true
        await waitUntil { harness.controller.status == .active }
        #expect(harness.controller.status == .active)
        #expect(harness.fnMonitor.isRunning)
        #expect(!harness.controller.isPollingForPermission)
    }

    @Test func aSavedKeyShortcutIsRegisteredWithCarbonBits() {
        let store = InMemoryKeyValueStore()
        AppSettings(store: store).shortcut = .key(controlOptionD)
        let harness = ShortcutHarness(store: store)
        harness.controller.activate()
        #expect(harness.hotKeys.registrations[id] == .init(keyCode: 0x02, modifiers: UInt32(controlKey | optionKey)))
        #expect(!harness.fnMonitor.isRunning)
        harness.hotKeys.press(id: id)
        #expect(harness.toggles.count == 1)
    }

    @Test func recordingPausesTheCurrentShortcutSoNothingToggles() {
        let store = InMemoryKeyValueStore()
        AppSettings(store: store).shortcut = .key(optionSpace)
        let harness = ShortcutHarness(store: store)
        harness.controller.activate()

        harness.controller.startRecording()
        #expect(harness.controller.isRecording)
        #expect(harness.controller.status == .paused)
        #expect(harness.keyEvents.isListening)
        #expect(!harness.hotKeys.isRegistered(id: id))
        #expect(!harness.fnMonitor.isRunning)
        #expect(harness.systemShortcuts.readCount == 1)

        harness.hotKeys.press(id: id)
        harness.fnMonitor.hold()
        #expect(harness.toggles.count == 0)
    }

    @Test func recordingAKeyComboRegistersAndSavesIt() {
        let harness = ShortcutHarness()
        harness.controller.activate()
        harness.controller.startRecording()
        harness.keyEvents.pressKey(0x02, [.control, .option], label: "D")

        #expect(!harness.controller.isRecording)
        #expect(!harness.keyEvents.isListening)
        #expect(harness.settings.shortcut == .key(controlOptionD))
        #expect(harness.controller.status == .active)
        #expect(harness.hotKeys.registrations[id]?.keyCode == 0x02)
        #expect(!harness.fnMonitor.isRunning)
        #expect(harness.controller.feedback?.isError == false)
    }

    @Test func recordingFnSwitchesBackToTheFnMonitor() {
        let store = InMemoryKeyValueStore()
        AppSettings(store: store).shortcut = .key(optionSpace)
        let harness = ShortcutHarness(store: store)
        harness.controller.activate()
        harness.controller.startRecording()
        harness.keyEvents.tapFn()

        #expect(harness.settings.shortcut == .fn)
        #expect(harness.fnMonitor.isRunning)
        #expect(!harness.hotKeys.isRegistered(id: id))
    }

    @Test func aRejectedKeyKeepsListeningWithAnExplanation() {
        let harness = ShortcutHarness()
        harness.controller.activate()
        harness.controller.startRecording()
        harness.keyEvents.pressKey(0x02, [.command], label: "D")

        #expect(harness.controller.isRecording)
        #expect(harness.controller.feedback == .init(text: ShortcutRejection.appStandardShortcut.message, isError: true))
        #expect(harness.settings.shortcut == .fn)

        harness.keyEvents.pressKey(0x02, [.control, .option], label: "D")
        #expect(harness.settings.shortcut == .key(controlOptionD))
    }

    @Test func escapeCancelsAndRestoresThePreviousShortcut() {
        let store = InMemoryKeyValueStore()
        AppSettings(store: store).shortcut = .key(optionSpace)
        let harness = ShortcutHarness(store: store)
        harness.controller.activate()
        harness.controller.startRecording()
        harness.keyEvents.pressKey(KeyCode.escape, [], label: "esc")

        #expect(!harness.controller.isRecording)
        #expect(harness.settings.shortcut == .key(optionSpace))
        #expect(harness.hotKeys.registrations[id]?.keyCode == UInt32(KeyCode.space))
        #expect(harness.controller.status == .active)
    }

    @Test func aShortcutThatCannotBeRegisteredKeepsThePreviousOne() {
        let store = InMemoryKeyValueStore()
        AppSettings(store: store).shortcut = .key(optionSpace)
        let harness = ShortcutHarness(store: store)
        harness.hotKeys.refusedKeyCodes = [0x02]
        harness.controller.activate()
        harness.controller.startRecording()
        harness.keyEvents.pressKey(0x02, [.control, .option], label: "D")

        #expect(harness.settings.shortcut == .key(optionSpace))
        #expect(harness.hotKeys.registrations[id]?.keyCode == UInt32(KeyCode.space))
        #expect(harness.controller.status == .active)
        #expect(harness.controller.feedback == .init(text: ShortcutRejection.registrationFailed.message, isError: true))
    }

    @Test func aSavedShortcutThatFailsAtLaunchIsReported() {
        let store = InMemoryKeyValueStore()
        AppSettings(store: store).shortcut = .key(controlOptionD)
        let harness = ShortcutHarness(store: store)
        harness.hotKeys.refusedKeyCodes = [0x02]
        harness.controller.activate()
        #expect(harness.controller.status == .registrationFailed)
        // The saved choice is kept so it can work again later.
        #expect(harness.settings.shortcut == .key(controlOptionD))
    }

    @Test func changesAreBlockedWhileRecordingOrProcessing() {
        let harness = ShortcutHarness()
        harness.controller.activate()
        harness.controller.busyStateChanged(isBusy: true)
        #expect(harness.controller.changesBlocked)

        harness.controller.startRecording()
        #expect(!harness.controller.isRecording)
        #expect(!harness.keyEvents.isListening)
        #expect(harness.controller.feedback?.isError == true)
        // The active shortcut keeps working, so the dictation can still be stopped.
        #expect(harness.fnMonitor.isRunning)

        harness.controller.busyStateChanged(isBusy: false)
        #expect(!harness.controller.changesBlocked)
    }

    @Test func fnTapsAreEnabledOnlyWhileRecordingWithoutRestartingTheMonitor() {
        let harness = ShortcutHarness()
        harness.controller.activate()
        let starts = harness.fnMonitor.startCount
        #expect(!harness.fnMonitor.allowsTap)
        harness.controller.busyStateChanged(isBusy: true, isRecording: true)
        #expect(harness.fnMonitor.allowsTap)
        #expect(harness.fnMonitor.startCount == starts)
        harness.controller.busyStateChanged(isBusy: true, isRecording: false)
        #expect(!harness.fnMonitor.allowsTap)
        harness.controller.busyStateChanged(isBusy: false)
        #expect(!harness.fnMonitor.allowsTap)
    }

    @Test func aDictationStartingDuringRecordingCancelsTheRecorder() {
        let store = InMemoryKeyValueStore()
        AppSettings(store: store).shortcut = .key(optionSpace)
        let harness = ShortcutHarness(store: store)
        harness.controller.activate()
        harness.controller.startRecording()

        harness.controller.busyStateChanged(isBusy: true)
        #expect(!harness.controller.isRecording)
        #expect(!harness.keyEvents.isListening)
        #expect(harness.hotKeys.isRegistered(id: id))
        #expect(harness.toggles.count == 0)
    }

    @Test func resetGoesBackToFn() {
        let store = InMemoryKeyValueStore()
        AppSettings(store: store).shortcut = .key(optionSpace)
        let harness = ShortcutHarness(store: store)
        harness.controller.activate()
        harness.controller.resetToDefault()
        #expect(harness.settings.shortcut == .fn)
        #expect(!harness.hotKeys.isRegistered(id: id))
        #expect(harness.fnMonitor.isRunning)
    }

    @Test func recheckFollowsTheAccessibilityState() {
        let harness = ShortcutHarness()
        harness.controller.activate()
        harness.trust.value = false
        harness.controller.recheckPermission()
        #expect(harness.controller.status == .needsAccessibility)
        #expect(!harness.fnMonitor.isRunning)

        harness.trust.value = true
        harness.controller.recheckPermission()
        #expect(harness.controller.status == .active)
        #expect(harness.fnMonitor.isRunning)
    }

    @Test func theRecordedShortcutSurvivesARestart() {
        let store = InMemoryKeyValueStore()
        let first = ShortcutHarness(store: store)
        first.controller.activate()
        first.controller.startRecording()
        first.keyEvents.pressKey(0x02, [.control, .option], label: "D")

        let second = ShortcutHarness(store: store)
        second.controller.activate()
        #expect(second.settings.shortcut == .key(controlOptionD))
        #expect(second.hotKeys.registrations[id]?.keyCode == 0x02)
    }
}

@MainActor
@Suite("Dock icon preference")
struct DockIconControllerTests {
    final class Flags {
        var busy = false
        var settingsVisible = false
    }

    func make(showInDock: Bool = false) -> (DockIconController, AppSettings, FakeActivationPolicy, Flags) {
        let settings = AppSettings(store: InMemoryKeyValueStore())
        settings.showInDock = showInDock
        let policy = FakeActivationPolicy()
        let flags = Flags()
        let controller = DockIconController(
            settings: settings,
            applier: policy,
            isBusy: { flags.busy },
            settingsVisible: { flags.settingsVisible }
        )
        return (controller, settings, policy, flags)
    }

    @Test func launchAppliesTheSavedPreference() {
        let (controller, _, policy, _) = make()
        controller.applyAtLaunch()
        #expect(policy.changes == [false])
        #expect(policy.reactivations == 0)

        let (shown, _, shownPolicy, _) = make(showInDock: true)
        shown.applyAtLaunch()
        #expect(shownPolicy.changes == [true])
    }

    @Test func changingItWhileIdleInAnotherAppNeverStealsFocus() {
        let (controller, settings, policy, _) = make()
        controller.applyAtLaunch()
        policy.isActive = false
        settings.showInDock = true
        controller.preferenceChanged()
        #expect(policy.changes == [false, true])
        #expect(policy.reactivations == 0)
    }

    @Test func changingItFromSettingsKeepsSettingsInFront() {
        let (controller, settings, policy, flags) = make()
        controller.applyAtLaunch()
        policy.isActive = true
        flags.settingsVisible = true
        settings.showInDock = true
        controller.preferenceChanged()
        #expect(policy.changes == [false, true])
        #expect(policy.reactivations == 1)
    }

    @Test func changesWaitUntilTheDictationIsOver() {
        let (controller, settings, policy, flags) = make()
        controller.applyAtLaunch()
        flags.busy = true
        settings.showInDock = true
        controller.preferenceChanged()
        #expect(policy.changes == [false])
        #expect(controller.hasPendingChange)

        controller.busyStateChanged(isBusy: true)
        #expect(policy.changes == [false])

        flags.busy = false
        controller.busyStateChanged(isBusy: false)
        #expect(policy.changes == [false, true])
        #expect(!controller.hasPendingChange)
    }

    @Test func flippingBackDuringADictationChangesNothing() {
        let (controller, settings, policy, flags) = make()
        controller.applyAtLaunch()
        flags.busy = true
        settings.showInDock = true
        controller.preferenceChanged()
        settings.showInDock = false
        controller.preferenceChanged()
        flags.busy = false
        controller.busyStateChanged(isBusy: false)
        #expect(policy.changes == [false])
    }

    @Test func aRefusedSwitchIsRetriedOnTheNextChange() {
        let (controller, settings, policy, _) = make()
        controller.applyAtLaunch()
        policy.refuse = true
        settings.showInDock = true
        controller.preferenceChanged()
        #expect(controller.appliedShowsDockIcon == false)

        policy.refuse = false
        controller.preferenceChanged()
        #expect(controller.appliedShowsDockIcon == true)
        #expect(policy.changes == [false, true])
    }
}

@MainActor
@Suite("Shortcut migration from 0.1")
struct ShortcutMigrationTests {
    @Test func usersWhoKeptTheOldDefaultMoveToFn() {
        #expect(AppSettings(store: InMemoryKeyValueStore()).shortcut == .fn)
    }

    @Test(arguments: [
        ("optionSpace", ShortcutModifiers([.option]), "⌥ Space"),
        ("optionShiftSpace", ShortcutModifiers([.option, .shift]), "⌥⇧ Space"),
        ("controlShiftSpace", ShortcutModifiers([.control, .shift]), "⌃⇧ Space"),
        ("controlOptionCommandSpace", ShortcutModifiers([.control, .option, .command]), "⌃⌥⌘ Space"),
    ])
    func anExplicitlyChosenPresetIsKept(raw: String, modifiers: ShortcutModifiers, display: String) {
        let store = InMemoryKeyValueStore()
        store.set(raw, forKey: "hotKeyPreset")
        let shortcut = AppSettings(store: store).shortcut
        #expect(shortcut == .key(KeyCombo(keyCode: KeyCode.space, modifiers: modifiers, keyLabel: "Space")))
        #expect(shortcut.displayName == display)
    }

    @Test func anUnknownPresetFallsBackToFn() {
        let store = InMemoryKeyValueStore()
        store.set("hyperSpace", forKey: "hotKeyPreset")
        #expect(AppSettings(store: store).shortcut == .fn)
    }

    @Test func aNewlySavedShortcutWinsAndTheOldKeyStaysForVersion01() {
        let store = InMemoryKeyValueStore()
        store.set("optionShiftSpace", forKey: "hotKeyPreset")
        let settings = AppSettings(store: store)
        settings.shortcut = .fn
        #expect(AppSettings(store: store).shortcut == .fn)
        #expect(store.object(forKey: "hotKeyPreset") as? String == "optionShiftSpace")
    }

    @Test func unreadableSavedDataFallsBack() {
        let store = InMemoryKeyValueStore()
        store.set(Data("not json".utf8), forKey: "shortcut")
        #expect(AppSettings(store: store).shortcut == .fn)
        store.set("optionSpace", forKey: "hotKeyPreset")
        #expect(AppSettings(store: store).shortcut.displayName == "⌥ Space")
    }

    @Test func loadingDoesNotWriteAnything() {
        let store = InMemoryKeyValueStore()
        store.set("optionSpace", forKey: "hotKeyPreset")
        _ = AppSettings(store: store)
        #expect(store.object(forKey: "shortcut") == nil)
        #expect(store.object(forKey: "showInDock") == nil)
    }
}
