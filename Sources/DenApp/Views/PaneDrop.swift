import DenProtocol
import SwiftUI

/// ⌘-drag a pane onto another to rearrange: every other pane shows its drop
/// regions (four edges to dock beside it, the middle square to swap), the
/// one under the pointer lights up, and a small card follows the pointer.
enum PaneDrag {
    /// Direction from the pane's center picks the side, so a little off
    /// center is already left/right/above/below; only the compass's middle
    /// square (±18pt) swaps. The compass squares sit on those directions, so
    /// pointing at one picks it.
    static func placement(at point: CGPoint, in size: CGSize) -> PanePlacement {
        guard size.width > 0, size.height > 0 else { return .swap }
        let dx = point.x - size.width / 2, dy = point.y - size.height / 2
        if abs(dx) <= swapRadius, abs(dy) <= swapRadius { return .swap }
        if abs(dx) / size.width >= abs(dy) / size.height { return dx < 0 ? .left : .right }
        return dy < 0 ? .above : .below
    }

    static let swapRadius: CGFloat = 18
}

/// What a pane shows while another is dragged: a compass of five squares
/// (dock left, right, top, bottom, or swap). Over the pane under the
/// pointer, the matching square lights and a preview fills the exact area
/// the moved pane will take.
struct PaneDropRegions: View {
    /// The placement under the pointer, if it's over this pane.
    let active: PanePlacement?
    let theme: Theme
    var radius: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                if let active {
                    let r = Self.preview(active, w: w, h: h)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(theme.accent.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(theme.accent, lineWidth: 1.5))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                }
                compass
                    .position(x: w / 2, y: h / 2)
            }
            .animation(.spring(response: 0.22, dampingFraction: 0.9), value: active)
        }
        .allowsHitTesting(false)
    }

    /// Where the moved pane ends up, inset from the pane's edge.
    static func preview(_ placement: PanePlacement, w: CGFloat, h: CGFloat) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: w, height: h).insetBy(dx: 6, dy: 6)
        switch placement {
        case .swap: return full
        case .left: return CGRect(x: full.minX, y: full.minY, width: full.width / 2, height: full.height)
        case .right: return CGRect(x: full.midX, y: full.minY, width: full.width / 2, height: full.height)
        case .above: return CGRect(x: full.minX, y: full.minY, width: full.width, height: full.height / 2)
        case .below: return CGRect(x: full.minX, y: full.midY, width: full.width, height: full.height / 2)
        }
    }

    private var compass: some View {
        VStack(spacing: 4) {
            square(.above)
            HStack(spacing: 4) {
                square(.left)
                square(.swap)
                square(.right)
            }
            square(.below)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.menuBorder, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }

    private func square(_ placement: PanePlacement) -> some View {
        let lit = placement == active
        let s: CGFloat = 30
        return ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(lit ? theme.accent : theme.chromeText.opacity(0.08))
            if placement == .swap {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(lit ? theme.onAccent : theme.secondaryText)
            } else {
                // A tiny pane with the half the moved pane takes filled in.
                // preview() in a 30pt box insets 6pt, leaving an 18pt area
                // at (6, 6); shift it to the glyph's origin and pad 2pt.
                let half = Self.preview(placement, w: 30, h: 30).offsetBy(dx: -6, dy: -6)
                let k: CGFloat = 14 / 18
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 2.5).strokeBorder(lit ? theme.onAccent : theme.secondaryText, lineWidth: 1.2)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(lit ? theme.onAccent : theme.secondaryText)
                        .frame(width: half.width * k, height: half.height * k)
                        .offset(x: 2 + half.minX * k, y: 2 + half.minY * k)
                }
                .frame(width: 18, height: 18)
            }
        }
        .frame(width: s, height: s)
    }
}

/// The card that follows the pointer while a pane is dragged.
struct PaneDragGhost: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let drag = model.paneDrag {
            let theme = model.theme
            HStack(spacing: 7) {
                ProgramGlyph(kind: model.program(for: drag.source), size: 13, color: theme.chromeText)
                    .frame(width: 16, height: 14)
                Text(model.title(for: drag.source))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.chromeText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: 240)
            .fixedSize()
            .background(MenuSurface(theme: theme))
            .position(x: drag.point.x + 70, y: drag.point.y + 24)
            .allowsHitTesting(false)
        }
    }
}
