import DenProtocol
import SwiftUI

/// A tab's program status: a spinner while working, a symbol per blocked
/// reason, and a mark for finished or failed results not yet seen.
struct StatusGlyph: View {
    let indicator: TabStatus.Indicator
    var size: CGFloat = 12

    var body: some View {
        Group {
            switch indicator {
            case .working:
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(size / 16)
            case .blocked(let kind):
                Image(systemName: Self.symbol(for: kind))
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse, options: .repeating)
            case .error:
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .font(.system(size: size * 0.9, weight: .semibold))
        .frame(width: size + 4, height: size + 4)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    private static func symbol(for kind: BlockedKind?) -> String {
        switch kind {
        case .permission: "hand.raised.fill"
        case .question: "questionmark.bubble.fill"
        case .auth: "key.fill"
        case nil: "pause.circle.fill"
        }
    }
}
