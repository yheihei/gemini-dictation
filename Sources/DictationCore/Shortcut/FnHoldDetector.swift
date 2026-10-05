import Foundation

/// fn 単独の長押しで開始し、録音中は短押しでも停止する。
/// 押し続けても発火は1回だけ。
/// 時刻は NSEvent.timestamp と同じシステム稼働時間を使う。
public struct FnHoldDetector: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var holdDuration: TimeInterval
        public var simultaneityTolerance: TimeInterval

        public init(holdDuration: TimeInterval = 0.5, simultaneityTolerance: TimeInterval = 0.02) {
            precondition(holdDuration > 0 && holdDuration.isFinite)
            precondition(simultaneityTolerance >= 0 && simultaneityTolerance.isFinite)
            self.holdDuration = holdDuration
            self.simultaneityTolerance = simultaneityTolerance
        }
    }

    public enum Input: Equatable, Sendable {
        case fnDown(otherModifiers: ShortcutModifiers, at: TimeInterval)
        case fnUp(at: TimeInterval, lastOtherInputAt: TimeInterval?)
        case modifiersChanged(otherModifiers: ShortcutModifiers)
    }

    public enum Action: Equatable, Sendable {
        case none
        case confirmAt(TimeInterval)
        case fire
    }

    public let configuration: Configuration
    private var downAt: TimeInterval?
    private var tainted = false
    private var fired = false
    private var tapAllowedForPress = false

    /// 押した瞬間の状態も保存し、開始した長押しの解放では停止しないようにする。
    public var allowsTap = false {
        didSet {
            if !allowsTap && tapAllowedForPress { tainted = true }
        }
    }

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public var isFnHeld: Bool { downAt != nil }

    public mutating func handle(_ input: Input) -> Action {
        switch input {
        case .fnDown(let others, let time):
            guard downAt == nil else { return .none }
            downAt = time
            tainted = !others.isEmpty
            fired = false
            tapAllowedForPress = allowsTap
            return tainted ? .none : .confirmAt(time + configuration.holdDuration)
        case .fnUp(let time, let lastOtherInputAt):
            defer { reset() }
            guard let down = downAt, tapAllowedForPress, allowsTap, !tainted, !fired,
                  time >= down, !hasOtherInput(lastOtherInputAt, since: down, through: time) else {
                return .none
            }
            return .fire
        case .modifiersChanged(let others):
            if downAt != nil, !others.isEmpty { tainted = true }
            return .none
        }
    }

    /// 文字の内容を読まず、直近のキー・クリック・スクロールの時刻だけで組み合わせを除く。
    public mutating func confirm(at time: TimeInterval, lastOtherInputAt: TimeInterval?) -> Action {
        guard let down = downAt, !tainted, !fired,
              time >= down + configuration.holdDuration else { return .none }
        if hasOtherInput(lastOtherInputAt, since: down, through: time) {
            tainted = true
            return .none
        }
        fired = true
        return .fire
    }

    private func hasOtherInput(_ time: TimeInterval?, since down: TimeInterval, through end: TimeInterval) -> Bool {
        guard let time else { return false }
        return time >= down - configuration.simultaneityTolerance && time <= end + configuration.simultaneityTolerance
    }

    public mutating func reset() {
        downAt = nil
        tainted = false
        fired = false
        tapAllowedForPress = false
    }
}
