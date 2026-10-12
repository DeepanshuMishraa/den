import SwiftUI

/// Den's tooltip: a small label with keycaps, shown below the view after a
/// short hover (e.g. "Change Session ⌥ Space then S"). The view only
/// publishes where it is; `TooltipLayer` draws it above everything and keeps
/// it inside the window.
struct DenTooltip: ViewModifier {
    let text: String
    let command: DenCommand?
    let number: Int?
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
            .onDisappear { task?.cancel(); visible = false }
            .simultaneousGesture(TapGesture().onEnded { task?.cancel(); visible = false })
            .anchorPreference(key: TooltipKey.self, value: .bounds) { anchor in
                guard visible, !text.isEmpty else { return [] }
                let keys = command.map { model.config.keycaps($0, number: number) } ?? []
                return [TooltipRequest(text: text, keys: keys, anchor: anchor)]
            }
    }
}

struct TooltipRequest {
    let text: String
    let keys: [[String]]
    let anchor: Anchor<CGRect>
}

struct TooltipKey: PreferenceKey {
    static let defaultValue: [TooltipRequest] = []
    static func reduce(value: inout [TooltipRequest], nextValue: () -> [TooltipRequest]) {
        value.append(contentsOf: nextValue())
    }
}

/// Draws the hovered view's tooltip at the top of the window's view tree.
struct TooltipLayer: View {
    let requests: [TooltipRequest]
    let theme: Theme

    var body: some View {
        GeometryReader { proxy in
            if let request = requests.last {
                TooltipPlacement(target: proxy[request.anchor]) {
                    TooltipBubble(text: request.text, keys: request.keys, theme: theme)
                        .fixedSize()
                }
                .id(request.text)
                .transition(.opacity.combined(with: .offset(y: -2)))
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: requests.last?.text)
    }
}

/// Centers the bubble under its target, flips it above near the bottom
/// edge, and keeps it clear of the window's edges.
private struct TooltipPlacement: Layout {
    let target: CGRect
    let gap: CGFloat = 6
    let margin: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bubble = subviews.first else { return }
        let size = bubble.sizeThatFits(.unspecified)
        let maxX = max(bounds.minX + margin, bounds.maxX - margin - size.width)
        let x = min(max(target.midX - size.width / 2, bounds.minX + margin), maxX)
        var y = target.maxY + gap
        if y + size.height > bounds.maxY - margin { y = target.minY - gap - size.height }
        bubble.place(at: CGPoint(x: x, y: max(y, bounds.minY + margin)), proposal: .unspecified)
    }
}

struct TooltipBubble: View {
    let text: String
    /// One group per keypress; leader shortcuts have two.
    let keys: [[String]]
    let theme: Theme

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 11.5, weight: .medium))
            ForEach(Array(keys.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Text("then").font(.system(size: 10.5)).foregroundStyle(theme.tertiaryText)
                }
                HStack(spacing: 3) {
                    ForEach(Array(group.enumerated()), id: \.offset) { Keycap(label: $0.element, theme: theme) }
                }
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
    /// Keycaps come from the command's shortcut in the config.
    func denTooltip(_ text: String, command: DenCommand? = nil, number: Int? = nil) -> some View {
        modifier(DenTooltip(text: text, command: command, number: number))
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
    let onAction: (UUID) -> Void

    var body: some View {
        let font = Font.custom(fontFamily, size: fontSize)
        VStack(alignment: .leading, spacing: fontSize * 0.4) {
            HStack(spacing: fontSize * 0.6) {
                Text("✓").font(font.weight(.bold)).foregroundStyle(theme.accent)
                Text(toast.message).font(font).foregroundStyle(theme.foreground.color.opacity(0.88))
                if !toast.actions.isEmpty {
                    HStack(spacing: fontSize * 0.5) {
                        ForEach(toast.actions, id: \.id) { action in
                            Button { onAction(action.id) } label: {
                                Text(action.label).font(font.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, fontSize * 0.55)
                            .padding(.vertical, fontSize * 0.2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(theme.accent.opacity(0.5), lineWidth: 1)
                            )
                        }
                    }
                    .padding(.leading, fontSize * 0.3)
                }
            }
            if let progress = toast.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(theme.accent)
                    .frame(width: 200)
            }
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

/// Fuzzy matching for the palette and menus, ranked so what you meant
/// comes first: exact, then prefix, then a word starting with the query,
/// then a plain substring, then letters scattered through the text (best
/// when they land on word starts and run together).
enum Fuzzy {
    struct Match: Equatable {
        /// Matched character offsets, for highlighting.
        let hits: [Int]
        /// Higher is better.
        let score: Int
    }

    /// Returns matched character offsets, or nil when `query` doesn't match.
    static func match(_ query: String, in text: String) -> [Int]? {
        rank(query, in: text)?.hits
    }

    static func rank(_ query: String, in text: String) -> Match? {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return Match(hits: [], score: 0) }
        let t = fold(text)
        guard q.count <= t.count else { return nil }
        // Shorter texts win ties: "Theme" over "Change Theme Folder".
        let brevity = -t.count

        if t == q { return Match(hits: Array(t.indices), score: 10_000) }
        if let start = substring(q, in: t) {
            let hits = Array(start ..< start + q.count)
            if start == 0 { return Match(hits: hits, score: 8_000 + brevity) }
            if let word = wordStarts(t).first(where: { substring(q, in: Array(t[$0...])) == 0 }) {
                return Match(hits: Array(word ..< word + q.count), score: 6_000 - word * 4 + brevity)
            }
            return Match(hits: hits, score: 4_000 - start * 4 + brevity)
        }
        return scattered(q, in: t).map { Match(hits: $0.hits, score: $0.score + brevity) }
    }

    /// Ranks `items` by how well `key` matches `query`, dropping misses.
    /// Equal scores keep their original order.
    static func filter<T>(_ items: [T], query: String, key: (T) -> String) -> [T] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        return items.enumerated()
            .compactMap { i, item in rank(query, in: key(item)).map { (i, item, $0.score) } }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            .map(\.1)
    }

    private static func fold(_ s: String) -> [Character] {
        s.map { Character($0.lowercased().first.map(String.init) ?? String($0)) }
    }

    private static func substring(_ q: [Character], in t: [Character]) -> Int? {
        guard q.count <= t.count else { return nil }
        return (0 ... t.count - q.count).first { t[$0 ..< $0 + q.count].elementsEqual(q) }
    }

    private static func isWordStart(_ t: [Character], _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let prev = t[i - 1]
        return !(prev.isLetter || prev.isNumber) || (prev.isLowercase && t[i].isUppercase)
    }

    private static func wordStarts(_ t: [Character]) -> [Int] {
        t.indices.filter { isWordStart(t, $0) && (t[$0].isLetter || t[$0].isNumber) }
    }

    /// Best subsequence placement: word starts and runs score, gaps cost.
    private static func scattered(_ q: [Character], in t: [Character]) -> (hits: [Int], score: Int)? {
        let n = t.count, m = q.count
        let none = Int.min / 4
        // best[j][i]: best score with q[..<j+1] matched and q[j] at t[i].
        var best = Array(repeating: Array(repeating: none, count: n), count: m)
        var from = Array(repeating: Array(repeating: -1, count: n), count: m)
        for j in 0 ..< m {
            // Max of best[j-1][k] + k over k <= i - 2: a gap of i - k - 1
            // costs that many points.
            var far = none, farAt = -1
            for i in 0 ..< n {
                if j > 0, i >= 2, best[j - 1][i - 2] > none, best[j - 1][i - 2] + (i - 2) > far {
                    far = best[j - 1][i - 2] + (i - 2)
                    farAt = i - 2
                }
                guard t[i] == q[j] else { continue }
                let bonus = 10 + (isWordStart(t, i) ? 20 : 0)
                if j == 0 {
                    best[j][i] = bonus - i
                    continue
                }
                let adjacent = i >= 1 && best[j - 1][i - 1] > none ? best[j - 1][i - 1] + 15 : none
                let gapped = farAt >= 0 ? far - i + 1 : none
                guard max(adjacent, gapped) > none else { continue }
                if adjacent >= gapped {
                    best[j][i] = adjacent + bonus
                    from[j][i] = i - 1
                } else {
                    best[j][i] = gapped + bonus
                    from[j][i] = farAt
                }
            }
        }
        guard let end = (0 ..< n).max(by: { best[m - 1][$0] < best[m - 1][$1] }), best[m - 1][end] > none else { return nil }
        var hits = [end]
        var j = m - 1, i = end
        while j > 0 { i = from[j][i]; j -= 1; hits.append(i) }
        return (hits.reversed(), best[m - 1][end])
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
