import Foundation

/// Decides when a press of fn / Globe counts as "fn on its own".
///
/// A tap counts only when all of these hold:
/// - no other modifier was held when fn went down or was pressed while it was held,
/// - no key, click or scroll happened while fn was held (`lastOtherInputAt`),
/// - fn was released within `maxTapDuration`,
/// - no second fn press follows within `doubleTapWindow`. A quick double press is
///   left to macOS (for example the "Press fn key twice" Dictation shortcut).
///
/// Times are seconds on the system uptime clock (`NSEvent.timestamp`).
public struct FnTapDetector: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var maxTapDuration: TimeInterval
        public var doubleTapWindow: TimeInterval
        /// Other input this close before fn went down still counts as "during" the press.
        public var simultaneityTolerance: TimeInterval

        public init(maxTapDuration: TimeInterval = 0.8, doubleTapWindow: TimeInterval = 0.35, simultaneityTolerance: TimeInterval = 0.02) {
            self.maxTapDuration = maxTapDuration
            self.doubleTapWindow = doubleTapWindow
            self.simultaneityTolerance = simultaneityTolerance
        }
    }

    public enum Input: Equatable, Sendable {
        case fnDown(otherModifiers: ShortcutModifiers, at: TimeInterval)
        /// `lastOtherInputAt` is when the most recent key press, click or scroll happened.
        case fnUp(otherModifiers: ShortcutModifiers, at: TimeInterval, lastOtherInputAt: TimeInterval?)
        case modifiersChanged(otherModifiers: ShortcutModifiers, at: TimeInterval)
    }

    public enum Action: Equatable, Sendable {
        case none
        /// A clean tap ended; call `confirm(at:)` at this time to see whether it stands.
        case confirmAt(TimeInterval)
        case fire
    }

    public let configuration: Configuration
    private var downAt: TimeInterval?
    private var tainted = false
    private var pendingTapAt: TimeInterval?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public var isFnHeld: Bool {
        downAt != nil
    }

    public mutating func handle(_ input: Input) -> Action {
        switch input {
        case .fnDown(let others, let time):
            guard downAt == nil else { return .none }
            var action = Action.none
            var secondPressOfDoubleTap = false
            if let pending = pendingTapAt {
                pendingTapAt = nil
                if time - pending <= configuration.doubleTapWindow {
                    secondPressOfDoubleTap = true
                } else {
                    // The confirmation came late; the earlier tap still stands.
                    action = .fire
                }
            }
            downAt = time
            tainted = secondPressOfDoubleTap || !others.isEmpty
            return action

        case .modifiersChanged(let others, _):
            if downAt != nil, !others.isEmpty {
                tainted = true
            }
            return .none

        case .fnUp(let others, let time, let lastOtherInputAt):
            guard let down = downAt else { return .none }
            downAt = nil
            defer { tainted = false }
            if tainted || !others.isEmpty || time - down > configuration.maxTapDuration {
                return .none
            }
            // Input after the release (typed before this event was handled) is not part of it.
            if let other = lastOtherInputAt,
               other >= down - configuration.simultaneityTolerance,
               other <= time + configuration.simultaneityTolerance {
                return .none
            }
            pendingTapAt = time
            return .confirmAt(time + configuration.doubleTapWindow)
        }
    }

    /// Fires the pending tap once the double-press window has passed without a second press.
    public mutating func confirm(at time: TimeInterval) -> Action {
        guard let pending = pendingTapAt, downAt == nil,
              time - pending >= configuration.doubleTapWindow - 0.001 else {
            return .none
        }
        pendingTapAt = nil
        return .fire
    }

    public mutating func reset() {
        downAt = nil
        tainted = false
        pendingTapAt = nil
    }
}
