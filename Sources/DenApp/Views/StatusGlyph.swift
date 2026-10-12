import DenProtocol
import SwiftUI

/// A tab's program status: pulsing dots while working, a symbol per blocked
/// reason, and a mark for finished or failed results not yet seen.
struct StatusGlyph: View {
    let indicator: TabStatus.Indicator
    var size: CGFloat = 12

    var body: some View {
        Group {
            switch indicator {
            case .working:
                WorkingDots(size: size)
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
        .uiFont(size: size * 0.9, weight: .semibold)
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

/// Three dots breathing in turn: a program is busy.
struct WorkingDots: View {
    var size: CGFloat = 12

    var body: some View {
        let dot = max(2.5, size * 0.24)
        TimelineView(.periodic(from: .now, by: 0.28)) { context in
            let lit = Int(context.date.timeIntervalSinceReferenceDate / 0.28) % 4
            HStack(spacing: dot * 0.7) {
                ForEach(0 ..< 3, id: \.self) { i in
                    Circle()
                        .frame(width: dot, height: dot)
                        .opacity(i == lit ? 1 : 0.4)
                }
            }
            .foregroundStyle(.secondary)
            .animation(.easeInOut(duration: 0.25), value: lit)
        }
        .fixedSize()
    }
}
