import SwiftUI

/// ⌘F's bar: a small pill over the tab's top-right corner. Typing searches
/// every pane in the tab; Return goes to the older hit, ⇧Return the newer.
struct FindBar: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @FocusState private var focused: Bool

    static let width: CGFloat = 340

    var body: some View {
        let theme = model.theme
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11.5)).foregroundStyle(theme.tertiaryText)
            TextField("Find in tab", text: $text)
                .textFieldStyle(.plain)
                .uiFont(size: 13)
                .focused($focused)
            if let counter = model.find?.counter {
                Text(counter)
                    .uiFont(size: 11.5)
                    .monospacedDigit()
                    .foregroundStyle(model.find?.current == nil ? theme.tertiaryText : theme.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.numericText())
            }
            theme.separator.frame(width: 1, height: 16).padding(.horizontal, 2)
            HStack(spacing: 0) {
                IconButton(symbol: "chevron.up", size: 11, weight: .semibold, frame: CGSize(width: 24, height: 22),
                           enabled: model.find?.current != nil) { model.stepFind(-1) }
                    .denTooltip("Older Match", command: .findNext)
                IconButton(symbol: "chevron.down", size: 11, weight: .semibold, frame: CGSize(width: 24, height: 22),
                           enabled: model.find?.current != nil) { model.stepFind(1) }
                    .denTooltip("Newer Match", command: .findPrevious)
                IconButton(symbol: "xmark", size: 10.5, weight: .semibold, frame: CGSize(width: 24, height: 22)) { model.closeFind() }
                    .denTooltip("Close", command: nil)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .frame(width: Self.width, height: 36)
        .background(MenuSurface(theme: theme))
        .animation(.denFast, value: model.find?.counter)
        .onAppear { KeyboardFocus.takeFromTerminal { focused = true } }
        .onChange(of: model.findFocusRequest) { KeyboardFocus.takeFromTerminal { focused = true } }
        // A beat after typing stops, so a long scrollback isn't scanned
        // once per keystroke.
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            model.setFindQuery(text)
        }
        .onKeyPress(.return, phases: .down) { press in
            // Typed faster than the debounce: land on the first hit instead.
            if model.find?.query != text {
                model.setFindQuery(text)
            } else {
                model.stepFind(press.modifiers.contains(.shift) ? 1 : -1)
            }
            return .handled
        }
        .onKeyPress(.escape) { model.closeFind(); return .handled }
        // Leaving the tab ends the search; its highlights go with it.
        .onChange(of: model.activeTab) { model.closeFind() }
    }
}
