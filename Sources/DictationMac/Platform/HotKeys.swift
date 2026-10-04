import Carbon.HIToolbox
import Foundation

/// Shortcut choices for starting/stopping a recording.
public enum HotKeyPreset: String, CaseIterable, Identifiable, Sendable {
    case optionSpace
    case optionShiftSpace
    case controlShiftSpace
    case controlOptionCommandSpace

    public var id: String { rawValue }

    public var keyCode: UInt32 { UInt32(kVK_Space) }

    public var carbonModifiers: UInt32 {
        switch self {
        case .optionSpace: return UInt32(optionKey)
        case .optionShiftSpace: return UInt32(optionKey | shiftKey)
        case .controlShiftSpace: return UInt32(controlKey | shiftKey)
        case .controlOptionCommandSpace: return UInt32(controlKey | optionKey | cmdKey)
        }
    }

    public var displayName: String {
        switch self {
        case .optionSpace: return "⌥ Space"
        case .optionShiftSpace: return "⌥⇧ Space"
        case .controlShiftSpace: return "⌃⇧ Space"
        case .controlOptionCommandSpace: return "⌃⌥⌘ Space"
        }
    }
}

/// System-wide shortcuts through Carbon `RegisterEventHotKey`, which needs no
/// Accessibility or Input Monitoring permission and only sees the registered combination.
@MainActor
public final class HotKeyCenter {
    public typealias Handler = @MainActor () -> Void

    public static let escapeKeyCode = UInt32(kVK_Escape)

    private static let signature: OSType = 0x4744_6963 // "GDic"
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: Handler] = [:]
    private var eventHandler: EventHandlerRef?

    public init() {}

    @discardableResult
    public func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping Handler) -> Bool {
        installEventHandlerIfNeeded()
        unregister(id: id)
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else {
            return false
        }
        references[id] = reference
        handlers[id] = handler
        return true
    }

    public func unregister(id: UInt32) {
        if let reference = references.removeValue(forKey: id) {
            UnregisterEventHotKey(reference)
        }
        handlers[id] = nil
    }

    public func isRegistered(id: UInt32) -> Bool {
        references[id] != nil
    }

    public func unregisterAll() {
        for id in Array(references.keys) {
            unregister(id: id)
        }
    }

    fileprivate func handle(id: UInt32) {
        handlers[id]?()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(context).takeUnretainedValue()
            let id = hotKeyID.id
            // Application-target Carbon events are delivered on the main thread.
            MainActor.assumeIsolated {
                center.handle(id: id)
            }
            return noErr
        }, 1, &eventType, context, &eventHandler)
    }
}
