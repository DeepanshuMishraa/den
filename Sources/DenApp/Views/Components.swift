import SwiftUI

/// Den's tooltip: a small dark label with keycaps, shown below the view
/// after a short hover (e.g. "Change Session ⌘ K").
struct DenTooltip: ViewModifier {
    let text: String
    let keys: [String]
    @Environment(AppModel.self) private var model
    @State private var visible = false
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                task?.cancel()
                if inside {
                    task = Task {
                        try? await Task.sleep(for: .milliseconds(650))
                        guard !Task.isCancelled else { return }
                        visible = true
                    }
                } else {
                    visible = false
                }
            }
            .simultaneousGesture(TapGesture().onEnded { visible = false })
            .overlay(alignment: .bottom) {
                if visible {
                    TooltipBubble(text: text, keys: keys, theme: model.theme)
                        .fixedSize()
                        .alignmentGuide(.bottom) { $0[.top] - 6 }
                        .transition(.opacity.combined(with: .offset(y: -2)))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: visible)
    }
}

struct TooltipBubble: View {
    let text: String
    let keys: [String]
    let theme: Theme

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 11.5, weight: .medium))
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { Keycap(label: $0, theme: theme) }
            }
        }
        .foregroundStyle(theme.chromeText)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.menuFill))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.menuBorder, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

struct Keycap: View {
    let label: String
    let theme: Theme

    var body: some View {
        Text(label)
            .font(.system(size: 10.5, weight: .semibold))
            .frame(minWidth: 15, minHeight: 15)
            .padding(.horizontal, 2)
            .background(RoundedRectangle(cornerRadius: 3.5).fill(theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.07)))
    }
}

extension View {
    func denTooltip(_ text: String, keys: [String] = []) -> some View {
        modifier(DenTooltip(text: text, keys: keys))
    }
}

/// Borderless icon button with a rounded hover fill.
struct IconButton: View {
    let symbol: String
    var size: CGFloat = 13
    var weight: Font.Weight = .medium
    var frame = CGSize(width: 26, height: 24)
    var enabled = true
    let action: () -> Void
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(enabled ? model.theme.secondaryText : model.theme.tertiaryText.opacity(0.6))
                .frame(width: frame.width, height: frame.height)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering && enabled ? model.theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

/// A toast that reads as part of the terminal: the terminal's own font and
/// palette, a flat card with the same hairline border as the panes, and a
/// plain accent check instead of a badge.
struct ToastView: View {
    let toast: AppModel.Toast
    let theme: Theme
    let fontFamily: String
    let fontSize: CGFloat

    var body: some View {
        let font = Font.custom(fontFamily, size: fontSize)
        HStack(spacing: fontSize * 0.6) {
            Text("✓").font(font.weight(.bold)).foregroundStyle(theme.accent)
            Text(toast.message).font(font).foregroundStyle(theme.foreground.color.opacity(0.88))
        }
        .padding(.horizontal, fontSize * 0.9)
        .padding(.vertical, fontSize * 0.45)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.isDark ? theme.background.lightened(0.05).color : theme.background.darkened(0.03).color)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.focusedBorder, lineWidth: 1)
                )
                .shadow(color: .black.opacity(theme.isDark ? 0.25 : 0.06), radius: 6, y: 2)
        )
    }
}

/// The terminal is an AppKit view holding first responder, so SwiftUI's
/// `@FocusState` alone can't move focus into an overlay's text field.
@MainActor
enum KeyboardFocus {
    /// Moves first responder off the terminal, then lets SwiftUI focus the field.
    static func takeFromTerminal(_ focusField: @escaping @MainActor () -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.firstResponder is TerminalView {
            // The window itself; SwiftUI then moves focus into the field.
            window.makeFirstResponder(nil)
        }
        // Next runloop turn, after the hosting view owns the responder chain.
        DispatchQueue.main.async { focusField() }
    }
}

/// The springs Den uses throughout: quick and slightly soft.
extension Animation {
    static let den = Animation.spring(response: 0.3, dampingFraction: 0.86)
    static let denFast = Animation.spring(response: 0.22, dampingFraction: 0.9)
}

/// Fuzzy subsequence matching for the palette and menus.
enum Fuzzy {
    /// Returns matched character offsets, or nil when `query` doesn't match.
    static func match(_ query: String, in text: String) -> [Int]? {
        guard !query.isEmpty else { return [] }
        let q = Array(query.lowercased())
        let t = Array(text.lowercased())
        // Prefer a contiguous substring hit, which reads best when highlighted.
        if let range = text.lowercased().range(of: query.lowercased()) {
            let start = text.lowercased().distance(from: text.lowercased().startIndex, to: range.lowerBound)
            return Array(start ..< start + q.count)
        }
        var hits: [Int] = []
        var qi = 0
        for (i, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
            hits.append(i)
            qi += 1
        }
        return qi == q.count ? hits : nil
    }

    static func score(_ hits: [Int]) -> Int {
        guard let first = hits.first else { return 0 }
        let gaps = zip(hits, hits.dropFirst()).reduce(0) { $0 + ($1.1 - $1.0 - 1) }
        return first * 2 + gaps * 3
    }

    static func highlighted(_ text: String, hits: [Int], base: Color, accent: Color) -> Text {
        let set = Set(hits)
        var out = AttributedString()
        for (i, ch) in text.enumerated() {
            var piece = AttributedString(String(ch))
            piece.foregroundColor = set.contains(i) ? accent : base
            out.append(piece)
        }
        return Text(out)
    }
}
