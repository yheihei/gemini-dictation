import DictationCore
import SwiftUI

/// The floating panel content. Pure SwiftUI controls are used for buttons so that
/// clicks work in a panel that never becomes key (it must not steal focus from the
/// text field the transcript is going to).
public struct HUDView: View {
    public var content: HUDContent
    public var perform: (HUDAction) -> Void

    public init(content: HUDContent, perform: @escaping (HUDAction) -> Void) {
        self.content = content
        self.perform = perform
    }

    public var body: some View {
        if content.isCompact {
            compactIndicator
        } else {
            detailedPanel
        }
    }

    private var compactIndicator: some View {
        HStack(spacing: 7) {
            if content.tone == .recording {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(content.title)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .fixedSize(horizontal: true, vertical: false)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }

    private var detailedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                icon
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = content.message {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if let elapsed = content.elapsed {
                    Text(content.limit.map { "\(formatElapsed(elapsed)) / \(formatElapsed($0))" } ?? formatElapsed(elapsed))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if let level = content.level {
                LevelMeter(level: level)
            }

            if let transcript = content.transcript {
                ScrollView {
                    Text(transcript)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }

            if let detail = content.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if content.hint != nil || !content.actions.isEmpty {
                HStack(spacing: 8) {
                    if let hint = content.hint {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    ForEach(content.actions) { action in
                        Button(action.title) { perform(action) }
                            .buttonStyle(HUDButtonStyle(isPrimary: action.isPrimary))
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
    }

    @ViewBuilder
    private var icon: some View {
        switch content.tone {
        case .recording:
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .font(.title3)
        case .working:
            ProgressView()
                .controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
        case .info:
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
                .font(.title3)
        case .warning:
            Image(systemName: "doc.on.clipboard.fill")
                .foregroundStyle(.orange)
                .font(.title3)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.title3)
        }
    }
}

struct LevelMeter: View {
    var level: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(Color.red.opacity(0.75))
                    .frame(width: max(4, proxy.size.width * min(1, max(0, level))))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
        .frame(height: 6)
    }
}

struct HUDButtonStyle: ButtonStyle {
    var isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(isPrimary ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isPrimary ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isPrimary ? Color.accentColor : Color.primary.opacity(0.1))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}
